import importlib.util
import io
from pathlib import Path
import shutil
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location('setup_validation_host', Path(__file__).resolve().parents[1] / 'host.py')
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)


class SetupValidationInventoryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.state = Path(self.temporary.name).resolve()
        self.args = host.parser().parse_args(['--vm', str(self.state / 'original.vbvm'), 'setup'])
        self.candidate = self.state / 'candidate.vbvm'
        self.candidate.mkdir()
        self.environment = {'minimumHostFreeBytes': 1, 'buildData': {'bytes': 96 * 1024 ** 3}}
        host.atomic_json(self.state / 'candidate.json', {'version': 1, 'vmId': 'fixture-vm',
                         'sourceVM': str(self.args.vm), 'environment': self.environment})
        self.bootstrap_tools = {name: 'a' * 64 for name in
                             ('VMGuestAgent', 'guest_runner', 'guest_bootstrap.mjs')}

    def snapshot(self, repository, exchange):
        manifest = exchange / 'source/Scripts/vm/test_manifest.mjs'
        manifest.parent.mkdir(parents=True)
        shutil.copyfile(host.TOOLS / 'test_manifest.mjs', manifest)
        host.atomic_json(exchange / 'snapshot-manifest.json', {'version': 1, 'files': [
            {'path': 'Scripts/vm/test_manifest.mjs', 'type': 'file', 'mode': 0o644,
             'sha256': host.hash_regular_file(manifest)}]})
        return {'sha256': host.hash_regular_file(exchange / 'snapshot-manifest.json'), 'commit': 'b' * 40}

    def test_validation_launch_failure_keeps_selected_inventory_and_cannot_promote_baseline(self):
        original_monitor = host.monitor_vm
        calls = []
        validation = {}
        def monitor(args, state, vm, exchange, run_id, binaries, environment, timeout, provision_password=None, **options):
            job = host.read_json(exchange / 'job.json')
            calls.append(job['kind'])
            if job['kind'] == 'doctor':
                self.assertFalse((exchange / 'artifacts/planned-result.json').exists())
                return {'status': 'passed', 'identity': {'vmId': 'fixture-vm', 'consoleUser': 'wallet-test'}, 'preflight': {
                    'bootstrap': {'available': True, 'hashes': self.bootstrap_tools},
                    'checks': {name: True for name in ('bootstrap', 'node', 'python', 'jq', 'xcode', 'macos', 'ios', 'visionos')},
                }}
            self.assertEqual(job['kind'], 'run')
            self.assertTrue(run_id.startswith('setup-validation-'))
            planned = host.read_json(exchange / 'artifacts/planned-result.json')
            self.assertEqual(planned['status'], 'planned')
            self.assertEqual(planned['origin'], 'host-plan')
            self.assertEqual(planned['source'], job['source'])
            self.assertFalse((exchange / 'artifacts/result.json').exists())
            with patch.object(host.subprocess, 'Popen', side_effect=OSError('fixture: launcher unavailable')) as launch, \
                    patch.object(host, 'stop_owned_process') as stop:
                result = original_monitor(args, state, vm, exchange, run_id, binaries, environment, timeout, **options)
            launch.assert_called_once()
            stop.assert_not_called()
            validation.update(exchange=exchange, job=job, planned=planned, result=result)
            return result
        def doctor(args, state, candidate, environment, operation, record, configuration,
                   binaries, bootstrap_tools, source, password, source_digest):
            run_id, exchange = operation['runId'], operation['exchange']
            host.atomic_json(exchange / 'job.json', {'version': 1, 'runId': run_id, 'vmId': record['vmId'],
                'kind': 'doctor', 'profile': 'all', 'stages': [], 'onlyTesting': [], 'source': source,
                'bootstrapTools': bootstrap_tools})
            operation['monitorCalled'] = True
            return host.monitor_vm(args, state, candidate, exchange, run_id, binaries, environment,
                args.timeout or 120, password, keep_operation=True, previous_stops=operation['previousStops']), exchange
        with patch.object(host, 'validate_vm', return_value={}), patch.object(host, 'check_capacity'), \
                patch.object(host, 'build_tools', return_value=self.state / 'tools'), \
                patch.object(host, 'bootstrap_tool_hashes', return_value=self.bootstrap_tools), \
                patch.object(host, 'configure_build_storage', return_value=False), \
                patch.object(host, 'ensure_disk_idle'), patch.object(host, 'configure_guest_hardware'), \
                patch.object(host, 'stage_provisioning', return_value={'consoleUser': 'wallet-test'}), \
                patch.object(host, 'snapshot_source', side_effect=self.snapshot), \
                patch.object(host, 'verify_setup_sources'), \
                patch.object(host, 'environment_attested', return_value=True), \
                patch.object(host, 'run_setup_doctor', side_effect=doctor), \
                patch.object(host, 'guest_access_module', side_effect=AssertionError('No disk access or SSH in validation fixtures')), \
                patch.object(host, 'prepared_guest_hook', return_value=None), \
                patch.object(host, 'monitor_vm', side_effect=monitor), patch('sys.stdout', new=io.StringIO()), \
                patch.object(host, 'checked', wraps=host.checked) as commands:
            self.assertEqual(host.setup(self.args, self.state, self.environment), 2)
        self.assertEqual(calls, ['doctor', 'run'])
        self.assertEqual(len(commands.call_args_list), 2)
        self.assertTrue(all(Path(call.args[0][0]).name == 'node' for call in commands.call_args_list))
        result, planned, job = validation['result'], validation['planned'], validation['job']
        self.assertEqual(result['status'], 'failed')
        self.assertEqual(result['reason'], 'vm_launch_failed')
        self.assertEqual(result['plannedResult'], 'planned-result.json')
        self.assertEqual(result['selection'], {
            'stages': ['test'], 'configuration': 'Debug',
            'onlyTesting': ['WindowAuthenticationSessionTests', 'PasswordStorageTests', 'SecretHandlingTests'],
        })
        self.assertEqual(result['source'], job['source'])
        self.assertEqual([stage['id'] for stage in result['stages']], [stage['id'] for stage in planned['stages']])
        self.assertEqual({stage['id'] for stage in result['stages']}, {
            'provider.install', 'protocol.check', 'provider.test',
            'build-tests.macos.debug', 'test.macos.debug', 'build-tests.ios.debug', 'test.ios.debug',
            'build-tests.visionos.debug', 'test.visionos.debug',
        })
        self.assertTrue(all(stage['status'] == 'blocked' for stage in result['stages']))
        self.assertEqual(result['summary']['counts']['blocked'], len(planned['stages']))
        self.assertEqual(result['coverage']['status'], 'partial')
        self.assertFalse(result['coverage']['fullSuiteVerified'])
        self.assertEqual(host.read_json(validation['exchange'] / 'artifacts/planned-result.json'), planned)
        self.assertEqual(host.read_json(validation['exchange'] / 'artifacts/result.json'), result)
        self.assertTrue(self.candidate.exists())
        self.assertTrue((self.state / 'candidate.json').exists())
        self.assertFalse((self.state / 'baseline.json').exists())
        self.assertFalse((self.state / 'baseline.vbvm').exists())
        self.assertFalse((self.state / 'active.json').exists())
