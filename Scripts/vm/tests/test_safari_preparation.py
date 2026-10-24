import contextlib
import copy
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import shutil
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location('safari_preparation_host', Path(__file__).resolve().parents[1] / 'host.py')
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)


def preparation_evidence(run_id):
    installation = '/Users/wallet-test/Applications/BigWalletSafariVM/Prepared'
    receipt = {'version': 1, 'status': 'passed', 'preparationRunID': run_id,
        'descriptor': {'version': 1, 'runID': run_id, 'root': f'/Volumes/BigWalletBuild/Exchange/{run_id}/safari/macos/Debug',
                       'platform': 'macos', 'signingMode': 'local', 'configuration': 'Debug'},
        'installationDirectory': installation,
        'sourceApp': '/Users/wallet-test/Library/Developer/Xcode/DerivedData/Wallet/Build/Products/Debug/Big Wallet.app',
        'signatures': {'app': {'identifier': 'org.lil.wallet', 'cdhash': 'a' * 40},
                       'extension': {'identifier': 'org.lil.wallet.Safari', 'cdhash': 'b' * 40},
                       'helper': {'identifier': 'org.lil.wallet.ambient', 'cdhash': 'c' * 40}},
        'enabledObservation': {'enabled': True, 'processID': 42,
            'executablePath': installation + '/Big Wallet.app/Contents/MacOS/Big Wallet',
            'preparationNonce': '12345678-1234-4123-8123-123456789abc', 'observedAt': '2026-10-20T10:00:00.000Z'},
        'cleanup': {'status': 'passed'}, 'preparedAt': '2026-10-20T10:00:01.000Z'}
    return {'version': 1, 'status': 'passed', 'preparationRunID': run_id, 'platform': 'macos',
            'configuration': 'Debug', 'signingMode': 'local', 'installationDirectory': installation,
            'receiptSHA256': hashlib.sha256(json.dumps(receipt, separators=(',', ':'), ensure_ascii=False).encode()).hexdigest(),
            'receipt': receipt}


