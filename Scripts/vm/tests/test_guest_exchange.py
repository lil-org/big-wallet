import hashlib
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
        self.guest_identity = self.root / 'guest-state'
        self.guest_identity.mkdir()
        self.identity = {'version': 1, 'vmId': 'fixture-vm', 'consoleUser': 'guest'}
        (self.guest_identity / 'identity.json').write_text(json.dumps(self.identity))
        self.build_identity = {'version': 1, 'vmId': 'fixture-vm', 'volumeUUID': '01234567-89ab-cdef-0123-456789abcdef'}
        (self.guest_root / '.big-wallet-vm.json').write_text(json.dumps(self.build_identity))
        self.fake_ssh = self.root / 'fake-ssh.py'
        self.fake_ssh.write_text('''import json, os, pathlib, shlex, sys, time
root = pathlib.Path(sys.argv[1])
arguments = shlex.split(sys.argv[-1])
script = arguments[2]
assert "const root = '/Volumes/BigWalletBuild';" in script
assert '[[root, 0, 0o022]' in script or 'const protectedOwner = 0;' in script
script = script.replace("const root = '/Volumes/BigWalletBuild';", 'const root = ' + json.dumps(str(root)) + ';')
script = script.replace('[[root, 0, 0o022]', '[[root, uid, 0o022]')
script = script.replace('const protectedOwner = 0;', 'const protectedOwner = process.getuid();')
script = script.replace("const identityDirectory = '/Library/Application Support/BigWalletTestVM';",
                        'const identityDirectory = ' + json.dumps(str(root.parent / 'guest-state')) + ';')
if (root / 'ready-fast-timeout').exists():
    script = script.replace('const deadline = performance.now() + 120000;', 'const deadline = performance.now() + 100;')
if 'Guest artifact export failed' in script:
    while (root / 'hold-export').exists(): time.sleep(0.01)
if 'const descriptor = fs.openSync(stopMarker' in script:
    (root / 'stop-started').touch()
    while (root / 'hold-stop').exists(): time.sleep(0.01)
if (root / 'fail-report').exists() and "supervisorAlive:" in script:
    print('fixture guest password', file=sys.stderr)
    sys.exit(1)
if "supervisorAlive:" in script:
    with (root / 'report-calls').open('a') as output: output.write('report\\n')
    while (root / 'hold-report').exists(): time.sleep(0.01)
    responses = root / 'report-responses.json'
    if responses.exists():
        values = json.loads(responses.read_text())
        if values:
            value = values.pop(0)
            responses.write_text(json.dumps(values))
            if value is not None:
                os.write(1, value.get('stdout', '').encode())
                os.write(2, value.get('stderr', '').encode())
                sys.exit(value.get('code', 255))
shim = r"""
const cpFixture = require('node:child_process');
const fsFixture = require('node:fs');
const rootFixture = ROOT_PLACEHOLDER;
const osFixture = require('node:os');
const realUserInfo = osFixture.userInfo;
osFixture.userInfo = () => ({...realUserInfo(), username: fsFixture.existsSync(rootFixture + '/wrong-credential-user') ? 'other-user' : 'guest'});
const realSpawnSync = cpFixture.spawnSync;
cpFixture.spawnSync = (file, args, options) => {
    if (file === '/sbin/mount') {
        if (args.length) throw Error('Mount readiness must remain read-only');
        fsFixture.appendFileSync(rootFixture + '/readiness-mount-probes', 'probe\\n');
        if (fsFixture.existsSync(rootFixture + '/mount-inspection-failed')) return {status: 1, stdout: ''};
        if (fsFixture.existsSync(rootFixture + '/mount-unavailable')) return {status: 0, stdout: ''};
        const filesystem = fsFixture.existsSync(rootFixture + '/mount-wrong') ? 'smbfs' : 'apfs';
        return {status: 0, stdout: '/dev/disk3s1 on ' + rootFixture + ' (' + filesystem + ', local, journaled)\\n'};
    }
    if (file === '/usr/local/libexec/big-wallet-vm/guest_runner') {
        if (JSON.stringify(args) !== JSON.stringify(['--verify-session']) || options.env.BW_TEST_VM_EXCHANGE !== rootFixture + '/Exchange') throw Error('Unexpected credential session verification');
        fsFixture.appendFileSync(rootFixture + '/session-verifications', options.env.BW_TEST_VM_RUN_ID + '\\n');
        return {status: fsFixture.existsSync(rootFixture + '/session-unavailable') ? 2 : 0};
    }
    if (file === '/usr/local/libexec/big-wallet-vm/VMGuestAgent') {
        if (args[0] !== '--process-identity') throw Error('Unexpected supervisor invocation');
        if (fsFixture.existsSync(rootFixture + '/identity-unavailable')) return {status: 2, stdout: ''};
        return {status: 0, stdout: JSON.stringify([1, Number(args[1])])};
    }
    if (file !== '/bin/launchctl') return realSpawnSync(file, args, options);
    fsFixture.appendFileSync(rootFixture + '/launchctl-calls', JSON.stringify(args) + '\\n');
    if (args[0] === 'print') return {status: fsFixture.existsSync(rootFixture + '/service-unavailable') ? 1 : 0};
    if (args[0] !== 'kickstart' || args[1] !== '-p' || args.includes('-k')) throw Error('Unexpected launchctl command');
    if (fsFixture.existsSync(rootFixture + '/launch-fails')) return {status: 1, stdout: ''};
    const receipt = {version: 1, runId: process.argv[1], vmId: process.argv[2], agentPID: FIXTURE_PID, agentStart: [1, FIXTURE_PID], state: 'running', runnerPID: FIXTURE_PID, runnerStart: [1, FIXTURE_PID]};
    fsFixture.mkdirSync(rootFixture + '/Exchange/.agent-runs', {recursive: true, mode: 0o700});
    fsFixture.writeFileSync(rootFixture + '/Exchange/.agent-runs/' + receipt.runId + '.json', JSON.stringify(receipt));
    if (fsFixture.existsSync(rootFixture + '/lose-launch-reply')) process.exit(255);
    return {status: 0, stdout: String(FIXTURE_PID)};
};
""".replace('ROOT_PLACEHOLDER', json.dumps(str(root))).replace('FIXTURE_PID', str(os.getppid()))
os.execv(sys.argv[2], [sys.argv[2], '-e', shim + script, *arguments[3:]])
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
        self.drive(lambda _: self.transport.launched_at is not None)
        self.assertEqual(json.loads((self.guest / 'job.json').read_text()), self.job)

    def established(self):
        transport = self.start()
        self.drive(lambda _: transport.observed_launch)
        self.assertIsNone(transport.child)
        return transport

    def banner_failure(self, **changes):
        return {'code': 255, 'stdout': '', 'stderr': 'Connection timed out during banner exchange\r\n'
                'Connection to 192.168.64.2 port 22 timed out\r\n', **changes}

    def report_responses(self, *responses):
        (self.guest_root / 'report-responses.json').write_text(json.dumps(responses))

    def report_attempt(self, now):
        transport = self.transport
        with patch.object(exchange_module.time, 'monotonic', return_value=now):
            self.assertIsNone(transport.poll())
        self.assertIsNotNone(transport.child)
        transport.child.wait(timeout=10)

    def transport_info(self):
        return json.loads((self.exchange / 'guest-transport.json').read_text())

    def begin_report_outage(self):
        transport = self.established()
        self.report_responses(self.banner_failure())
        now = time.monotonic()
        transport.next_poll = now
        self.report_attempt(now)
        with patch.object(exchange_module.time, 'monotonic', return_value=now + 10):
            self.assertIsNone(transport.poll())
        self.assertIsNotNone(transport.report_outage)
        return transport, now

    def safari_plan(self, platform='macos', signing='local', stages=None):
        self.job.update(version=1, profile='all', payload={'stages': ['safari'] if stages is None else stages,
                                                        'onlyTesting': [], 'signing': signing},
                        source={'sha256': hashlib.sha256((self.exchange / 'snapshot-manifest.json').read_bytes()).hexdigest(),
                                'commit': 'a' * 40})
        job_data = json.dumps(self.job).encode()
        (self.exchange / 'job.json').write_bytes(job_data)
        artifacts = self.exchange / 'artifacts'
        artifacts.mkdir(mode=0o700, exist_ok=True)
        plan = {'version': 1, 'runId': self.job['runId'], 'vmId': self.job['vmId'], 'profile': self.job['profile'],
                'source': self.job['source'], 'origin': 'host-plan', 'status': 'planned',
                'jobSHA256': hashlib.sha256(job_data).hexdigest(), 'stages': [{
                    'id': f'safari.{platform}.debug', 'group': 'safari', 'status': 'pending',
                    'nativeAudit': {'kind': 'safari', 'platform': platform, 'configuration': 'Debug', 'signing': signing}}]}
        (artifacts / 'planned-result.json').write_text(json.dumps(plan))
        return plan

    def guest_credential(self):
        return self.guest / self.job['runId'] / 'safari/guest-credential.json'

    def guest_script_command(self, script, shim=''):
        script = script.replace("const root = '/Volumes/BigWalletBuild';",
                                'const root = ' + json.dumps(str(self.guest_root)) + ';')
        script = script.replace('[[root, 0, 0o022]', '[[root, uid, 0o022]')
        return [self.node, '-e', shim + script, self.job['runId'], self.job['vmId']]

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

    def planned_failure(self, status='failed'):
        self.job.update(version=1, profile='all', source={
            'sha256': hashlib.sha256((self.exchange / 'snapshot-manifest.json').read_bytes()).hexdigest(),
            'commit': 'a' * 40})
        (self.exchange / 'job.json').write_text(json.dumps(self.job))
        artifacts = self.exchange / 'artifacts'
        artifacts.mkdir(exist_ok=True, mode=0o700)
        plan = {**self.job, 'origin': 'host-plan', 'status': 'planned',
                'jobSHA256': hashlib.sha256((self.exchange / 'job.json').read_bytes()).hexdigest(),
                'stages': [{'id': 'repository.fixture', 'group': 'repository', 'status': 'pending'},
                           {'id': 'test.fixture', 'group': 'test', 'status': 'pending',
                            'nativeAudit': {'platform': 'macos', 'configuration': 'Debug', 'kind': 'full'}}]}
        (artifacts / 'planned-result.json').write_text(json.dumps(plan))
        report = {**self.job, 'status': status, 'error': 'fixture harness import failed', 'finishedAt': 'fixture completion',
                  'stages': [], 'coverage': {'status': 'partial', 'fullSuiteVerified': False},
                  'summary': {'status': status, 'issues': ['fixture harness import failed']}}
        return plan, report

    def publish_fixture(self, report):
        exported = self.root / 'exported'
        (exported / 'artifacts').mkdir(parents=True)
        (exported / 'validated-result.json').write_text(json.dumps(report))
        (exported / 'artifacts/result.json').write_text(json.dumps(report))
        (exported / 'guest-runner.log').write_text('specific bootstrap diagnostic')
        transport = object.__new__(exchange_module.GuestExchange)
        transport.exchange, transport.export_directory = self.exchange, exported
        transport.run_id, transport.vm_id, transport.job = self.job['runId'], self.job['vmId'], self.job.copy()
        return transport

    def export_failure(self, status):
        plan, report = self.planned_failure(status)
        transport = self.start()
        self.uploaded()
        artifacts = self.guest / 'artifacts'
        artifacts.mkdir(mode=0o700)
        (artifacts / 'result.json').write_text(json.dumps(report))
        (self.guest / 'guest-runner.log').write_text('fixture harness import failed\n')
        transport.next_poll = 0
        self.assertEqual(self.drive(lambda value: value is not None), {'status': 'passed', 'phase': 'exchange-complete'})
        actual = json.loads((self.exchange / 'artifacts/result.json').read_text())
        expected_stage_status = 'cancelled' if status == 'cancelled' else 'blocked'
        self.assertEqual(actual['status'], status)
        self.assertEqual(actual['error'], report['error'])
        self.assertEqual(actual['plannedResult'], 'planned-result.json')
        self.assertEqual([stage['id'] for stage in actual['stages']], [stage['id'] for stage in plan['stages']])
        self.assertTrue(all(stage['status'] == expected_stage_status for stage in actual['stages']))
        self.assertEqual(actual['stages'][1]['nativeAudit'], plan['stages'][1]['nativeAudit'])
        self.assertEqual(actual['summary']['counts'][expected_stage_status], 2)
        self.assertEqual(actual['coverage']['status'], 'partial')
        self.assertFalse(actual['coverage']['fullSuiteVerified'])
        self.assertEqual(len(actual['coverage']['incompleteStages']), 2)
        self.assertEqual(json.loads((self.exchange / 'artifacts/planned-result.json').read_text()), plan)
        self.assertEqual((self.exchange / 'guest-runner.log').read_text(), 'fixture harness import failed\n')

    def test_failed_bootstrap_exports_its_diagnostic_and_blocks_every_planned_stage(self):
        self.export_failure('failed')

    def test_cancelled_bootstrap_exports_its_diagnostic_and_cancels_every_planned_stage(self):
        self.export_failure('cancelled')

    def test_bootstrap_failure_cannot_use_an_unbound_or_malformed_host_plan(self):
        plan, report = self.planned_failure()
        transport = self.publish_fixture(report)
        plan_path = self.exchange / 'artifacts/planned-result.json'
        for change in ({'runId': 'other'}, {'vmId': 'other'}, {'source': {'sha256': 'b' * 64}},
                       {'jobSHA256': 'b' * 64}, {'origin': 'guest'}, {'status': 'passed'},
                       {'stages': []}, {'stages': [{'id': 'fixture', 'status': 'passed'}]}, []):
            with self.subTest(change=change):
                plan_path.write_text(json.dumps({**plan, **change} if isinstance(change, dict) else change))
                with self.assertRaises(exchange_module.GuestExchangeError):
                    transport._publish_export()
                self.assertFalse((self.exchange / 'artifacts/result.json').exists())
                self.assertFalse((self.exchange / 'guest-runner.log').exists())
        plan_path.write_text(json.dumps(plan))
        (self.exchange / 'snapshot-manifest.json').write_text('changed snapshot manifest')
        with self.assertRaisesRegex(exchange_module.GuestExchangeError, 'source snapshot'):
            transport._publish_export()
        self.assertFalse((self.exchange / 'artifacts/result.json').exists())

    def test_failed_export_checks_the_captured_job_and_report_source(self):
        _, report = self.planned_failure()
        transport = self.publish_fixture(report)
        job_path = self.exchange / 'job.json'
        original = job_path.read_bytes()
        job_path.write_text(json.dumps({**self.job, 'profile': 'extended'}))
        with self.assertRaisesRegex(exchange_module.GuestExchangeError, 'failed guest job'):
            transport._publish_export()
        job_path.write_bytes(original)
        report['source'] = {**report['source'], 'sha256': 'b' * 64}
        (transport.export_directory / 'validated-result.json').write_text(json.dumps(report))
        with self.assertRaisesRegex(exchange_module.GuestExchangeError, 'source snapshot'):
            transport._publish_export()
        self.assertFalse((self.exchange / 'artifacts/result.json').exists())

    def test_failed_export_accepts_a_snapshot_manifest_larger_than_one_mebibyte(self):
        (self.exchange / 'snapshot-manifest.json').write_text(json.dumps({'version': 1, 'files': [], 'padding': 'x' * (1024 ** 2)}))
        _, report = self.planned_failure()
        transport = self.publish_fixture(report)
        transport._publish_export()
        actual = json.loads((self.exchange / 'artifacts/result.json').read_text())
        self.assertEqual(actual['status'], 'failed')
        self.assertEqual(len(actual['stages']), 2)

    def test_doctor_failure_and_completed_stage_outcomes_do_not_use_the_host_plan(self):
        for kind in ('doctor', 'run'):
            with self.subTest(kind=kind):
                self.job['kind'] = kind
                _, report = self.planned_failure()
                if kind == 'run':
                    report['stages'] = [{'id': 'already-passed', 'status': 'passed'}, {'id': 'already-blocked', 'status': 'blocked'}]
                transport = self.publish_fixture(report)
                (self.exchange / 'artifacts/planned-result.json').unlink()
                transport._publish_export()
                self.assertEqual(json.loads((self.exchange / 'artifacts/result.json').read_text()), report)
                (self.exchange / 'artifacts/result.json').unlink()
                (self.exchange / 'guest-runner.log').unlink()
                shutil.rmtree(transport.export_directory)

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

    def test_upload_waits_for_exchange_to_appear_without_creating_it(self):
        delayed = self.guest.with_name('DelayedExchange')
        self.guest.rename(delayed)
        transport = self.start()
        probes = self.guest_root / 'readiness-mount-probes'
        self.drive(lambda _: transport.phase == 'ready' and probes.exists() and len(probes.read_text().splitlines()) >= 2)
        self.assertFalse(self.guest.exists())
        self.assertFalse((delayed / 'job.json').exists())
        self.assertFalse((self.guest_root / 'launchctl-calls').exists())
        delayed.rename(self.guest)
        self.uploaded()
        self.assertGreaterEqual(len(probes.read_text().splitlines()), 2)

    def test_upload_waits_for_local_apfs_mount_before_touching_an_existing_exchange(self):
        (self.guest / 'job.json').write_text('preserved old job')
        unavailable = self.guest_root / 'mount-unavailable'
        unavailable.touch()
        transport = self.start()
        self.drive(lambda _: transport.phase == 'ready' and (self.guest_root / 'readiness-mount-probes').exists())
        self.assertEqual((self.guest / 'job.json').read_text(), 'preserved old job')
        self.assertFalse((self.guest / 'source').exists())
        unavailable.unlink()
        self.uploaded()

    def test_upload_waits_for_missing_build_identity_but_never_manufactures_it(self):
        marker = self.guest_root / '.big-wallet-vm.json'
        marker.unlink()
        transport = self.start()
        self.drive(lambda _: transport.phase == 'ready' and (self.guest_root / 'readiness-mount-probes').exists())
        self.assertFalse(marker.exists())
        self.assertFalse((self.guest / 'job.json').exists())
        marker.write_text(json.dumps(self.build_identity))
        self.uploaded()

    def test_missing_exchange_readiness_times_out_without_upload_or_guest_launch(self):
        shutil.rmtree(self.guest)
        (self.guest_root / 'ready-fast-timeout').touch()
        self.start()
        outcome = self.drive(lambda result: result is not None)
        self.assertEqual(outcome['status'], 'failed')
        self.assertEqual(outcome['phase'], 'ready')
        self.assertIn('did not become ready within 120 seconds', outcome['error'])
        self.assertFalse(self.guest.exists())
        self.assertFalse((self.guest_root / 'launchctl-calls').exists())

    def test_stop_during_readiness_is_prompt_and_does_not_write_to_unready_guest_storage(self):
        shutil.rmtree(self.guest)
        transport = self.start()
        self.drive(lambda _: transport.phase == 'ready' and (self.guest_root / 'readiness-mount-probes').exists())
        transport.request_stop()
        self.assertIsNone(transport.stop_child)
        outcome = transport.poll()
        self.assertEqual(outcome, {'status': 'failed', 'reason': 'guest_exchange_cancelled', 'phase': 'ready'})
        self.assertFalse(self.guest.exists())
        self.assertFalse((self.guest_root / 'launchctl-calls').exists())
        self.assertFalse(transport.input_archive.exists())

    def test_invalid_identity_mount_or_permissions_fail_readiness_without_retries_or_upload(self):
        guest_identity = self.guest_identity / 'identity.json'
        build_identity = self.guest_root / '.big-wallet-vm.json'
        cases = [
            lambda: guest_identity.write_text(json.dumps({**self.identity, 'vmId': 'another-vm'})),
            lambda: guest_identity.write_text(json.dumps({**self.identity, 'consoleUser': 'another-user'})),
            lambda: guest_identity.chmod(0o666),
            lambda: build_identity.write_text(json.dumps({**self.build_identity, 'vmId': 'another-vm'})),
            lambda: build_identity.write_text(json.dumps({**self.build_identity, 'volumeUUID': 'invalid'})),
            lambda: build_identity.write_text('{'),
            lambda: build_identity.write_text('null'),
            lambda: build_identity.write_text('false'),
            lambda: build_identity.write_text('0'),
            lambda: build_identity.chmod(0o666),
            lambda: self.guest.chmod(0o755),
            lambda: (self.guest_root / 'mount-wrong').touch(),
            lambda: (self.guest_root / 'mount-inspection-failed').touch(),
        ]
        for index, change in enumerate(cases):
            with self.subTest(case=index):
                guest_identity.write_text(json.dumps(self.identity))
                guest_identity.chmod(0o644)
                build_identity.write_text(json.dumps(self.build_identity))
                build_identity.chmod(0o644)
                self.guest.chmod(0o700)
                for name in ('mount-wrong', 'mount-inspection-failed', 'readiness-mount-probes'):
                    (self.guest_root / name).unlink(missing_ok=True)
                change()
                self.start()
                outcome = self.drive(lambda result: result is not None)
                self.assertEqual(outcome['phase'], 'ready')
                self.assertEqual(outcome['status'], 'failed')
                self.assertNotIn('did not become ready within', outcome['error'])
                self.assertFalse((self.guest / 'job.json').exists())
                self.assertFalse((self.guest_root / 'launchctl-calls').exists())
                probes = self.guest_root / 'readiness-mount-probes'
                if probes.exists():
                    self.assertEqual(len(probes.read_text().splitlines()), 1)
                self.close_transport()

    def test_symlinked_exchange_fails_readiness_without_following_or_mutating_it(self):
        actual = self.guest.with_name('UnrelatedExchange')
        self.guest.rename(actual)
        self.guest.symlink_to(actual, target_is_directory=True)
        self.start()
        outcome = self.drive(lambda result: result is not None)
        self.assertEqual(outcome['phase'], 'ready')
        self.assertIn('ownership or permissions are invalid', outcome['error'])
        self.assertFalse((actual / 'job.json').exists())

    def test_local_macos_safari_credential_is_private_separate_and_removed_only_at_final_export(self):
        self.safari_plan()
        transport = self.start()
        self.drive(lambda _: transport.phase == 'safari-credential')
        secret = self.password.read_bytes().strip()
        self.assertNotIn(secret.decode(), str(transport.child.args))
        self.assertNotIn(secret.decode(), str(transport.environment))
        self.uploaded()
        credential = self.guest_credential()
        self.assertEqual(json.loads(credential.read_text()), {
            'version': 1, 'runID': self.job['runId'], 'consoleUser': 'guest', 'password': secret.decode()})
        self.assertEqual(credential.stat().st_mode & 0o777, 0o600)
        self.assertEqual(credential.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual(credential.parent.parent.stat().st_mode & 0o777, 0o700)
        self.assertEqual((self.guest_root / 'session-verifications').read_text().splitlines(), [self.job['runId']])
        for path in (self.exchange / 'job.json', self.exchange / 'snapshot-manifest.json',
                     self.exchange / 'artifacts/planned-result.json', self.guest / 'job.json', self.guest / 'source/input.txt'):
            self.assertNotIn(secret, path.read_bytes())
        self.report()
        self.drive(lambda _: (self.exchange / 'artifacts/result.json').exists())
        self.assertTrue(credential.exists())
        self.report(finished=True)
        transport.next_poll = 0
        self.assertEqual(self.drive(lambda outcome: outcome is not None)['status'], 'passed')
        self.assertFalse(credential.exists())
        self.assertFalse(list(self.exchange.rglob('guest-credential.json')))
        for path in (self.exchange / 'artifacts').rglob('*'):
            if path.is_file():
                self.assertNotIn(secret, path.read_bytes())

    def test_safari_credential_is_not_staged_for_apple_ios_or_build_only_selection(self):
        for options in ({'signing': 'apple'}, {'platform': 'ios'}, {'stages': ['build']}, {'stages': ['test']}):
            with self.subTest(options=options):
                self.safari_plan(**options)
                self.assertIsNone(exchange_module.safari_credential_job_digest(self.job, self.exchange))

    def test_safari_credential_accepts_only_the_exact_explicit_preparation_plan(self):
        plan = self.safari_plan()
        self.job['payload'].update({'prepareSafari': True, 'configuration': 'Debug', 'onlyTesting': ['Safari UI Tests macOS']})
        job_data = json.dumps(self.job).encode()
        (self.exchange / 'job.json').write_bytes(job_data)
        plan['jobSHA256'] = hashlib.sha256(job_data).hexdigest()
        plan['stages'] = [{'id': identifier, 'group': group, 'status': 'pending',
                           **({'preparationResult': True} if identifier.startswith('prepare-safari.') else {})}
                          for identifier, group in [('provider.install', 'repository'), ('protocol.check', 'repository'),
                                                    ('build-safari.macos.debug', 'build'), ('prepare-safari.macos.debug', 'safari')]]
        (self.exchange / 'artifacts/planned-result.json').write_text(json.dumps(plan))
        self.assertEqual(exchange_module.safari_credential_job_digest(self.job, self.exchange), plan['jobSHA256'])
        for change in ('missing-marker', 'native-audit', 'extra-stage'):
            changed = json.loads(json.dumps(plan))
            if change == 'missing-marker':
                changed['stages'][-1].pop('preparationResult')
            elif change == 'native-audit':
                changed['stages'][-1]['nativeAudit'] = {'kind': 'safari', 'platform': 'macos'}
            else:
                changed['stages'].append({'id': 'another', 'group': 'safari', 'status': 'pending'})
            (self.exchange / 'artifacts/planned-result.json').write_text(json.dumps(changed))
            with self.assertRaises(exchange_module.GuestExchangeError):
                exchange_module.safari_credential_job_digest(self.job, self.exchange)

    def test_safari_credential_requires_the_unchanged_job_plan_and_runtime_selection(self):
        for change in ('job-digest', 'snapshot', 'plan-source', 'plan-stage'):
            with self.subTest(change=change):
                plan = self.safari_plan()
                if change == 'job-digest':
                    plan['jobSHA256'] = 'f' * 64
                elif change == 'snapshot':
                    (self.exchange / 'snapshot-manifest.json').write_text('{"changed":true}')
                elif change == 'plan-source':
                    plan['source'] = {'sha256': 'f' * 64, 'commit': 'b' * 40}
                else:
                    plan['stages'][0]['nativeAudit']['signing'] = 'apple'
                (self.exchange / 'artifacts/planned-result.json').write_text(json.dumps(plan))
                with self.assertRaises(exchange_module.GuestExchangeError):
                    exchange_module.safari_credential_job_digest(self.job, self.exchange)

    def test_safari_credential_staging_requires_verified_guest_session_and_account(self):
        self.safari_plan()
        (self.guest_root / 'session-unavailable').touch()
        self.start()
        outcome = self.drive(lambda outcome: outcome is not None)
        self.assertEqual(outcome['status'], 'failed')
        self.assertEqual(outcome['phase'], 'safari-credential')
        self.assertFalse(self.guest_credential().exists())
        self.assertFalse((self.guest_root / 'launchctl-calls').exists())
        self.assertNotIn('fixture guest password', json.dumps(outcome))

    def test_safari_credential_rejects_a_different_guest_account(self):
        self.safari_plan()
        (self.guest_root / 'wrong-credential-user').touch()
        self.start()
        outcome = self.drive(lambda outcome: outcome is not None)
        self.assertEqual(outcome['status'], 'failed')
        self.assertEqual(outcome['phase'], 'ready')
        self.assertFalse(self.guest_credential().exists())
        self.assertFalse((self.guest_root / 'session-verifications').exists())
        self.assertNotIn('fixture guest password', json.dumps(outcome))

    def test_safari_credential_rejects_symlinked_destination_without_writing_outside_scope(self):
        self.safari_plan()
        destination = self.guest_credential()
        destination.parent.parent.mkdir(mode=0o700)
        outside = self.root / 'outside-credential'
        outside.mkdir(mode=0o700)
        destination.parent.symlink_to(outside)
        self.start()
        outcome = self.drive(lambda outcome: outcome is not None)
        self.assertEqual(outcome['status'], 'failed')
        self.assertFalse((outside / destination.name).exists())
        self.assertNotIn('fixture guest password', json.dumps(outcome))

    def test_safari_credential_is_removed_when_the_run_is_cancelled(self):
        self.safari_plan()
        transport = self.start()
        self.uploaded()
        self.assertTrue(self.guest_credential().exists())
        interrupted = self.guest_credential().parent / '.guest-credential.12345.tmp'
        interrupted.write_bytes(b'fixture guest password')
        interrupted.chmod(0o600)
        unrelated = self.guest_credential().parent / '.guest-credential.keep.tmp'
        unrelated.write_text('preserve unrelated file')
        transport.request_stop()
        self.drive(lambda _: transport.stop_sent)
        self.assertFalse(self.guest_credential().exists())
        self.assertFalse(interrupted.exists())
        self.assertTrue(unrelated.exists())

    def test_final_export_removes_interrupted_secret_temp_even_without_published_credential(self):
        self.safari_plan()
        transport = self.start()
        self.uploaded()
        self.guest_credential().unlink()
        interrupted = self.guest_credential().parent / '.guest-credential.54321.tmp'
        interrupted.write_bytes(b'fixture guest password')
        interrupted.chmod(0o600)
        self.report(finished=True)
        transport.next_poll = 0
        self.assertEqual(self.drive(lambda outcome: outcome is not None)['status'], 'passed')
        self.assertFalse(interrupted.exists())

    def test_stop_and_export_remove_the_same_credential_concurrently(self):
        self.safari_plan()
        self.start()
        self.uploaded()
        report = self.report(finished=True)
        (self.guest / 'artifacts/diagnostic.log').write_text('collected diagnostics')
        shim = f'''
const raceFS = require('node:fs');
const realUnlink = raceFS.unlinkSync;
const credential = {json.dumps(str(self.guest_credential()))};
const prefix = {json.dumps(str(self.root / 'cleanup-ready-'))};
const role = process.argv[3];
raceFS.unlinkSync = filename => {{
    if (filename === credential) {{
        raceFS.writeFileSync(prefix + role, 'ready');
        const peer = prefix + (role === 'export' ? 'stop' : 'export');
        const deadline = Date.now() + 5000;
        while (!raceFS.existsSync(peer)) {{
            if (Date.now() >= deadline) throw Error('Credential cleanup barrier timed out');
            Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 1);
        }}
    }}
    return realUnlink(filename);
}};
'''
        children = []
        results = {}
        try:
            for role, script in (('export', exchange_module._EXPORT), ('stop', exchange_module._STOP)):
                child = subprocess.Popen(self.guest_script_command(script, shim) + [role],
                                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
                children.append((role, child))
            for role, child in children:
                output, errors = child.communicate(timeout=10)
                self.assertEqual(child.returncode, 0, errors.decode())
                results[role] = output
        finally:
            for _, child in children:
                exchange_module.access._stop(child)
                child.communicate()
        self.assertFalse(self.guest_credential().exists())
        self.assertEqual(json.loads((self.guest / 'stop.json').read_text()), {'runId': self.job['runId']})
        with tarfile.open(fileobj=io.BytesIO(results['export'])) as archive:
            self.assertEqual(json.load(archive.extractfile('artifacts/result.json')), report)
            self.assertEqual(archive.extractfile('artifacts/diagnostic.log').read(), b'collected diagnostics')
            self.assertFalse(any('credential' in name for name in archive.getnames()))
        self.assertNotIn(self.password.read_bytes().strip(), results['export'])

    def test_credential_cleanup_rejects_unsafe_file_identity(self):
        self.safari_plan()
        self.start()
        self.uploaded()
        credential = self.guest_credential()
        original = credential.read_bytes()
        outside = self.root / 'outside-credential'
        outside.write_bytes(original)
        outside.chmod(0o600)
        for change in ('permissions', 'symlink', 'owner'):
            with self.subTest(change=change):
                credential.unlink()
                credential.write_bytes(original)
                credential.chmod(0o600)
                shim = ''
                if change == 'permissions':
                    credential.chmod(0o644)
                elif change == 'symlink':
                    credential.unlink()
                    credential.symlink_to(outside)
                else:
                    shim = f'''const identityFS = require('node:fs');
