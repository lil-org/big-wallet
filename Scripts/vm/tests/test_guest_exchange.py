import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location('guest_exchange_fixture', Path(__file__).resolve().parents[1] / 'guest_exchange.py')
exchange_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(exchange_module)


class GuestExchangeTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.exchange = self.root / 'host-exchange'
        self.exchange.mkdir(mode=0o700)
        self.work = self.root / 'private-work'
        self.work.mkdir(mode=0o700)
        self.password = self.work / 'password'
        self.password.write_bytes(b'fixture guest password\n')
        self.password.chmod(0o600)
        self.job = {'runId': 'fixture-run', 'vmId': 'fixture-vm', 'kind': 'run'}
        (self.exchange / 'job.json').write_text(json.dumps(self.job))
        (self.exchange / 'snapshot-manifest.json').write_text('{}')
        (self.exchange / 'source').mkdir()
        (self.exchange / 'source/input.txt').write_text('snapshot bytes')
        self.guest_root = self.root / 'guest-build'
        self.guest_root.mkdir()
        self.guest = self.guest_root / 'Exchange'
        self.guest.mkdir(mode=0o700)
        self.fake_ssh = self.root / 'fake-ssh.py'
        self.fake_ssh.write_text('''import json, os, pathlib, shlex, sys, time
root = pathlib.Path(sys.argv[1])
arguments = shlex.split(sys.argv[-1])
script = arguments[2]
assert "const root = '/Volumes/BigWalletBuild';" in script
assert '[[root, 0, 0o022]' in script
script = script.replace("const root = '/Volumes/BigWalletBuild';", 'const root = ' + json.dumps(str(root)) + ';')
script = script.replace('[[root, 0, 0o022]', '[[root, uid, 0o022]')
if 'Guest artifact export failed' in script:
    while (root / 'hold-export').exists(): time.sleep(0.01)
if (root / 'fail-report').exists() and "process.stdout.write('{}" in script:
    print('fixture guest password', file=sys.stderr)
    sys.exit(1)
os.execv(sys.argv[2], [sys.argv[2], '-e', script, *arguments[3:]])
''')
        self.node = shutil.which('node')
        self.assertIsNotNone(self.node)
        self.transport = None
        self.command_patch = patch.object(exchange_module.access, 'ssh_command', return_value=[
            sys.executable, str(self.fake_ssh), str(self.guest_root), self.node])
        self.command_patch.start()
        self.addCleanup(self.command_patch.stop)
        self.addCleanup(self.close_transport)

    def close_transport(self):
        if self.transport is not None:
            self.transport.cancel()

    def start(self):
        self.transport = exchange_module.GuestExchange('192.168.64.2', 'guest', self.password,
            self.work / 'known-hosts', 'big-wallet-vm-fixture-vm', self.work, self.exchange)
        return self.transport

    def drive(self, condition, timeout=10):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            outcome = self.transport.poll()
            if condition(outcome):
                return outcome
            time.sleep(0.01)
        self.fail(f'Transport did not reach expected state: {self.transport.phase}, {self.transport.result}')

    def uploaded(self):
        self.drive(lambda _: self.transport.phase == 'upload' and self.transport.child is None)
        self.assertEqual(json.loads((self.guest / 'job.json').read_text()), self.job)

    def report(self, *, finished=False):
        value = {**self.job, 'status': 'passed' if finished else 'running'}
        if finished:
            value['finishedAt'] = '2026-10-14T00:00:00Z'
        artifacts = self.guest / 'artifacts'
        artifacts.mkdir(exist_ok=True, mode=0o700)
        (artifacts / 'result.json').write_text(json.dumps(value))
        return value

    def archive(self, entries):
        archive = self.root / 'export.tar'
        with tarfile.open(archive, 'w') as output:
            for name, contents, kind in entries:
                member = tarfile.TarInfo(name)
                member.type = kind
                if kind == tarfile.REGTYPE:
                    member.size = len(contents)
                    output.addfile(member, io.BytesIO(contents))
                else:
                    member.linkname = contents.decode() if contents else ''
                    output.addfile(member)
        return archive

    def extract(self, archive):
        directory = Path(tempfile.mkdtemp(dir=self.root))
        exchange_module.extract_export(archive, directory, 'fixture-run', 'fixture-vm')
        return directory

    def test_input_archive_contains_only_job_snapshot_and_optional_inputs(self):
        (self.exchange / 'provision').mkdir()
        (self.exchange / 'provision/password').write_text('must not transfer')
        (self.exchange / 'artifacts').mkdir()
        (self.exchange / 'artifacts/planned-result.json').write_text('host plan')
        (self.exchange / 'source/link').symlink_to('input.txt')
        (self.exchange / 'inputs').mkdir()
        (self.exchange / 'inputs/replay.json').write_text('{}')
        archive = self.root / 'input.tar'
        exchange_module.build_input_archive(self.exchange, archive)
        with tarfile.open(archive) as result:
            self.assertEqual(set(result.getnames()), {'source', 'source/input.txt', 'source/link', 'inputs',
                'inputs/replay.json', 'snapshot-manifest.json', 'job.json'})
            self.assertTrue(result.getmember('source/link').issym())

    def test_input_archive_rejects_escaping_links_and_enforces_limits(self):
        (self.exchange / 'source/link').symlink_to('../../private-work/password')
        with self.assertRaisesRegex(exchange_module.GuestExchangeError, 'symlink leaves'):
            exchange_module.build_input_archive(self.exchange, self.root / 'input.tar')
        (self.exchange / 'source/link').unlink()
        with patch.object(exchange_module, 'MAX_INPUT_BYTES', 1):
            with self.assertRaisesRegex(exchange_module.GuestExchangeError, 'size limit'):
                exchange_module.build_input_archive(self.exchange, self.root / 'input.tar')

    def test_end_to_end_upload_and_export_publish_final_report_only_after_artifacts(self):
        (self.guest / 'job.json').write_text('{"runId":"old"}')
        (self.guest / 'unrelated').write_text('preserve')
        artifacts = self.exchange / 'artifacts'
        artifacts.mkdir(mode=0o700)
        (artifacts / 'planned-result.json').write_text('host plan')
        transport = self.start()
        self.uploaded()
        self.assertEqual((self.guest / 'source/input.txt').read_text(), 'snapshot bytes')
        self.assertEqual((self.guest / 'unrelated').read_text(), 'preserve')
        self.assertEqual(self.guest.stat().st_mode & 0o777, 0o700)
        running = self.report()
        self.drive(lambda _: (artifacts / 'result.json').exists())
        self.assertEqual(json.loads((artifacts / 'result.json').read_text()), running)
        final = self.report(finished=True)
        (self.guest / 'artifacts/tests.xcresult').mkdir()
        (self.guest / 'artifacts/tests.xcresult/data').write_bytes(b'artifact data')
        (self.guest / 'guest-runner.log').write_text('guest log')
        gate = self.guest_root / 'hold-export'
        gate.touch()
        transport.next_poll = 0
        self.drive(lambda _: transport.phase == 'export')
        for _ in range(3):
            self.assertIsNone(transport.poll())
            self.assertEqual(json.loads((artifacts / 'result.json').read_text()), running)
        gate.unlink()
        outcome = self.drive(lambda result: result is not None)
        self.assertEqual(outcome, {'status': 'passed', 'phase': 'exchange-complete'})
        self.assertEqual(json.loads((artifacts / 'result.json').read_text()), final)
        self.assertEqual((artifacts / 'tests.xcresult/data').read_bytes(), b'artifact data')
        self.assertEqual((self.exchange / 'guest-runner.log').read_text(), 'guest log')
        self.assertEqual((artifacts / 'planned-result.json').read_text(), 'host plan')
        transport.cancel()
        self.assertFalse(transport.askpass.exists())
        self.assertFalse(transport.scratch.exists())

    def test_export_rejects_unsafe_members_duplicates_conflicts_and_truncation(self):
        final = json.dumps({**self.job, 'status': 'passed', 'finishedAt': 'done'}).encode()
        base = [('artifacts/result.json', final, tarfile.REGTYPE)]
        bad = [('artifacts/../escape', b'', tarfile.REGTYPE), ('/absolute', b'', tarfile.REGTYPE),
               ('artifacts/link', b'../outside', tarfile.SYMTYPE), ('artifacts/link', b'artifacts/result.json', tarfile.LNKTYPE),
               ('artifacts/pipe', b'', tarfile.FIFOTYPE), ('artifacts/result.json', final, tarfile.REGTYPE),
               ('artifacts/planned-result.json', b'overwritten plan', tarfile.REGTYPE)]
        for member in bad:
            with self.subTest(member=member):
                with self.assertRaises(exchange_module.GuestExchangeError):
                    self.extract(self.archive(base + [member]))
        with self.assertRaisesRegex(exchange_module.GuestExchangeError, 'parent is not a directory'):
            self.extract(self.archive(base + [('artifacts/file', b'file', tarfile.REGTYPE),
                                             ('artifacts/file/child', b'child', tarfile.REGTYPE)]))
        archive = self.archive(base)
        archive.write_bytes(archive.read_bytes()[:1000])
        with self.assertRaisesRegex(exchange_module.GuestExchangeError, 'truncated'):
            self.extract(archive)

    def test_export_rejects_wrong_report_and_capacity_without_publishing(self):
        archive = self.archive([('artifacts/result.json', json.dumps({**self.job, 'runId': 'wrong',
            'status': 'passed', 'finishedAt': 'done'}).encode(), tarfile.REGTYPE)])
        with self.assertRaisesRegex(exchange_module.GuestExchangeError, 'current job'):
            self.extract(archive)
        with patch.object(exchange_module.shutil, 'disk_usage', return_value=shutil._ntuple_diskusage(1, 1, 0)):
            with self.assertRaisesRegex(exchange_module.GuestExchangeError, 'capacity'):
                self.extract(archive)
        self.assertFalse((self.exchange / 'artifacts/result.json').exists())

    def test_extraction_rejects_preexisting_directories_and_symlink_ancestors(self):
        final = json.dumps({**self.job, 'status': 'passed', 'finishedAt': 'done'}).encode()
        archive = self.archive([('artifacts/result.json', final, tarfile.REGTYPE)])
        for nested in (False, True):
            directory = Path(tempfile.mkdtemp(dir=self.root))
            link = directory / 'artifacts'
            if nested:
                link.mkdir()
                link = link / 'nested'
            link.symlink_to(self.work, target_is_directory=True)
            with self.subTest(nested=nested), self.assertRaisesRegex(exchange_module.GuestExchangeError, 'empty private'):
                exchange_module.extract_export(archive, directory, 'fixture-run', 'fixture-vm')
        self.assertFalse((self.work / 'result.json').exists())

    def test_stop_during_upload_is_not_erased_by_job_publication(self):
        transport = self.start()
        self.drive(lambda _: transport.phase == 'upload')
        transport.request_stop()
        transport.child.wait(timeout=5)
        self.drive(lambda _: transport.stop_sent)
        marker = self.guest / '.stop-fixture-run'
        self.assertTrue(marker.exists())
        self.assertEqual(json.loads((self.guest / 'stop.json').read_text()), {'runId': 'fixture-run'})
        self.assertTrue(not (self.guest / 'job.json').exists() or json.loads((self.guest / 'job.json').read_text()) == self.job)

    def test_transfer_failure_redacts_password_and_still_allows_guest_stop(self):
        transport = self.start()
        self.uploaded()
        (self.guest_root / 'fail-report').touch()
        outcome = self.drive(lambda result: result is not None)
        self.assertEqual(outcome['status'], 'failed')
        self.assertNotIn('fixture guest password', outcome['error'])
        self.assertIn('[REDACTED]', outcome['error'])
        transport.request_stop()
        stop_child = transport.stop_child
        self.assertIsNotNone(stop_child)
        stop_child.wait(timeout=5)
        self.assertEqual(json.loads((self.guest / 'stop.json').read_text()), {'runId': 'fixture-run'})
        self.assertEqual(transport.poll(), outcome)
        self.assertIsNone(transport.stop_child)
        self.assertTrue(transport.stop_sent)
        transport.cancel()
        self.assertIsNone(transport.stop_child)
        self.assertFalse(transport.askpass.exists())

    def test_terminal_notification_is_idempotent_and_missing_final_report_is_bounded(self):
        transport = self.start()
        self.uploaded()
        with patch.object(exchange_module.time, 'monotonic', return_value=100):
            transport.notify_guest_finished()
        with patch.object(exchange_module.time, 'monotonic', return_value=120):
            transport.notify_guest_finished()
        self.assertEqual(transport.guest_finished_at, 100)
        with patch.object(exchange_module.time, 'monotonic', return_value=131):
            outcome = transport.poll()
        self.assertEqual(outcome['reason'], 'guest_exited_without_result')

    def test_final_export_is_not_interrupted_by_terminal_report_grace(self):
        transport = self.start()
        self.uploaded()
        self.report(finished=True)
        gate = self.guest_root / 'hold-export'
        gate.touch()
        self.drive(lambda _: transport.phase == 'export')
        transport.guest_finished_at = time.monotonic() - 60
        self.assertIsNone(transport.poll())
        child = transport.child
        transport.cancel()
        self.assertIsNotNone(child.poll())
        self.assertFalse(transport.askpass.exists())
        self.assertFalse(transport.export_directory.exists())


if __name__ == '__main__':
    unittest.main()