class SafariPreparationTests(unittest.TestCase):
    def setUp(self):
        self.stack = contextlib.ExitStack()
        self.addCleanup(self.stack.close)
        self.state = Path(self.stack.enter_context(tempfile.TemporaryDirectory())).resolve()
        self.original = self.state / 'original.vbvm'
        self.baseline = self.state / 'baseline.vbvm'
        (self.baseline / '.vbdata').mkdir(parents=True)
        (self.baseline / 'Disk.img').write_bytes(b'original-baseline')
        (self.baseline / '.vbdata/Config.plist').write_bytes(plistlib.dumps({'sharedFolders': []}))
        self.args = host.parser().parse_args(['--vm', str(self.original), 'setup', '--interactive', '--safari-activation'])
        self.environment = host.read_json(host.TOOLS / 'environment.json')
        self.tools = {name: 'a' * 64 for name in ('VMGuestAgent', 'guest_runner', 'guest_bootstrap.mjs')}
        self.baseline_record = {'version': 1, 'vmId': 'fixture-vm', 'sourceVM': str(self.original),
            'environment': self.environment, 'consoleUser': 'wallet-test', 'verificationSigningMode': 'local',
            'verifiedAt': '2026-10-20T09:00:00Z', 'baseVerifiedAt': '2026-10-20T09:00:00Z',
            'bootstrapSourceDigest': host.bootstrap_source_digest(), 'bootstrapTools': self.tools}
        host.atomic_json(self.state / 'baseline.json', self.baseline_record)
        self.original_record_bytes = (self.state / 'baseline.json').read_bytes()
        self.calls = []
        self.failure = None
        self.corrupt_receipt = False
        self.exported = True
        self.stack.enter_context(patch('sys.stdout', new=io.StringIO()))
        for name, value in [('validate_vm', {'sharedFolders': []}), ('check_capacity', None),
                            ('ensure_disk_idle', None), ('build_tools', self.state / 'tools'),
                            ('bootstrap_tool_hashes', self.tools), ('verify_setup_sources', None),
                            ('environment_attested', True), ('prepared_guest_hook', None)]:
            self.stack.enter_context(patch.object(host, name, return_value=value))
        self.stack.enter_context(patch.object(host, 'clone_vm', side_effect=shutil.copytree))
        self.stack.enter_context(patch.object(host, 'snapshot_source', side_effect=self.snapshot))
        self.real_monitor = host.monitor_vm
        self.stack.enter_context(patch.object(host, 'monitor_vm', side_effect=self.monitor))
        self.stack.enter_context(patch.object(host, 'stage_provisioning', side_effect=AssertionError('No installer staging')))
        self.stack.enter_context(patch.object(host, 'cached_xcode_archive', side_effect=AssertionError('No Xcode archive')))
        self.stack.enter_context(patch.object(host, 'guest_access_module', side_effect=AssertionError('No host guest access in tests')))

    def snapshot(self, repository, exchange):
        paths = []
        for relative in ['Scripts/vm/test_manifest.mjs', 'Scripts/safari/scenarios.mjs', 'Scripts/safari/synchronization.mjs']:
            destination = exchange / 'source' / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(host.ROOT / relative, destination)
            paths.append({'path': relative, 'type': 'file', 'mode': 0o644, 'sha256': host.hash_regular_file(destination)})
        host.atomic_json(exchange / 'snapshot-manifest.json', {'version': 1, 'files': paths})
        return {'sha256': host.hash_regular_file(exchange / 'snapshot-manifest.json'), 'commit': 'b' * 40,
                'fileCount': len(paths), 'bytes': sum((exchange / 'source' / item['path']).stat().st_size for item in paths)}

    def monitor(self, args, state, vm, exchange, run_id, binaries, environment, timeout, **options):
        self.assertEqual((self.state / 'baseline.json').read_bytes(), self.original_record_bytes)
        self.assertEqual((self.baseline / 'Disk.img').read_bytes(), b'original-baseline')
        self.assertEqual(vm, self.state / 'candidate.vbvm')
        job = host.read_json(exchange / 'job.json')
        plan = host.read_json(exchange / 'artifacts/planned-result.json')
        self.calls.append(job)
        preparation = job['payload'].get('prepareSafari', False)
        if preparation:
            self.assertEqual(job['payload'], {'stages': ['safari'], 'configuration': 'Debug', 'signing': 'local',
                                              'onlyTesting': ['Safari UI Tests macOS'], 'prepareSafari': True})
            self.assertEqual([stage['id'] for stage in plan['stages']], [
                'provider.install', 'protocol.check', 'build-safari.macos.debug', 'prepare-safari.macos.debug'])
            self.assertTrue(all('nativeAudit' not in stage for stage in plan['stages']))
        else:
            self.assertTrue(all(selector.startswith('Tests macOS/') for selector in job['payload']['onlyTesting']))
            self.assertTrue(all(stage.get('nativeAudit', {}).get('platform', 'macos') == 'macos' for stage in plan['stages']))
        stages = [{**stage, 'status': 'passed', **({'audit': {'ok': True}} if 'nativeAudit' in stage else {})}
                  for stage in plan['stages']]
        report = {'version': 1, 'runId': run_id, 'vmId': job['vmId'],
            'source': {'files': job['source']['fileCount'], **job['source']}, 'status': 'passed',
            'finishedAt': '2026-10-20T10:00:02Z', 'identity': {'vmId': job['vmId'], 'consoleUser': 'wallet-test'},
            'preflight': {'bootstrap': {'available': True, 'hashes': self.tools}}, 'stages': stages}
        if preparation:
            value = preparation_evidence(run_id)
            if self.corrupt_receipt:
                value['receipt']['enabledObservation']['enabled'] = False
                value['receiptSHA256'] = hashlib.sha256(json.dumps(value['receipt'], separators=(',', ':')).encode()).hexdigest()
            filename = 'prepare-safari.macos.debug.safari-preparation.json'
            (exchange / 'artifacts' / filename).write_text(json.dumps(value, separators=(',', ':'), ensure_ascii=False))
            reference = {key: value[key] for key in ('preparationRunID', 'receiptSHA256')}
            stages[-1].update({'preparationResult': filename,
                'preparationSHA256': host.hash_regular_file(exchange / 'artifacts' / filename),
                'audit': {'ok': True, 'preparation': reference}})
        if self.failure == ('prepare' if preparation else 'native'):
            report['status'] = stages[-1]['status'] = 'failed'
        if self.failure == 'identity':
            report['identity']['vmId'] = 'other-vm'
        if self.failure == 'source-files':
            report['source']['files'] += 1
        host.atomic_json(exchange / 'artifacts/result.json', report)
        active = host.read_json(state / 'active.json')
        active['phase'] = 'starting'
        active['artifactsExported'] = self.exported
        active['acceptedResultSHA256'] = host.hash_regular_file(exchange / 'artifacts/result.json')
        host.atomic_json(state / 'active.json', active)
        return report

    def test_focused_setup_promotes_only_after_native_smoke_and_audited_preparation(self):
        self.assertEqual(host.setup(self.args, self.state, self.environment), 0)
        self.assertEqual(len(self.calls), 2)
        result = host.read_json(self.state / 'baseline.json')
        self.assertEqual(result['safariPreparation']['preparationRunID'], self.calls[-1]['runId'])
        self.assertIn('setup-validation-', result['validationResult'])
        self.assertIn('setup-safari-preparation-', result['safariPreparationResult'])
        self.assertFalse((self.state / 'candidate.json').exists())
        self.assertFalse((self.state / 'active.json').exists())
        self.assertEqual(len(list(self.state.glob('previous-baseline-*.vbvm'))), 1)

    def test_native_failure_never_runs_preparation_or_changes_the_baseline(self):
        self.failure = 'native'
        self.assertEqual(host.setup(self.args, self.state, self.environment), 2)
        self.assertEqual(len(self.calls), 1)
        self.assertEqual((self.state / 'baseline.json').read_bytes(), self.original_record_bytes)
        self.assertTrue((self.state / 'candidate.vbvm').exists())
        self.assertFalse(list(self.state.glob('previous-baseline-*.vbvm')))

    def test_mismatched_verified_source_count_cannot_start_preparation(self):
        self.failure = 'source-files'
        self.assertEqual(host.setup(self.args, self.state, self.environment), 2)
        self.assertEqual(len(self.calls), 1)
        self.assertEqual((self.state / 'baseline.json').read_bytes(), self.original_record_bytes)
        attempt = host.read_json(self.state / 'candidate.json')['safariActivationAttempt']
        report = host.read_json(Path(attempt['result']))
        self.assertEqual(report['reason'], 'safari_preparation_guest_validation_did_not_match_requested_setup')
        self.assertEqual(attempt['resultSHA256'], host.hash_regular_file(Path(attempt['result'])))

    def test_invalid_preparation_receipt_or_guest_identity_cannot_promote(self):
        self.corrupt_receipt = True
        self.assertEqual(host.setup(self.args, self.state, self.environment), 2)
        self.assertEqual((self.state / 'baseline.json').read_bytes(), self.original_record_bytes)
        candidate = host.read_json(self.state / 'candidate.json')
        self.assertNotIn('safariPreparation', candidate)
        result = host.read_json(Path(candidate['safariActivationAttempt']['result']))
        self.assertEqual(result['reason'], 'safari_preparation_receipt_invalid')

    def test_failed_owned_candidate_with_archived_diagnostics_restarts_from_the_baseline(self):
        self.failure = 'prepare'
        self.assertEqual(host.setup(self.args, self.state, self.environment), 2)
        (self.state / 'candidate.vbvm' / 'failed-attempt-only').write_text('fixture')
        self.failure = None
        self.assertEqual(host.setup(self.args, self.state, self.environment), 0)
        self.assertFalse((self.baseline / 'failed-attempt-only').exists())
        self.assertEqual(len(self.calls), 4)

    def test_cancel_while_removing_failed_candidate_can_retry(self):
        self.failure = 'prepare'
        self.assertEqual(host.setup(self.args, self.state, self.environment), 2)
        self.failure = None
        candidate = self.state / 'candidate.vbvm'
        remove = shutil.rmtree

        def interrupted_remove(path, *args, **kwargs):
            remove(path, *args, **kwargs)
            if path == candidate:
                raise KeyboardInterrupt

        with patch.object(host.shutil, 'rmtree', side_effect=interrupted_remove):
            self.assertEqual(host.setup(self.args, self.state, self.environment), 2)
        self.assertFalse(candidate.exists())
        self.assertEqual((self.state / 'baseline.json').read_bytes(), self.original_record_bytes)
        self.assertEqual(host.setup(self.args, self.state, self.environment), 0)
        self.assertEqual(len(self.calls), 4)

    def test_cancel_before_first_vm_launch_can_retry(self):
        def snapshot(repository, exchange):
            source = self.snapshot(repository, exchange)
            host.publish_stop(exchange, host.read_json(self.state / 'active.json')['runId'], requested=True)
            return source

        with patch.object(host, 'snapshot_source', side_effect=snapshot):
            self.assertEqual(host.setup(self.args, self.state, self.environment), 2)
        self.assertEqual(self.calls, [])
        self.assertEqual(host.setup(self.args, self.state, self.environment), 0)
        self.assertEqual(len(self.calls), 2)

    def test_cancel_before_second_vm_launch_preserves_first_report(self):
        def snapshot(repository, exchange):
            source = self.snapshot(repository, exchange)
            if self.calls:
                host.publish_stop(exchange, host.read_json(self.state / 'active.json')['runId'], requested=True)
            return source

        with patch.object(host, 'snapshot_source', side_effect=snapshot):
            self.assertEqual(host.setup(self.args, self.state, self.environment), 2)
        self.assertEqual(len(self.calls), 1)
        attempt = host.read_json(self.state / 'candidate.json')['safariActivationAttempt']
        self.assertEqual(attempt['runId'], self.calls[0]['runId'])
        self.assertEqual(attempt['resultSHA256'], host.hash_regular_file(Path(attempt['result'])))
        self.assertEqual(host.read_json(Path(attempt['result']))['status'], 'passed')
        self.assertEqual(host.setup(self.args, self.state, self.environment), 0)

    def test_cancel_after_attempt_is_saved_but_before_monitor_starts_can_retry(self):
        with patch.object(host, 'monitor_vm', side_effect=KeyboardInterrupt):
            self.assertEqual(host.setup(self.args, self.state, self.environment), 2)
        self.assertEqual(self.calls, [])
        self.assertEqual(host.setup(self.args, self.state, self.environment), 0)

    def test_stop_observed_inside_monitor_before_vm_launch_can_retry(self):
        def hook(state, candidate, record, exchange):
            host.publish_stop(exchange, host.read_json(state / 'active.json')['runId'], requested=True)
            return SimpleNamespace(exchange_complete=False)

        def monitor(*args, **kwargs):
            with patch.object(host, 'setup_viewer_binary', return_value=self.state / 'VMHost'), \
                    patch.object(host.subprocess, 'Popen', side_effect=AssertionError('Unexpected VM launch')) as launch:
                result = self.real_monitor(*args, **kwargs)
                launch.assert_not_called()
                return result

        with patch.object(host, 'prepared_guest_hook', side_effect=hook), \
                patch.object(host, 'monitor_vm', side_effect=monitor):
            self.assertEqual(host.setup(self.args, self.state, self.environment), 2)
        attempt = host.read_json(self.state / 'candidate.json')['safariActivationAttempt']
        self.assertTrue(attempt['artifactsExported'])
        self.assertEqual(host.read_json(Path(attempt['result']))['status'], 'cancelled')
        self.assertEqual(host.setup(self.args, self.state, self.environment), 0)

    def test_cancel_after_export_refreshes_report_hash_and_can_retry(self):
        def monitor(*args, **kwargs):
            result = self.monitor(*args, **kwargs)
            host.publish_stop(args[3], args[4], requested=True)
            return result

        with patch.object(host, 'monitor_vm', side_effect=monitor):
            self.assertEqual(host.setup(self.args, self.state, self.environment), 2)
        attempt = host.read_json(self.state / 'candidate.json')['safariActivationAttempt']
        self.assertTrue(attempt['artifactsExported'])
        self.assertEqual(host.read_json(Path(attempt['result']))['status'], 'cancelled')
        self.assertEqual(attempt['resultSHA256'], host.hash_regular_file(Path(attempt['result'])))
        self.assertEqual(host.setup(self.args, self.state, self.environment), 0)

    def test_cancel_after_uncollected_report_preserves_the_candidate(self):
        self.exported = False

        def monitor(*args, **kwargs):
            result = self.monitor(*args, **kwargs)
            host.publish_stop(args[3], args[4], requested=True)
            return result

        with patch.object(host, 'monitor_vm', side_effect=monitor):
            self.assertEqual(host.setup(self.args, self.state, self.environment), 2)
        with self.assertRaisesRegex(host.RunnerError, 'uncollected or unverified'):
            host.setup(self.args, self.state, self.environment)
        self.assertEqual(len(self.calls), 1)

    def test_uncertain_diagnostics_preserve_the_failed_candidate(self):
        self.failure = 'prepare'
        self.exported = False
        self.assertEqual(host.setup(self.args, self.state, self.environment), 2)
        with self.assertRaisesRegex(host.RunnerError, 'uncollected or unverified'):
            host.setup(self.args, self.state, self.environment)
        self.assertEqual(len(self.calls), 2)
        self.assertEqual((self.state / 'baseline.json').read_bytes(), self.original_record_bytes)

    def test_activation_requires_interactive_current_baseline_and_no_provisioning_inputs(self):
        self.args.interactive = False
        with self.assertRaisesRegex(host.RunnerError, 'requires --interactive'):
            host.setup(self.args, self.state, self.environment)
        self.args.interactive = True
        self.args.provision_config = self.state / 'input.json'
        with self.assertRaisesRegex(host.RunnerError, 'no provisioning inputs'):
            host.setup(self.args, self.state, self.environment)
        self.args.provision_config = None
        changed = copy.deepcopy(self.baseline_record)
        changed['bootstrapSourceDigest'] = 'old'
        host.atomic_json(self.state / 'baseline.json', changed)
        with self.assertRaisesRegex(host.RunnerError, 'ordinary setup first'):
            host.setup(self.args, self.state, self.environment)
        self.assertEqual(self.calls, [])
        self.assertFalse((self.state / 'candidate.vbvm').exists())

    def test_prepared_reference_is_added_only_to_selected_local_macos_runtime_jobs(self):
        reference = {'preparationRunID': 'setup-prepared-fixture', 'receiptSHA256': 'f' * 64}
        record = {'safariPreparation': reference}
        macos = {'stages': [{'nativeAudit': {'kind': 'safari', 'platform': 'macos'}}]}
        self.assertEqual(host.prepared_safari_for_job(record, {'payload': {}}, macos), reference)
        for plan in [{'stages': []}, {'stages': [{'id': 'build-safari.macos.debug'}]},
                     {'stages': [{'nativeAudit': {'kind': 'safari', 'platform': 'ios'}}]},
                     {'stages': [{'nativeAudit': {'kind': 'full', 'platform': 'macos'}}]}]:
            self.assertIsNone(host.prepared_safari_for_job(record, {'payload': {}}, plan))
        self.assertIsNone(host.prepared_safari_for_job(record, {'payload': {'signing': 'apple'}}, macos))
        with self.assertRaisesRegex(host.RunnerError, 'omit --interactive-safari'):
            host.prepared_safari_for_job(record, {'payload': {'interactiveSafari': True}}, macos)


if __name__ == '__main__':
    unittest.main()
