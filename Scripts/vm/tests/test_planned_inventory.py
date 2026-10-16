import importlib.util
from contextlib import contextmanager
import io
import itertools
import json
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location('planned_inventory_host', Path(__file__).resolve().parents[1] / 'host.py')
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)


class RunSnapshotBindingTests(unittest.TestCase):
    sources = ('VMGuestAgent.swift', 'guest_runner', 'guest.mjs', 'test_manifest.mjs',
               'result_audit.mjs', 'provision_guest.sh', 'environment.json')

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.repository = self.root / 'repository'
        self.tools = self.repository / 'Scripts/vm'
        self.tools.mkdir(parents=True)
        for name in (*self.sources, 'plan_manifest.mjs'):
            shutil.copyfile(host.TOOLS / name, self.tools / name)
        for arguments in (('init', '-q'), ('config', 'user.email', 'fixture@example.invalid'),
                          ('config', 'user.name', 'Fixture'), ('add', '.'), ('commit', '-qm', 'fixture')):
            subprocess.run(['git', '-C', str(self.repository), *arguments], check=True, capture_output=True)
        self.state = self.root / 'state'
        self.state.mkdir()
        binaries = self.root / 'binaries'
        binaries.mkdir()
        (binaries / 'VMGuestAgent').write_bytes(b'fixture compiled agent')
        self.args = host.parser().parse_args(['--vm', str(self.root / 'original.vbvm'), 'run', '--stage', 'worker'])
        self.environment = host.read_json(self.tools / 'environment.json')
        for name, value in (('ROOT', self.repository), ('TOOLS', self.tools)):
            patcher = patch.object(host, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)
        host.atomic_json(self.state / 'baseline.json', {'vmId': 'fixture-vm', 'sourceVM': str(self.args.vm),
            'environment': self.environment, 'runnerSourceDigest': host.runner_source_digest(),
            'runnerTools': host.guest_tool_hashes(binaries)})
        for name, options in (
                ('check_capacity', {}), ('build_tools', {'return_value': binaries}),
                ('prepared_guest_hook', {'return_value': None}), ('ensure_disk_idle', {}),
                ('clone_vm', {'side_effect': lambda source, destination: destination.mkdir()}),
                ('monitor_vm', {'side_effect': self.complete_run})):
            patcher = patch.object(host, name, **options)
            setattr(self, name, patcher.start())
            self.addCleanup(patcher.stop)
        output = patch('sys.stdout', new=io.StringIO())
        output.start()
        self.addCleanup(output.stop)

    def complete_run(self, args, state, vm, exchange, run_id, *rest, **options):
        result = {'runId': run_id, 'status': 'passed', 'finishedAt': 'fixture completion'}
        host.atomic_json(exchange / 'artifacts/result.json', result)
        host.register_operation(state, vm, exchange, run_id, 'starting')
        active = host.read_json(state / 'active.json')
        active.update({'artifactsExported': True,
                       'acceptedResultSHA256': host.hash_regular_file(exchange / 'artifacts/result.json')})
        host.atomic_json(state / 'active.json', active)
        return result

    def test_runner_edits_captured_during_snapshot_block_before_clone_or_boot(self):
        snapshot = host.snapshot_source
        for name in self.sources:
            with self.subTest(source=name):
                path = self.tools / name
                original = path.read_bytes()
                exchanges = []
                def snapshot_after_edit(repository, exchange):
                    exchanges.append(exchange)
                    path.write_bytes(original + b'\nfixture source edit\n')
                    return snapshot(repository, exchange)
                try:
                    with patch.object(host, 'snapshot_source', side_effect=snapshot_after_edit):
                        self.assertEqual(host.run_tests(self.args, self.state, self.environment), 1)
                    report = host.read_json(exchanges[0] / 'artifacts/result.json')
                    self.assertEqual(report['reason'], 'host_preparation_failed')
                    self.assertIn('snapshotted guest setup/tools', report['hostTermination']['error'])
                    self.clone_vm.assert_not_called()
                    self.monitor_vm.assert_not_called()
                    self.assertFalse((self.state / 'active.json').exists())
                finally:
                    path.write_bytes(original)

    def test_later_workspace_edits_do_not_invalidate_the_verified_frozen_snapshot(self):
        snapshot = host.snapshot_source
        originals = {name: (self.tools / name).read_bytes() for name in self.sources}
        exchanges = []
        def snapshot_before_edits(repository, exchange):
            source = snapshot(repository, exchange)
            exchanges.append(exchange)
            for name, contents in originals.items():
                (self.tools / name).write_bytes(contents + b'\nfixture later edit\n')
            return source
        with patch.object(host, 'snapshot_source', side_effect=snapshot_before_edits):
            self.assertEqual(host.run_tests(self.args, self.state, self.environment), 0)
        self.clone_vm.assert_called_once()
        self.monitor_vm.assert_called_once()
        for name, contents in originals.items():
            self.assertEqual((exchanges[0] / 'source/Scripts/vm' / name).read_bytes(), contents)
        self.assertFalse((self.state / 'active.json').exists())


class PlannedInventoryTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        guest_hook = patch.object(host, 'prepared_guest_hook', return_value=None)
        guest_hook.start()
        self.addCleanup(guest_hook.stop)
        self.root = Path(self.temporary.name).resolve()
        self.environment = {'minimumHostFreeBytes': 1}
        self.exchange = self.root / 'results/plan-fixture'
        (self.exchange / 'artifacts').mkdir(parents=True)
        self.manifest = self.exchange / 'source/Scripts/vm/test_manifest.mjs'
        self.manifest.parent.mkdir(parents=True)
        shutil.copyfile(host.TOOLS / 'test_manifest.mjs', self.manifest)
        digest = host.hash_regular_file(self.manifest)
        host.atomic_json(self.exchange / 'snapshot-manifest.json', {'version': 1, 'files': [
            {'path': 'Scripts/vm/test_manifest.mjs', 'type': 'file', 'mode': 0o644, 'sha256': digest}]})
        self.job = {'version': 1, 'runId': 'plan-fixture', 'vmId': 'fixture-vm', 'kind': 'run',
                    'profile': 'all', 'stages': [], 'onlyTesting': [],
                    'source': {'sha256': host.hash_regular_file(self.exchange / 'snapshot-manifest.json'), 'commit': 'b' * 40},
                    'runnerTools': {name: 'a' * 64 for name in
                                    ('VMGuestAgent', 'guest_runner', 'guest.mjs', 'test_manifest.mjs', 'result_audit.mjs')}}
        self.job['runnerTools']['test_manifest.mjs'] = digest
        host.atomic_json(self.exchange / 'job.json', self.job)

    def plan(self, **overrides):
        job = {**self.job, **overrides}
        host.atomic_json(self.exchange / 'job.json', job)
        return host.stage_planned_result(self.exchange, job)

    def guest_inventory(self, job):
        code = '''
            import {readFileSync} from 'node:fs';
            import {pathToFileURL} from 'node:url';
            const {createManifest} = await import(pathToFileURL(process.argv[1]).href);
            const {pendingStageResults} = await import(pathToFileURL(process.argv[2]).href);
            process.stdout.write(JSON.stringify(pendingStageResults(createManifest(JSON.parse(readFileSync(0, 'utf8'))))));
        '''
        result = subprocess.run([shutil.which('node'), '--input-type=module', '--eval', code,
                                 str(self.manifest), str(host.TOOLS / 'guest.mjs')],
                                input=json.dumps(job), capture_output=True, text=True, check=True, timeout=30)
        return json.loads(result.stdout)

    @contextmanager
    def cloning_fixture(self, clone, idle_error=None):
        args = host.parser().parse_args(['run', 'all', '--stage', 'test', '--configuration', 'Debug',
                                         '--only-testing', 'Tests visionOS'])
        host.atomic_json(self.root / 'baseline.json', {'vmId': self.job['vmId'], 'environment': self.environment,
                         'sourceVM': str(args.vm), 'runnerSourceDigest': 'digest', 'runnerTools': self.job['runnerTools']})
        with patch.object(host, 'runner_source_digest', return_value='digest'), \
                patch.object(host, 'check_capacity'), patch.object(host, 'build_tools', return_value=self.root / 'tools'), \
                patch.object(host, 'guest_tool_hashes', return_value=self.job['runnerTools']), \
                patch.object(host, 'new_exchange', return_value=(self.job['runId'], self.exchange)), \
                patch.object(host, 'snapshot_source', return_value=self.job['source']), \
                patch.object(host, 'clone_vm', side_effect=clone) as copy, \
                patch.object(host, 'monitor_vm', side_effect=AssertionError('A VM was launched')) as boot, \
                patch.object(host, 'ensure_disk_idle', side_effect=idle_error) as idle, \
                patch.object(host.shutil, 'rmtree', wraps=host.shutil.rmtree) as remove, \
                patch('sys.stdout', new=io.StringIO()):
            yield args, copy, boot, idle, remove

    def test_plans_match_guest_inventory_for_profiles_dependencies_and_native_filters(self):
        cases = [
            {},
            {'profile': 'extended'},
            {'stages': ['repository', 'worker']},
            {'stages': ['test'], 'configuration': 'Debug', 'onlyTesting': ['Tests visionOS']},
            {'stages': ['test'], 'configuration': 'Debug', 'onlyTesting': ['Tests iOS/SecretHandlingTests/testSecretBufferIsZeroed']},
            {'profile': 'extended', 'stages': ['approval'], 'configuration': 'Release', 'approvalArgs': ['--soak', '--seed', '42']},
        ]
        for overrides in cases:
            with self.subTest(selection=overrides), patch.object(host, 'checked', wraps=host.checked) as commands:
                plan = self.plan(**overrides)
                self.assertEqual(plan['stages'], self.guest_inventory({**self.job, **overrides}))
                self.assertEqual(plan['status'], 'planned')
                self.assertEqual(plan['origin'], 'host-plan')
                self.assertNotIn('finishedAt', plan)
                self.assertFalse((self.exchange / 'artifacts/result.json').exists())
                self.assertEqual(plan['source'], self.job['source'])
                self.assertEqual(plan['selection']['onlyTesting'], overrides.get('onlyTesting', []))
                self.assertEqual(len(commands.call_args_list), 2)
                self.assertTrue(all(Path(call.args[0][0]).name == 'node' for call in commands.call_args_list))
                ids = {stage['id'] for stage in plan['stages']}
                if overrides.get('onlyTesting') == ['Tests visionOS']:
                    self.assertTrue({'provider.install', 'protocol.check', 'build-tests.visionos.debug',
                                     'test.visionos.debug', 'performance.visionos.release'} <= ids)
                    self.assertFalse(any('.ios.' in identifier or '.macos.' in identifier for identifier in ids))
                if overrides.get('onlyTesting', [''])[0].startswith('Tests iOS/'):
                    self.assertIn('build-tests.ios.debug', ids)
                    self.assertFalse(any(identifier.startswith('performance.') for identifier in ids))
                if overrides == {'profile': 'extended'}:
                    self.assertTrue({'tsan.extended', 'fuzz.seed-42', 'fuzz.seed-20261013',
                                     'fuzz.seed-3735928559', 'approval.soak-debug', 'approval.soak-release'} <= ids)

    def test_source_or_guest_manifest_drift_prevents_any_planning_command(self):
        for filename in (self.exchange / 'snapshot-manifest.json', self.manifest):
            with self.subTest(filename=filename.name):
                original = filename.read_bytes()
                filename.write_bytes(original + b'\n')
                with patch.object(host, 'checked', side_effect=AssertionError('A host command was started')):
                    with self.assertRaises(host.RunnerError):
                        host.stage_planned_result(self.exchange, self.job)
                filename.write_bytes(original)
        self.assertFalse((self.exchange / 'artifacts/planned-result.json').exists())

    def test_cold_stop_agent_failure_and_vm_exit_keep_every_planned_stage(self):
        for trigger, reason, status in (('stop', 'cancelled', 'cancelled'),
                                        ('agent', 'guest_launch_failed', 'failed'), ('exit', 'vm_exited', 'blocked')):
            with self.subTest(trigger=trigger):
                for name in ('stop.json', 'vm-stop', 'vm-status.json', 'artifacts/result.json'):
                    (self.exchange / name).unlink(missing_ok=True)
                plan = self.plan(stages=['test'], configuration='Debug', onlyTesting=['Tests visionOS'])
                if trigger == 'stop':
                    host.atomic_json(self.exchange / 'stop.json', {'runId': self.job['runId']})
                class Child:
                    def poll(self): return 0 if trigger == 'exit' else None
                    def wait(self, timeout=None): return 0
                clock = itertools.count()
                with patch.object(host.subprocess, 'Popen', return_value=Child()), \
                        patch.object(host.time, 'monotonic', side_effect=lambda: next(clock)), \
                        patch.object(host.time, 'sleep'), patch.object(host, 'check_capacity', return_value=100):
                    result = host.monitor_vm(SimpleNamespace(command='run'), self.root, self.root / 'unused.vbvm',
                                             self.exchange, self.job['runId'], self.root, {}, 100,
                                             setup_hook=SimpleNamespace(exchange_complete=False,
                                                 poll=lambda: {'status': 'failed', 'reason': 'guest_launch_failed'},
                                                 request_stop=lambda: None, cancel=lambda: None) if trigger == 'agent' else None)
                self.assertEqual(result['status'], status)
                self.assertEqual(result['hostTermination']['reason'], reason)
                self.assertEqual([stage['id'] for stage in result['stages']], [stage['id'] for stage in plan['stages']])
                self.assertEqual({stage['status'] for stage in result['stages']}, {'cancelled' if trigger == 'stop' else 'blocked'})
                self.assertEqual(result['source'], plan['source'])
                self.assertEqual(result['selection'], plan['selection'])
                self.assertEqual(result['plannedResult'], 'planned-result.json')
                self.assertNotIn('interruptedGuestResult', result)
                self.assertEqual(result['coverage']['status'], 'partial')
                self.assertFalse(result['coverage']['fullSuiteVerified'])
                self.assertEqual(len(result['coverage']['incompleteStages']), len(plan['stages']))
                self.assertEqual(host.read_json(self.exchange / 'artifacts/planned-result.json'), plan)

    def test_interrupted_reconciliation_uses_plan_when_guest_never_reported(self):
        plan = self.plan(stages=['approval'], configuration='Release')
        vm = self.root / 'runs/plan-fixture.vbvm'
        vm.mkdir(parents=True)
        host.atomic_json(self.root / 'active.json', {'runId': self.job['runId'], 'exchange': str(self.exchange), 'vm': str(vm), 'cloneOwned': True, 'phase': 'preparing'})
        with patch.object(host, 'ensure_disk_idle') as idle:
            host.reconcile_interrupted_operation(self.root)
        idle.assert_called_once_with(vm)
        result = host.read_json(self.exchange / 'artifacts/result.json')
        self.assertEqual(result['reason'], 'host_runner_interrupted')
        self.assertEqual(len(result['stages']), len(plan['stages']))
        self.assertTrue(all(stage['status'] == 'blocked' for stage in result['stages']))
        self.assertEqual(result['plannedResult'], 'planned-result.json')
        self.assertFalse(vm.exists())
        self.assertFalse((self.root / 'active.json').exists())

    def test_fallback_rejects_a_plan_that_no_longer_matches_the_job(self):
        self.plan()
        changed = {**self.job, 'source': {**self.job['source'], 'sha256': 'c' * 64}}
        host.atomic_json(self.exchange / 'job.json', changed)
        with self.assertRaisesRegex(host.RunnerError, 'planned inventory does not match'):
            host.finalize_interrupted_result(self.exchange, self.job['runId'], 'cancelled')
        self.assertFalse((self.exchange / 'artifacts/result.json').exists())

    def test_filter_changes_cannot_reuse_an_inventory_from_the_same_source(self):
        self.plan()
        host.atomic_json(self.exchange / 'job.json', {**self.job, 'onlyTesting': ['Tests iOS']})
        with self.assertRaisesRegex(host.RunnerError, 'planned inventory does not match'):
            host.finalize_interrupted_result(self.exchange, self.job['runId'], 'cancelled')
        self.assertFalse((self.exchange / 'artifacts/result.json').exists())

    def test_run_stages_the_inventory_before_clone_and_boot_without_executing_stage_commands(self):
        args = host.parser().parse_args(['run', 'all', '--stage', 'test', '--configuration', 'Debug',
                                         '--only-testing', 'Tests visionOS'])
        host.atomic_json(self.root / 'baseline.json', {'vmId': self.job['vmId'], 'environment': self.environment,
                         'sourceVM': str(args.vm), 'runnerSourceDigest': 'digest', 'runnerTools': self.job['runnerTools']})
        events = []
        def clone(source, destination):
            self.assertTrue((self.exchange / 'artifacts/planned-result.json').exists())
            self.assertFalse((self.exchange / 'artifacts/result.json').exists())
            self.assertIs(host.read_json(self.root / 'active.json')['cloneOwned'], True)
            events.append('clone')
            destination.mkdir()
        def boot(*_, **options):
            events.append('boot')
            self.assertIs(options['keep_operation'], True)
            self.assertEqual(host.read_json(self.exchange / 'artifacts/planned-result.json')['status'], 'planned')
            host.register_operation(self.root, self.root / 'runs/plan-fixture.vbvm',
                self.exchange, self.job['runId'], 'starting')
            return host.finalize_interrupted_result(self.exchange, self.job['runId'], 'guest_launch_failed')
        with patch.object(host, 'runner_source_digest', return_value='digest'), \
                patch.object(host, 'check_capacity'), patch.object(host, 'build_tools', return_value=self.root / 'tools'), \
                patch.object(host, 'guest_tool_hashes', return_value=self.job['runnerTools']), \
                patch.object(host, 'new_exchange', return_value=(self.job['runId'], self.exchange)), \
                patch.object(host, 'snapshot_source', return_value=self.job['source']), \
                patch.object(host, 'clone_vm', side_effect=clone), patch.object(host, 'monitor_vm', side_effect=boot), \
                patch.object(host, 'ensure_disk_idle'), patch.object(host, 'checked', wraps=host.checked) as commands, \
                patch('sys.stdout', new=io.StringIO()):
            self.assertEqual(host.run_tests(args, self.root, self.environment), 1)
        self.assertEqual(events, ['clone', 'boot'])
        self.assert_retained_clone()
        self.assertTrue(all(Path(call.args[0][0]).name == 'node' for call in commands.call_args_list))

    def test_completed_run_keeps_ownership_until_clone_cleanup_and_recovers_a_cleanup_failure(self):
        clone_path = self.root / 'runs' / (self.job['runId'] + '.vbvm')
        original_monitor, original_popen = host.monitor_vm, host.subprocess.Popen
        def clone(source, destination):
            destination.mkdir()
            (destination / 'Disk.img').write_bytes(b'fixture')
        class Child:
            def poll(self): return 0
        def launch(command, *args, **options):
            if Path(str(command[0])).name == 'VMHost':
                host.atomic_json(self.exchange / 'artifacts/result.json', {'runId': self.job['runId'],
                    'status': 'passed', 'finishedAt': 'fixture', 'source': self.job['source']})
                return Child()
            self.assertEqual(Path(str(command[0])).name, 'node')
            return original_popen(command, *args, **options)
        def fail_cleanup(path):
            self.assertEqual(path, clone_path)
            active = host.read_json(self.root / 'active.json')
            self.assertEqual(active['runId'], self.job['runId'])
            self.assertIs(active['cloneOwned'], True)
            self.assertIs(active['artifactsExported'], True)
            raise OSError('fixture: clone cleanup failed')
        with self.cloning_fixture(clone) as (args, *_), \
                patch.object(host, 'monitor_vm', wraps=original_monitor), \
                patch.object(host.subprocess, 'Popen', side_effect=launch), \
                patch.object(host, 'prepared_guest_hook', return_value=SimpleNamespace(
                    exchange_complete=True, cancel=lambda: None)), \
                patch.object(host.shutil, 'rmtree', side_effect=fail_cleanup):
            with self.assertRaisesRegex(OSError, 'clone cleanup failed'):
                host.run_tests(args, self.root, self.environment)
        self.assertTrue(clone_path.exists())
        self.assertIs(host.read_json(self.root / 'active.json')['cloneOwned'], True)
        report = host.read_json(self.exchange / 'artifacts/result.json')
        self.assertEqual(report['status'], 'passed')
        with patch.object(host, 'ensure_disk_idle') as idle:
            host.reconcile_interrupted_operation(self.root)
        idle.assert_called_once_with(clone_path)
        self.assertFalse(clone_path.exists())
        self.assertFalse((self.root / 'active.json').exists())
        self.assertEqual(host.read_json(self.exchange / 'artifacts/result.json'), report)

    def test_monitor_error_retains_clone_and_recovery_ownership_before_export(self):
        def clone(source, destination):
            destination.mkdir()
        with self.cloning_fixture(clone) as (args, _, boot, _, remove):
            def interrupted(*_, **options):
                host.register_operation(self.root, self.root / 'runs/plan-fixture.vbvm',
                    self.exchange, self.job['runId'], 'starting')
                raise OSError('fixture: report read failed after shutdown')
            boot.side_effect = interrupted
            with self.assertRaisesRegex(OSError, 'report read failed'):
                host.run_tests(args, self.root, self.environment)
        remove.assert_not_called()
        self.assert_retained_clone()
        self.assertTrue((self.root / 'active.json').exists())
        with patch.object(host, 'ensure_disk_idle'):
            host.reconcile_interrupted_operation(self.root)
        self.assertFalse((self.root / 'active.json').exists())
        self.assert_retained_clone()
        self.assertEqual(host.read_json(self.exchange / 'artifacts/result.json')['reason'], 'host_runner_interrupted')

    def assert_retained_clone(self):
        clone = self.root / 'runs/plan-fixture.vbvm'
        self.assertTrue(clone.is_dir())
        self.assertEqual(host.read_json(self.exchange / 'retained-vm.json'), {
            'version': 1, 'runId': self.job['runId'], 'vm': str(clone), 'reason': 'artifacts_not_collected'})

    @contextmanager
    def running_monitor_fixture(self, report=None, status=None, late_success=False):
        original_monitor, original_popen = host.monitor_vm, host.subprocess.Popen
        fixture = self
        class Child:
            returncode = None
            def poll(self): return self.returncode
            def wait(self, timeout=None):
                if late_success:
                    host.atomic_json(fixture.exchange / 'artifacts/result.json', {
                        'runId': fixture.job['runId'], 'status': 'passed', 'finishedAt': 'late-guest-result',
                        'source': fixture.job['source']})
                self.returncode = 0
                return 0
        child = Child()
        def clone(source, destination):
            destination.mkdir()
        def launch(command, *args, **options):
            if Path(str(command[0])).name != 'VMHost':
                self.assertEqual(Path(str(command[0])).name, 'node')
                return original_popen(command, *args, **options)
            initial = report if report is not None else {'runId': self.job['runId'], 'status': 'running',
                'source': self.job['source'], 'stages': [{'id': 'test.fixture', 'status': 'running', 'log': 'fixture.log'}]}
            for path, value in ((self.exchange / 'artifacts/result.json', initial),
                                (self.exchange / 'vm-status.json', status if status is not None else {'state': 'running'})):
                if isinstance(value, bytes):
                    path.write_bytes(value)
                else:
                    host.atomic_json(path, value)
            return child
        ticks = itertools.count()
        with self.cloning_fixture(clone) as (args, _, _, idle, remove), \
                patch.object(host, 'monitor_vm', wraps=original_monitor), \
                patch.object(host.subprocess, 'Popen', side_effect=launch), \
                patch.object(host.time, 'monotonic', side_effect=lambda: next(ticks)), \
                patch.object(host.time, 'sleep'):
            yield args, child, idle, remove

    def test_transient_monitor_read_failure_terminalizes_the_real_run_before_cleanup(self):
        read = host.read_json
        for filename in ('result.json', 'vm-status.json'):
            with self.subTest(filename=filename):
                failed = False
                def transient(path):
                    nonlocal failed
                    if Path(path).name == filename and Path(path).exists() and not failed:
                        failed = True
                        raise OSError('fixture transient monitor read')
                    return read(path)
                with self.running_monitor_fixture() as (args, child, _, remove), \
                        patch.object(host, 'read_json', side_effect=transient):
                    self.assertEqual(host.run_tests(args, self.root, self.environment), 1)
                result = read(self.exchange / 'artifacts/result.json')
                self.assertEqual(result['status'], 'failed')
                self.assertEqual(result['reason'], 'host_monitor_failed')
                self.assertIn('transient monitor read', result['hostTermination']['error'])
                self.assertTrue(result['finishedAt'])
                self.assertEqual(result['stages'][0]['status'], 'blocked')
                self.assertEqual(result['stages'][0]['log'], 'fixture.log')
                self.assertEqual(read(self.exchange / 'artifacts' / result['interruptedGuestResult'])['status'], 'running')
                self.assertEqual(child.returncode, 0)
                remove.assert_not_called()
                self.assert_retained_clone()
                self.assertFalse((self.root / 'active.json').exists())
                (self.exchange / 'stop.json').unlink(missing_ok=True)
                (self.exchange / 'vm-stop').unlink(missing_ok=True)
                (self.exchange / 'artifacts/result.json').unlink()
                self.assert_retained_clone()
                shutil.rmtree(self.root / 'runs/plan-fixture.vbvm')

    def test_repeated_monitor_read_failure_retains_clone_and_recovery(self):
        read = host.read_json
        failures = 2
        def repeated(path):
            nonlocal failures
            if Path(path).name == 'vm-status.json' and failures:
                failures -= 1
                raise OSError('fixture repeated status read')
            return read(path)
        with self.running_monitor_fixture() as (args, child, _, remove), \
                patch.object(host, 'read_json', side_effect=repeated):
            with self.assertRaisesRegex(OSError, 'repeated status read'):
                host.run_tests(args, self.root, self.environment)
        self.assertEqual(child.returncode, 0)
        remove.assert_not_called()
        self.assert_retained_clone()
        active = read(self.root / 'active.json')
        self.assertEqual(active['pendingTermination']['reason'], 'host_monitor_failed')
        self.assertNotIn('acceptedResultSHA256', active)
        self.assertEqual(read(self.exchange / 'artifacts/result.json')['status'], 'running')
        with patch.object(host, 'ensure_disk_idle'):
            host.reconcile_interrupted_operation(self.root)
        self.assertEqual(read(self.exchange / 'artifacts/result.json')['reason'], 'host_monitor_failed')
        self.assertFalse((self.root / 'active.json').exists())

    def test_failed_intent_final_report_or_acceptance_write_cannot_recover_a_guest_pass(self):
        read, write = host.read_json, host.atomic_json
        for phase in ('intent', 'report', 'acceptance'):
            with self.subTest(phase=phase):
                failed_read = False
                def transient(path):
                    nonlocal failed_read
                    if phase != 'acceptance' and Path(path).name == 'vm-status.json' and not failed_read:
                        failed_read = True
                        raise OSError('fixture monitoring failed')
                    return read(path)
                def failing_write(path, value):
                    if ((phase == 'intent' and Path(path).name == 'active.json' and value.get('pendingTermination')) or
                            (phase == 'report' and Path(path).name == 'result.json' and value.get('hostTermination')) or
                            (phase == 'acceptance' and Path(path).name == 'active.json' and value.get('acceptedResultSHA256'))):
                        raise OSError('fixture durable report write failed')
                    return write(path, value)
                initial = {'runId': self.job['runId'], 'status': 'passed', 'finishedAt': 'guest-result'} if phase == 'acceptance' else None
                with self.running_monitor_fixture(report=initial, late_success=phase != 'acceptance') as (args, child, _, remove), \
                        patch.object(host, 'read_json', side_effect=transient), \
                        patch.object(host, 'atomic_json', side_effect=failing_write):
                    with self.assertRaisesRegex(OSError, 'durable report write failed'):
                        host.run_tests(args, self.root, self.environment)
                self.assertEqual(child.returncode, 0)
                remove.assert_not_called()
                self.assert_retained_clone()
                self.assertTrue((self.root / 'active.json').exists())
                self.assertEqual(read(self.exchange / 'artifacts/result.json')['status'], 'passed')
                with patch.object(host, 'ensure_disk_idle'):
                    host.reconcile_interrupted_operation(self.root)
                result = read(self.exchange / 'artifacts/result.json')
                self.assertIn(result['status'], ('failed', 'blocked'))
                self.assertEqual(result['reason'], 'host_monitor_failed' if phase == 'report' else 'host_runner_interrupted')
                self.assertEqual(read(self.exchange / 'artifacts' / result['guestResultAfterStop'])['status'], 'passed')
                self.assertFalse((self.root / 'active.json').exists())
                (self.exchange / 'stop.json').unlink(missing_ok=True)
                (self.exchange / 'vm-stop').unlink(missing_ok=True)
                (self.exchange / 'artifacts/result.json').unlink()
                self.assert_retained_clone()
                shutil.rmtree(self.root / 'runs/plan-fixture.vbvm')

    def test_malformed_guest_diagnostics_preserve_raw_bytes_and_finalize_the_plan(self):
        cases = [('report', b'{invalid-json'), ('report', b'[]'),
                 ('report', b'{"runId":"another-run","status":"passed","finishedAt":"late"}'),
                 ('status', b'{invalid-status'), ('status', b'[]')]
        for kind, contents in cases:
            with self.subTest(kind=kind, contents=contents):
                options = {'report' if kind == 'report' else 'status': contents}
                with self.running_monitor_fixture(**options) as (args, child, _, _):
                    self.assertEqual(host.run_tests(args, self.root, self.environment), 1)
                result = host.read_json(self.exchange / 'artifacts/result.json')
                self.assertEqual(result['status'], 'failed')
                self.assertEqual(result['reason'], 'host_monitor_failed')
                self.assertEqual(child.returncode, 0)
                self.assertFalse((self.root / 'active.json').exists())
                if kind == 'report':
                    self.assertEqual((self.exchange / 'artifacts' / result['invalidGuestResult']).read_bytes(), contents)
                    planned = host.read_json(self.exchange / 'artifacts/planned-result.json')
                    self.assertEqual([stage['id'] for stage in result['stages']], [stage['id'] for stage in planned['stages']])
                    self.assertEqual(planned['status'], 'planned')
                else:
                    self.assertEqual((self.exchange / result['invalidVMStatus']).read_bytes(), contents)
                (self.exchange / 'stop.json').unlink(missing_ok=True)
                (self.exchange / 'vm-stop').unlink(missing_ok=True)
                (self.exchange / 'artifacts/result.json').unlink()
                self.assert_retained_clone()
                shutil.rmtree(self.root / 'runs/plan-fixture.vbvm')

    def test_failed_acceptance_of_finalized_report_keeps_original_diagnostics_during_recovery(self):
        read, write = host.read_json, host.atomic_json
        failed_read = False
        def transient(path):
            nonlocal failed_read
            if Path(path).name == 'vm-status.json' and not failed_read:
                failed_read = True
                raise OSError('fixture monitoring failed')
            return read(path)
        def failing_acceptance(path, value):
            if Path(path).name == 'active.json' and value.get('acceptedResultSHA256'):
                raise OSError('fixture acceptance unavailable')
            return write(path, value)
        with self.running_monitor_fixture(late_success=True) as (args, _, _, _), \
                patch.object(host, 'read_json', side_effect=transient), \
                patch.object(host, 'atomic_json', side_effect=failing_acceptance):
            with self.assertRaisesRegex(OSError, 'acceptance unavailable'):
                host.run_tests(args, self.root, self.environment)
        result_path = self.exchange / 'artifacts/result.json'
        result = read(result_path)
        original_path = self.exchange / 'artifacts' / result['guestResultAfterStop']
        original = original_path.read_bytes()
        self.assertEqual(result['status'], 'failed')
        with patch.object(host, 'ensure_disk_idle'), patch.object(host, 'atomic_json', side_effect=failing_acceptance):
            with self.assertRaisesRegex(OSError, 'acceptance unavailable'):
                host.reconcile_interrupted_operation(self.root)
        self.assertEqual(read(result_path), result)
        self.assertEqual(original_path.read_bytes(), original)
        self.assertTrue((self.root / 'active.json').exists())
        with patch.object(host, 'ensure_disk_idle'):
            host.reconcile_interrupted_operation(self.root)
        self.assertEqual(read(result_path), result)
        self.assertEqual(original_path.read_bytes(), original)
        self.assertFalse((self.root / 'active.json').exists())

    def test_doctor_reports_missing_host_node_without_executing_commands(self):
        args = SimpleNamespace(vm=self.root / 'fixture.vbvm', xcode=self.root / 'Xcode.app')
        with patch.object(host.shutil, 'which', return_value=None), \
                patch.object(host, 'validate_vm', return_value={'hardware': {'cpuCount': 5, 'memorySize': 16 * 1024 ** 3}}), \
                patch.object(host, 'check_capacity', return_value=100), \
                patch.object(host, 'checked', side_effect=AssertionError('A host command was started')):
            result = host.host_doctor(args, self.root, self.environment)
        node = next(check for check in result['checks'] if check['name'] == 'manifestNode')
        self.assertEqual(node['status'], 'blocked')
        self.assertIn('Host Node.js 18 or newer', node['detail'])

    def test_unsupported_host_node_is_rejected_before_manifest_import(self):
        with patch.object(host.shutil, 'which', return_value='/fixture/node'), \
                patch.object(host, 'checked', return_value='v16.20.2\n') as commands:
            with self.assertRaisesRegex(host.RunnerError, 'Node.js 18 or newer'):
                host.stage_planned_result(self.exchange, self.job)
        commands.assert_called_once_with(['/fixture/node', '--version'], env=host.node_planning_environment(), text=True, timeout=10)

    def test_node_preloads_and_coverage_cannot_execute_during_pure_planning(self):
        marker = self.root / 'preload-ran'
        preload = self.root / 'preload.cjs'
        preload.write_text(f'require("node:fs").writeFileSync({json.dumps(str(marker))}, "executed");\n')
        injected = {'NODE_OPTIONS': f'--require={preload}', 'NODE_PATH': str(self.root),
                    'NODE_V8_COVERAGE': str(self.root / 'coverage'), 'NODE_COMPILE_CACHE': str(self.root / 'compile-cache')}
        with patch.dict(host.os.environ, injected), patch.object(host, 'checked', wraps=host.checked) as commands:
            plan = self.plan()
        self.assertTrue(plan['stages'])
        self.assertFalse(marker.exists())
        self.assertFalse((self.root / 'coverage').exists())
        self.assertFalse((self.root / 'compile-cache').exists())
        self.assertEqual(len(commands.call_args_list), 2)
        for call in commands.call_args_list:
            self.assertFalse(any(key.startswith('NODE_') for key in call.kwargs['env']))

    def test_clone_failure_or_interrupt_terminalizes_plan_and_removes_only_idle_owned_clone(self):
        for interrupted in (False, True):
            with self.subTest(interrupted=interrupted):
                (self.exchange / 'artifacts/result.json').unlink(missing_ok=True)
                clone_path = self.root / 'runs/plan-fixture.vbvm'
                def clone(source, destination):
                    destination.mkdir()
                    (destination / 'Disk.img').write_bytes(b'partial copy')
                    if interrupted:
                        raise KeyboardInterrupt
                    raise host.RunnerError('fixture: clone failed')
                with self.cloning_fixture(clone) as (args, copy, boot, idle, remove):
                    self.assertEqual(host.run_tests(args, self.root, self.environment), 1)
                boot.assert_not_called()
                idle.assert_called_once_with(clone_path)
                remove.assert_called_once_with(clone_path)
                self.assertFalse(clone_path.exists())
                result = host.read_json(self.exchange / 'artifacts/result.json')
                plan = host.read_json(self.exchange / 'artifacts/planned-result.json')
                self.assertEqual(result['reason'], 'cancelled' if interrupted else 'vm_clone_failed')
                self.assertEqual(result['status'], 'cancelled' if interrupted else 'failed')
                self.assertEqual([stage['id'] for stage in result['stages']], [stage['id'] for stage in plan['stages']])
                self.assertTrue(all(stage['status'] == ('cancelled' if interrupted else 'blocked') for stage in result['stages']))
                self.assertIn('KeyboardInterrupt' if interrupted else 'clone failed', result['hostTermination']['error'])

    def test_clone_sigterm_is_reported_as_cancellation_and_restores_handlers(self):
        original_handlers = {value: signal.getsignal(value) for value in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP)}
        def clone(source, destination):
            destination.mkdir()
            signal.getsignal(signal.SIGTERM)(signal.SIGTERM, None)
        with self.cloning_fixture(clone) as (args, copy, boot, idle, remove):
            self.assertEqual(host.run_tests(args, self.root, self.environment), 1)
        self.assertEqual(host.read_json(self.exchange / 'artifacts/result.json')['status'], 'cancelled')
        for value, handler in original_handlers.items():
            self.assertIs(signal.getsignal(value), handler)
        boot.assert_not_called()

    def test_preexisting_clone_is_preserved_and_busy_partial_clone_is_not_removed(self):
        clone_path = self.root / 'runs/plan-fixture.vbvm'
        clone_path.mkdir(parents=True)
        sentinel = clone_path / 'unrelated-file'
        sentinel.write_text('preserve')
        with self.cloning_fixture(None) as (args, copy, boot, idle, remove):
            self.assertEqual(host.run_tests(args, self.root, self.environment), 1)
        copy.assert_not_called()
        idle.assert_not_called()
        remove.assert_not_called()
        self.assertEqual(sentinel.read_text(), 'preserve')
        shutil.rmtree(clone_path)
        (self.exchange / 'artifacts/result.json').unlink()
        def clone(source, destination):
            destination.mkdir()
            raise OSError('fixture: interrupted copy')
        with self.cloning_fixture(clone, host.RunnerError('fixture: disk is busy')) as (args, copy, boot, idle, remove):
            with self.assertRaisesRegex(host.RunnerError, 'disk is busy'):
                host.run_tests(args, self.root, self.environment)
        remove.assert_not_called()
        self.assertTrue(clone_path.exists())
        self.assertEqual(host.read_json(self.exchange / 'artifacts/result.json')['reason'], 'vm_clone_failed')

    def test_partial_clone_without_disk_images_does_not_inspect_unrelated_host_files(self):
        clone = self.root / 'partial.vbvm'
        clone.mkdir()
        with patch.object(host.subprocess, 'run', side_effect=AssertionError('Unexpected host process inspection')):
            host.ensure_disk_idle(clone)

    def test_vmhost_launch_failure_or_interrupt_produces_terminal_plan_without_signalling(self):
        for failure in (OSError('fixture: VMHost cannot execute'), KeyboardInterrupt()):
            with self.subTest(failure=type(failure).__name__):
                (self.exchange / 'artifacts/result.json').unlink(missing_ok=True)
                plan = self.plan(stages=['test'], onlyTesting=['Tests visionOS'])
                with patch.object(host.subprocess, 'Popen', side_effect=failure), \
                        patch.object(host, 'stop_owned_process') as stop:
                    result = host.monitor_vm(SimpleNamespace(command='run'), self.root, self.root / 'unused.vbvm',
                                             self.exchange, self.job['runId'], self.root, {}, 100)
                stop.assert_not_called()
                self.assertEqual(result['reason'], 'cancelled' if isinstance(failure, KeyboardInterrupt) else 'vm_launch_failed')
                self.assertEqual(result['status'], 'cancelled' if isinstance(failure, KeyboardInterrupt) else 'failed')
                self.assertEqual(len(result['stages']), len(plan['stages']))
                self.assertFalse((self.root / 'active.json').exists())
                self.assertEqual(result['plannedResult'], 'planned-result.json')

    def request_preparing_stop(self):
        with patch.object(host.sys, 'platform', 'darwin'), \
                patch.object(host.os, 'uname', return_value=SimpleNamespace(machine='arm64')), \
                patch('sys.stdout', new=io.StringIO()) as output:
            self.assertEqual(host.main(['--state-dir', str(self.root), 'status']), 0)
            active = json.loads(output.getvalue())
            self.assertEqual(active['runId'], self.job['runId'])
            self.assertEqual(active['phase'], 'preparing')
            self.assertEqual(active['exchange'], str(self.exchange))
            output.seek(0)
            output.truncate()
            self.assertEqual(host.main(['--state-dir', str(self.root), 'stop']), 0)
            self.assertIn(f'Stop requested for {self.job["runId"]}', output.getvalue())
        self.assertEqual(host.read_json(self.exchange / 'stop.json')['runId'], self.job['runId'])

    def test_stop_during_tools_snapshot_plan_or_clone_prevents_vm_launch(self):
        for phase in ('tools', 'snapshot', 'plan', 'clone'):
            with self.subTest(phase=phase):
                for name in ('stop.json', 'artifacts/result.json', 'artifacts/planned-result.json'):
                    (self.exchange / name).unlink(missing_ok=True)
                def tools(*_):
                    if phase == 'tools':
                        self.request_preparing_stop()
                    return self.root / 'tools'
                def snapshot(*_):
                    if phase == 'snapshot':
                        self.request_preparing_stop()
                    return self.job['source']
                original_plan = host.stage_planned_result
                def plan(*arguments):
                    if phase == 'plan':
                        self.request_preparing_stop()
                    return original_plan(*arguments)
                def clone(source, destination):
                    destination.mkdir()
                    self.request_preparing_stop()
                with self.cloning_fixture(clone) as (args, copy, boot, idle, remove), \
                        patch.object(host, 'build_tools', side_effect=tools), \
                        patch.object(host, 'snapshot_source', side_effect=snapshot), \
                        patch.object(host, 'stage_planned_result', side_effect=plan):
                    self.assertEqual(host.run_tests(args, self.root, self.environment), 1)
                boot.assert_not_called()
                if phase == 'clone':
                    copy.assert_called_once()
                    idle.assert_called_once_with(self.root / 'runs/plan-fixture.vbvm')
                    remove.assert_called_once_with(self.root / 'runs/plan-fixture.vbvm')
                else:
                    copy.assert_not_called()
                    idle.assert_not_called()
                    remove.assert_not_called()
                result = host.read_json(self.exchange / 'artifacts/result.json')
                planned = host.read_json(self.exchange / 'artifacts/planned-result.json')
                self.assertEqual(result['status'], 'cancelled')
                self.assertEqual(result['plannedResult'], 'planned-result.json')
                self.assertEqual(result['source'], self.job['source'])
                self.assertEqual(len(result['stages']), len(planned['stages']))
                self.assertTrue(all(stage['status'] == 'cancelled' for stage in result['stages']))
                self.assertFalse(result['coverage']['fullSuiteVerified'])
                self.assertFalse((self.root / 'active.json').exists())

    def test_stop_arriving_during_monitor_handoff_is_checked_before_popen(self):
        self.plan(stages=['test'], onlyTesting=['Tests visionOS'])
        vm = self.root / 'run.vbvm'
        host.register_operation(self.root, vm, self.exchange, self.job['runId'], 'preparing')
        started = host.read_json(self.root / 'active.json')['startedAt']
        original_register = host.register_operation
        def register(*arguments):
            original_register(*arguments)
            active = host.read_json(self.root / 'active.json')
            self.assertEqual(active['startedAt'], started)
            self.assertEqual(active['phase'], 'starting')
            host.atomic_json(self.exchange / 'stop.json', {'runId': self.job['runId']})
        with patch.object(host, 'register_operation', side_effect=register), \
                patch.object(host.subprocess, 'Popen', side_effect=AssertionError('VMHost must not launch')) as launch, \
                patch.object(host, 'stop_owned_process') as stop:
            result = host.monitor_vm(SimpleNamespace(command='run'), self.root, vm,
                                     self.exchange, self.job['runId'], self.root, {}, 100)
        self.assertEqual(result['status'], 'cancelled')
        launch.assert_not_called()
        stop.assert_not_called()
        self.assertFalse((self.root / 'active.json').exists())

    def test_preparing_ownership_and_stop_requests_are_scoped_to_the_run(self):
        active = {'version': 1, 'runId': 'another-run', 'ownerPID': host.os.getpid(),
                  'exchange': str(self.exchange), 'vm': str(self.root / 'other.vbvm')}
        host.atomic_json(self.root / 'active.json', active)
        with self.assertRaisesRegex(host.RunnerError, 'Another operation owns'):
            host.register_operation(self.root, self.root / 'fixture.vbvm', self.exchange, self.job['runId'], 'preparing')
        host.clear_owned_operation(self.root, self.job['runId'])
        self.assertEqual(host.read_json(self.root / 'active.json'), active)
        host.atomic_json(self.exchange / 'stop.json', {'runId': 'another-run'})
        self.assertFalse(host.operation_stop_requested(self.exchange, self.job['runId']))

    def test_busy_clone_after_preparing_stop_preserves_recovery_ownership(self):
        def clone(source, destination):
            destination.mkdir()
            self.request_preparing_stop()
        with self.cloning_fixture(clone, host.RunnerError('fixture: disk busy')) as (args, copy, boot, idle, remove):
            with self.assertRaisesRegex(host.RunnerError, 'disk busy'):
                host.run_tests(args, self.root, self.environment)
        boot.assert_not_called()
        remove.assert_not_called()
        self.assertTrue((self.root / 'runs/plan-fixture.vbvm').exists())
        self.assertEqual(host.read_json(self.root / 'active.json')['runId'], self.job['runId'])
        self.assertEqual(host.read_json(self.exchange / 'artifacts/result.json')['status'], 'cancelled')

    def test_tool_preparation_failure_reports_and_releases_its_preparing_record(self):
        with self.cloning_fixture(None) as (args, copy, boot, idle, remove), \
                patch.object(host, 'build_tools', side_effect=host.RunnerError('fixture: compiler unavailable')):
            self.assertEqual(host.run_tests(args, self.root, self.environment), 1)
        result = host.read_json(self.exchange / 'artifacts/result.json')
        self.assertEqual(result['reason'], 'host_preparation_failed')
        self.assertIn('compiler unavailable', result['hostTermination']['error'])
        self.assertFalse((self.root / 'active.json').exists())
        copy.assert_not_called()
        boot.assert_not_called()