const realStat = identityFS.lstatSync;
identityFS.lstatSync = filename => {{
    const info = realStat(filename);
    if (filename === {json.dumps(str(credential))}) info.uid += 1;
    return info;
}};
'''
                result = subprocess.run(self.guest_script_command(exchange_module._STOP, shim),
                                        capture_output=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(b'Invalid Safari credential file', result.stderr)
                self.assertEqual(credential.read_bytes(), original)
                self.assertEqual(outside.read_bytes(), original)

    def test_credential_cleanup_preserves_nonmissing_unlink_errors(self):
        self.safari_plan()
        self.start()
        self.uploaded()
        credential = self.guest_credential()
        for code in ('EACCES', 'EPERM', 'EIO'):
            with self.subTest(code=code):
                shim = f'''const errorFS = require('node:fs');
const realUnlink = errorFS.unlinkSync;
errorFS.unlinkSync = filename => {{
    if (filename === {json.dumps(str(credential))}) throw Object.assign(new Error('fixture unlink failure'), {{code: {json.dumps(code)}}});
    return realUnlink(filename);
}};
'''
                result = subprocess.run(self.guest_script_command(exchange_module._STOP, shim),
                                        capture_output=True, timeout=10)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(code.encode(), result.stderr)
                self.assertTrue(credential.is_file())

    def test_safari_credential_is_never_packaged_with_job_inputs(self):
        self.safari_plan()
        reserved = self.exchange / self.job['runId'] / 'safari'
        reserved.mkdir(parents=True, mode=0o700)
        (reserved / 'guest-credential.json').write_text('fixture credential outside approved input roots')
        archive = self.root / 'input.tar'
        exchange_module.build_input_archive(self.exchange, archive)
        with tarfile.open(archive) as inputs:
            self.assertFalse(any('credential' in name for name in inputs.getnames()))

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

    def test_transfer_failure_waits_for_guest_stop_and_credential_cleanup(self):
        self.safari_plan()
        transport = self.start()
        self.uploaded()
        (self.guest_root / 'fail-report').touch()
        outcome = self.drive(lambda result: result is not None)
        self.assertEqual(outcome['status'], 'failed')
        self.assertNotIn('fixture guest password', outcome['error'])
        self.assertIn('[REDACTED]', outcome['error'])
        gate = self.guest_root / 'hold-stop'
        gate.touch()
        transport.request_stop()
        stop_child = transport.stop_child
        self.assertIsNotNone(stop_child)
        self.drive(lambda _: (self.guest_root / 'stop-started').exists())
        self.assertIsNone(transport.poll())
        self.assertIsNone(stop_child.poll())
        self.assertTrue(self.guest_credential().exists())
        self.assertIs(transport.result, outcome)
        gate.unlink()
        self.assertIs(self.drive(lambda result: result is not None), outcome)
        self.assertEqual(json.loads((self.guest / 'stop.json').read_text()), {'runId': 'fixture-run'})
        self.assertFalse(self.guest_credential().exists())
        self.assertIsNone(transport.stop_child)
        self.assertTrue(transport.stop_sent)
        transport.cancel()
        self.assertIsNone(transport.stop_child)
        self.assertFalse(transport.askpass.exists())

    def test_stop_timeout_after_transfer_failure_preserves_failure_and_terminates_child(self):
        self.safari_plan()
        transport = self.start()
        self.uploaded()
        (self.guest_root / 'fail-report').touch()
        outcome = self.drive(lambda result: result is not None)
        (self.guest_root / 'hold-stop').touch()
        before_stop = time.monotonic()
        transport.request_stop()
        self.assertGreaterEqual(transport.stop_deadline, before_stop + 15)
        self.assertLessEqual(transport.stop_deadline, time.monotonic() + 15)
        stop_child = transport.stop_child
        self.drive(lambda _: (self.guest_root / 'stop-started').exists())
        self.assertIsNone(transport.poll())
        with patch.object(exchange_module.time, 'monotonic', return_value=transport.stop_deadline + 1):
            self.assertIs(transport.poll(), outcome)
        self.assertIsNotNone(stop_child.poll())
        self.assertIsNone(transport.stop_child)
        self.assertFalse(transport.stop_sent)
        self.assertTrue(self.guest_credential().exists())
        self.assertIs(transport.result, outcome)

    def test_transfer_failure_observed_during_stop_waits_for_credential_cleanup(self):
        self.safari_plan()
        transport = self.established()
        (self.guest_root / 'fail-report').touch()
        transport.next_poll = 0
        self.assertIsNone(transport.poll())
        transport.child.wait(timeout=5)
        gate = self.guest_root / 'hold-stop'
        gate.touch()
        transport.request_stop()
        self.assertIsNone(transport.poll())
        outcome = transport.result
        self.assertEqual(outcome['status'], 'failed')
        self.assertEqual(outcome['phase'], 'report')
        self.assertEqual(outcome['error'], '[REDACTED]')
        self.assertIsNone(transport.child)
        self.assertIsNone(transport.stop_child.poll())
        self.assertTrue(self.guest_credential().exists())
        gate.unlink()
        self.assertIs(self.drive(lambda result: result is not None), outcome)
        self.assertTrue(transport.stop_sent)
        self.assertFalse(self.guest_credential().exists())

    def test_report_banner_retries_recover_without_repeating_mutations_or_changing_guest_result(self):
        self.safari_plan()
        transport = self.established()
        job_mtime = (self.guest / 'job.json').stat().st_mtime_ns
        credential_mtime = self.guest_credential().stat().st_mtime_ns
        final = self.report(finished=True)
        self.report_responses(self.banner_failure(), self.banner_failure())
        now = time.monotonic()
        transport.next_poll = now
        for started, finished, next_attempt in ((now, now + 10, now + 15), (now + 15, now + 25, now + 35)):
            self.report_attempt(started)
            with patch.object(exchange_module.time, 'monotonic', return_value=finished):
                self.assertIsNone(transport.poll())
            self.assertEqual(transport.next_poll, next_attempt)
            with patch.object(exchange_module.time, 'monotonic', return_value=next_attempt - 0.001):
                self.assertIsNone(transport.poll())
            self.assertIsNone(transport.child)
        self.assertEqual(self.guest_credential().stat().st_mtime_ns, credential_mtime)
        self.report_attempt(now + 35)
        with patch.object(exchange_module.time, 'monotonic', return_value=now + 36):
            self.assertIsNone(transport.poll())
        self.assertIsNone(transport.report_outage)
        self.assertEqual(transport.phase, 'export')
        self.assertEqual(self.drive(lambda value: value is not None), {'status': 'passed', 'phase': 'exchange-complete'})
        self.assertEqual(json.loads((self.exchange / 'artifacts/result.json').read_text()), final)
        self.assertEqual((self.guest / 'job.json').stat().st_mtime_ns, job_mtime)
        calls = [json.loads(line) for line in (self.guest_root / 'launchctl-calls').read_text().splitlines()]
        self.assertEqual(sum(call[0] == 'kickstart' for call in calls), 1)
        self.assertEqual(len((self.guest_root / 'session-verifications').read_text().splitlines()), 1)
        info = self.transport_info()
        self.assertEqual((info['outages'], info['retryAttempts'], info['recoveredOutages']), (1, 2, 1))
        event = info['recentOutages'][0]
        self.assertEqual((event['status'], event['failures'], event['retryAttempts']), ('recovered', 2, 2))
        journal = self.exchange / 'guest-transport.json'
        self.assertEqual(journal.stat().st_mode & 0o777, 0o600)
        self.assertNotIn(self.password.read_text().strip(), journal.read_text())

    def test_report_banner_retries_stop_after_two_additional_attempts(self):
        transport = self.established()
        self.report_responses(*[self.banner_failure()] * 3)
        now = time.monotonic()
        transport.next_poll = now
        for index, (started, finished) in enumerate(((now, now + 10), (now + 15, now + 25), (now + 35, now + 45))):
            self.report_attempt(started)
            with patch.object(exchange_module.time, 'monotonic', return_value=finished):
                result = transport.poll()
            self.assertEqual(result is not None, index == 2)
        self.assertEqual((result['status'], result['reason'], result['phase']), ('failed', 'guest_exchange_failed', 'report'))
        event = self.transport_info()['recentOutages'][0]
        self.assertEqual((event['status'], event['reason'], event['failures'], event['retryAttempts']),
                         ('failed', 'retry_limit', 3, 2))
        self.assertIsNone(transport.child)

    def test_report_retry_classifier_rejects_security_errors_output_and_other_phases(self):
        transport = self.established()
        expected = self.banner_failure()['stderr']
        cases = [
            {'code': 1}, {'code': -15}, {'stdout': ' '}, {'stdout': '{}'},
            {'stderr': expected.replace('192.168.64.2', '192.168.64.3')},
            {'stderr': expected.replace('port 22', 'port 23')},
            {'stderr': 'Permission denied (password).\r\n'},
            {'stderr': 'Host key verification failed.\r\n' + expected},
            {'stderr': 'REMOTE HOST IDENTIFICATION HAS CHANGED!\r\n' + 'x' * 5000 + expected},
            {'stderr': expected + 'fixture guest password\r\n'},
            {'stderr': 'Connection reset by peer\r\n'}, {'stderr': ''},
            {'observed': False}, {'stopping': True},
            *[{'phase': phase} for phase in ('pack', 'ready', 'upload', 'safari-credential', 'launch', 'export', 'extract')],
        ]
        for index, change in enumerate(cases):
            with self.subTest(case=index):
                value = self.banner_failure(**change)
                transport.phase = change.get('phase', 'report')
                transport.observed_launch = change.get('observed', True)
                transport.stop_requested = change.get('stopping', False)
                transport.output = transport._temporary_output()
                transport.output.write(value['stdout'].encode())
                transport.errors = transport._temporary_output()
                transport.errors.write(value['stderr'].encode())
                self.assertFalse(transport._retry_report_failure(value['code'], time.monotonic()))
                self.assertIsNone(transport.report_outage)
                transport._close_phase_files()
        self.assertFalse((self.exchange / 'guest-transport.json').exists())

    def test_first_report_banner_failure_without_established_execution_is_immediate(self):
        transport = self.start()
        self.uploaded()
        self.assertFalse(transport.observed_launch)
        self.report_responses(self.banner_failure())
        result = self.drive(lambda value: value is not None)
        self.assertEqual((result['reason'], result['phase']), ('guest_exchange_failed', 'report'))
        self.assertFalse((self.exchange / 'guest-transport.json').exists())

    def test_report_outage_deadline_prevents_a_late_queued_attempt(self):
        transport, now = self.begin_report_outage()
        calls = (self.guest_root / 'report-calls').read_text()
        with patch.object(exchange_module.time, 'monotonic', return_value=now + 60):
            result = transport.poll()
        self.assertEqual((result['reason'], result['phase']), ('guest_exchange_timeout', 'report'))
        self.assertEqual((self.guest_root / 'report-calls').read_text(), calls)
        event = self.transport_info()['recentOutages'][0]
        self.assertEqual((event['status'], event['retryAttempts'], event['elapsedSeconds']), ('failed', 0, 60))

    def test_report_outage_deadline_stops_an_active_retry(self):
        transport, now = self.begin_report_outage()
        (self.guest_root / 'hold-report').touch()
        with patch.object(exchange_module.time, 'monotonic', return_value=now + 15):
            self.assertIsNone(transport.poll())
        child = transport.child
        self.assertIsNone(child.poll())
        self.assertLessEqual(transport.deadline, now + 60)
        with patch.object(exchange_module.time, 'monotonic', return_value=now + 60):
            result = transport.poll()
        self.assertEqual(result['reason'], 'guest_exchange_timeout')
        self.assertIsNotNone(child.poll())
        self.assertEqual(self.transport_info()['retryAttempts'], 1)

    def test_report_outage_budget_starts_at_the_original_attempt(self):
        transport = self.established()
        self.report_responses(self.banner_failure())
        now = time.monotonic()
        transport.next_poll = now
        self.report_attempt(now)
        with patch.object(exchange_module.time, 'monotonic', return_value=now + 55):
            result = transport.poll()
        self.assertEqual(result['reason'], 'guest_exchange_failed')
        event = self.transport_info()['recentOutages'][0]
        self.assertEqual((event['reason'], event['retryAttempts']), ('outage_deadline', 0))

    def test_stop_during_report_retry_backoff_collects_the_cancelled_guest_result(self):
        transport, now = self.begin_report_outage()
        calls = (self.guest_root / 'report-calls').read_text()
        final = {**self.report(finished=True), 'status': 'cancelled'}
        (self.guest / 'artifacts/result.json').write_text(json.dumps(final))
        (self.guest / 'artifacts/cancel.log').write_text('completed guest finalization')
        transport.request_stop()
        transport.stop_child.wait(timeout=10)
        with patch.object(exchange_module.time, 'monotonic', return_value=now + 11):
            self.assertIsNone(transport.poll())
        self.assertIsNone(transport.report_outage)
        self.assertTrue(transport.stop_sent)
        self.assertIsNone(transport.stop_child)
        self.assertEqual(json.loads((self.guest / 'stop.json').read_text()), {'runId': 'fixture-run'})
        self.assertEqual(self.transport_info()['recentOutages'][0]['status'], 'cancelled')
        self.assertEqual(self.drive(lambda result: result is not None), {'status': 'passed', 'phase': 'exchange-complete'})
        self.assertGreater(len((self.guest_root / 'report-calls').read_text()), len(calls))
        self.assertEqual(json.loads((self.exchange / 'artifacts/result.json').read_text()), final)
        self.assertEqual((self.exchange / 'artifacts/cancel.log').read_text(), 'completed guest finalization')
        self.assertEqual(self.transport_info()['recoveredOutages'], 0)

    def test_stop_during_active_report_retry_starts_a_fresh_final_report_poll(self):
        transport, now = self.begin_report_outage()
        (self.guest_root / 'hold-report').touch()
        with patch.object(exchange_module.time, 'monotonic', return_value=now + 15):
            self.assertIsNone(transport.poll())
        child = transport.child
        transport.request_stop()
        transport.stop_child.wait(timeout=10)
        final = {**self.report(finished=True), 'status': 'failed', 'error': 'original test failure'}
        (self.guest / 'artifacts/result.json').write_text(json.dumps(final))
        with patch.object(exchange_module.time, 'monotonic', return_value=now + 16):
            self.assertIsNone(transport.poll())
        self.assertIsNotNone(child.poll())
        self.assertIsNot(transport.child, child)
        self.assertTrue(transport.stop_sent)
        self.assertEqual(self.transport_info()['recentOutages'][0]['status'], 'cancelled')
        (self.guest_root / 'hold-report').unlink()
        self.assertEqual(self.drive(lambda result: result is not None), {'status': 'passed', 'phase': 'exchange-complete'})
        self.assertEqual(json.loads((self.exchange / 'artifacts/result.json').read_text()), final)

    def test_failed_final_report_after_stop_does_not_restart_banner_retries(self):
        transport, now = self.begin_report_outage()
        self.report_responses(self.banner_failure())
        transport.request_stop()
        transport.stop_child.wait(timeout=10)
        with patch.object(exchange_module.time, 'monotonic', return_value=now + 11):
            self.assertIsNone(transport.poll())
        result = self.drive(lambda result: result is not None)
        self.assertEqual((result['status'], result['reason'], result['phase']),
                         ('failed', 'guest_exchange_cancelled', 'report'))
        self.assertEqual(self.transport_info()['retryAttempts'], 0)
        self.assertEqual(self.transport_info()['recentOutages'][0]['reason'], 'guest_stop_requested')

    def test_report_retry_does_not_extend_guest_terminal_report_grace(self):
        transport = self.established()
        self.report_responses(self.banner_failure())
        now = time.monotonic()
        transport.guest_finished_at = now - 25
        transport.next_poll = now
        self.report_attempt(now)
        with patch.object(exchange_module.time, 'monotonic', return_value=now + 1):
            self.assertIsNone(transport.poll())
        with patch.object(exchange_module.time, 'monotonic', return_value=now + 5):
            result = transport.poll()
        self.assertEqual(result['reason'], 'guest_exited_without_result')
        self.assertEqual(transport.guest_finished_at, now - 25)
        self.assertEqual(self.transport_info()['retryAttempts'], 0)

    def test_invalid_reports_after_retry_fail_without_recording_recovery(self):
        valid = self.observation(self.receipt(state='running', runnerPID=os.getpid(), runnerStart=[1, os.getpid()]),
                                 report={**self.job, 'status': 'running'})
        values = ['{', {**valid, 'vmId': 'other-vm'}, {**valid, 'unexpected': True},
                  {**valid, 'receipt': {**valid['receipt'], 'agentPID': os.getpid() + 1}},
                  {**valid, 'receipt': {**valid['receipt'], 'agentStart': [2, os.getpid()]}},
                  {**valid, 'report': {**valid['report'], 'runId': 'other-run'}},
                  {**valid, 'report': {**valid['report'], 'status': 'unknown'}}]
        for index, value in enumerate(values):
            with self.subTest(case=index):
                transport, now = self.begin_report_outage()
                self.report_responses({'code': 0, 'stdout': value if isinstance(value, str) else json.dumps(value)})
                self.report_attempt(now + 15)
                with patch.object(exchange_module.time, 'monotonic', return_value=now + 16):
                    result = transport.poll()
                self.assertEqual(result['reason'], 'guest_exchange_failed')
                info = self.transport_info()
                self.assertEqual(info['recoveredOutages'], 0)
                self.assertEqual(info['recentOutages'][0]['status'], 'failed')
                self.close_transport()
                shutil.rmtree(self.guest)
                self.guest.mkdir(mode=0o700)
                (self.exchange / 'guest-transport.json').unlink()

    def test_report_retry_journal_is_bounded_and_preserves_recovery_totals(self):
        transport = self.established()
        for index in range(20):
            transport.phase = 'report'
            transport.phase_started_at = time.monotonic()
            transport.output = transport._temporary_output()
            transport.errors = transport._temporary_output()
            transport.errors.write(self.banner_failure()['stderr'].replace('\r\n', '\n').encode())
            self.assertTrue(transport._retry_report_failure(255, time.monotonic()))
            self.assertEqual(transport.report_outage['event']['retryAttempts'], 0)
            transport._complete_report_outage('recovered')
        info = self.transport_info()
        self.assertEqual((info['outages'], info['recoveredOutages']), (20, 20))
        self.assertEqual(len(info['recentOutages']), 16)
        self.assertLess((self.exchange / 'guest-transport.json').stat().st_size, 8192)
        self.assertTrue(all(event['status'] == 'recovered' for event in info['recentOutages']))

    def test_direct_cancellation_preserves_pending_report_retry_diagnostics(self):
        transport, _ = self.begin_report_outage()
        transport.cancel()
        self.assertEqual(self.transport_info()['recentOutages'][0]['status'], 'cancelled')
        self.assertFalse(transport.scratch.exists())

    def test_report_retry_journal_failure_stops_new_child_and_redacts_the_error(self):
        transport, now = self.begin_report_outage()
        write = exchange_module._atomic_json
        def fail_journal(path, value):
            if Path(path).name == 'guest-transport.json':
                raise OSError('fixture guest password')
            return write(path, value)
        (self.guest_root / 'hold-report').touch()
        with patch.object(exchange_module, '_atomic_json', side_effect=fail_journal), \
                patch.object(exchange_module.access, '_stop', wraps=exchange_module.access._stop) as stop, \
                patch.object(exchange_module.time, 'monotonic', return_value=now + 15):
            result = transport.poll()
        self.assertEqual((result['reason'], result['error']), ('guest_exchange_failed', '[REDACTED]'))
        stop.assert_called_once()
        self.assertIsNotNone(stop.call_args.args[0].poll())
        self.assertIsNone(transport.child)
        self.assertEqual(transport.files, [])
        self.assertTrue(transport.report_journal_failed)

    def observation(self, receipt=None, report=None, alive=True):
        return {'version': 1, **{key: self.job[key] for key in ('runId', 'vmId')},
                'receipt': receipt, 'report': report, 'supervisorAlive': alive}

    def receipt(self, state='completed', **fields):
        return {'version': 1, **{key: self.job[key] for key in ('runId', 'vmId')},
                'agentPID': os.getpid(), 'agentStart': [1, os.getpid()], 'state': state, **fields}

    def test_receipt_completion_is_idempotent_and_missing_final_report_is_bounded(self):
        transport = self.start()
        self.uploaded()
        value = self.observation(self.receipt(exitCode=0), alive=False)
        transport._observe_report(value, 100)
        transport._observe_report(value, 120)
        self.assertEqual(transport.guest_finished_at, 100)
        self.assertEqual(transport._observation_failure(131), 'guest_exited_without_result')

    def test_unknown_launch_response_observes_receipt_without_relaunch(self):
        (self.guest_root / 'lose-launch-reply').touch()
        transport = self.start()
        self.uploaded()
        self.drive(lambda _: transport.observed_launch)
        self.assertEqual(transport.agent_pid, os.getpid())
        self.report(finished=True)
        transport.next_poll = 0
        self.assertEqual(self.drive(lambda value: value is not None)['status'], 'passed')
        calls = [json.loads(line) for line in (self.guest_root / 'launchctl-calls').read_text().splitlines()]
        self.assertEqual(sum(call[0] == 'kickstart' for call in calls), 1)

    def test_stop_while_waiting_for_gui_service_prevents_launch(self):
        (self.guest_root / 'service-unavailable').touch()
        transport = self.start()
        self.drive(lambda _: transport.phase == 'launch')
        transport.request_stop()
        result = self.drive(lambda value: value is not None)
        self.assertEqual(result['reason'], 'guest_exchange_cancelled')
        calls = self.guest_root / 'launchctl-calls'
        if calls.exists():
            self.assertFalse(any(json.loads(line)[0] == 'kickstart' for line in calls.read_text().splitlines()))

    def test_unknown_launch_without_receipt_is_bounded(self):
        (self.guest_root / 'launch-fails').touch()
        transport = self.start()
        self.uploaded()
        self.assertEqual(transport._observation_failure(transport.launched_at + 31), 'guest_launch_failed')
        self.assertFalse(transport.observed_launch)

    def test_invalid_receipt_and_envelope_cannot_publish_a_final_report(self):
        transport = self.start()
        self.uploaded()
        final = {**self.job, 'status': 'passed', 'finishedAt': 'done'}
        for key, invalid in [('vmId', 'wrong'), ('runId', 'wrong'), ('version', True), ('agentPID', True), ('state', 'unknown')]:
            with self.subTest(key=key):
                receipt = self.receipt(exitCode=0)
                receipt[key] = invalid
                with self.assertRaises(exchange_module.GuestExchangeError):
                    transport._observe_report(self.observation(receipt, final), time.monotonic())
        for key, invalid in [('vmId', 'wrong'), ('runId', 'wrong'), ('version', True), ('supervisorAlive', 1)]:
            with self.subTest(envelope=key):
                value = self.observation(report=final)
                value[key] = invalid
                with self.assertRaises(exchange_module.GuestExchangeError):
                    transport._observe_report(value, time.monotonic())
        self.assertFalse((self.exchange / 'artifacts/result.json').exists())

    def test_failed_receipt_reports_launch_failure_without_claiming_success(self):
        transport = self.start()
        self.uploaded()
        result = transport._observe_report(self.observation(self.receipt(state='failed',
            reason='guest_launch_failed', error='fixture guest password')), time.monotonic())
        self.assertEqual(result['reason'], 'guest_launch_failed')
        self.assertEqual(result['error'], '[REDACTED]')
        self.assertFalse((self.exchange / 'artifacts/result.json').exists())

    def test_upload_preserves_claims_and_refuses_active_or_same_run_exchange(self):
        receipts = self.guest / '.agent-runs'
        receipts.mkdir(mode=0o700)
        previous = self.receipt(exitCode=0)
        (receipts / 'fixture-run.json').write_text(json.dumps(previous))
        transport = self.start()
        result = self.drive(lambda value: value is not None)
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(json.loads((receipts / 'fixture-run.json').read_text()), previous)
        self.close_transport()
        (receipts / 'fixture-run.json').unlink()
        previous.update(runId='old', state='running', runnerPID=os.getpid(), runnerStart=[1, os.getpid()])
        previous.pop('exitCode')
        (receipts / 'old.json').write_text(json.dumps(previous))
        self.start()
        self.assertEqual(self.drive(lambda value: value is not None)['status'], 'failed')
        self.assertTrue((receipts / 'old.json').exists())
        self.close_transport()
        previous['agentStart'] = [2, os.getpid()]
        previous['runnerStart'] = [2, os.getpid()]
        (receipts / 'old.json').write_text(json.dumps(previous))
        self.start()
        self.uploaded()
        self.assertEqual(json.loads((receipts / 'old.json').read_text()), previous)

    def test_final_export_is_not_interrupted_by_terminal_report_grace(self):
        transport = self.start()
        self.uploaded()
        self.report(finished=True)
        (self.guest / '.agent-runs/fixture-run.json').write_text(json.dumps(self.receipt(exitCode=0)))
        (self.guest_root / 'identity-unavailable').touch()
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
