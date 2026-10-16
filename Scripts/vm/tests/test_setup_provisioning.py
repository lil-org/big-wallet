import contextlib
import hashlib
import importlib.util
import io
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
import uuid
from unittest.mock import patch


spec = importlib.util.spec_from_file_location('setup_provisioning_host', Path(__file__).resolve().parents[1] / 'host.py')
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)


class ProvisioningPackageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.state = Path(self.temporary.name).resolve()
        self.environment = host.read_json(host.TOOLS / 'environment.json')
        self.record = {'vmId': 'fixture-vm', 'consoleUser': 'existing-user'}
        self.binaries = self.state / 'tools'
        self.binaries.mkdir()
        (self.binaries / 'VMGuestAgent').write_bytes(b'fixture agent')
        self.archive = self.state / 'Xcode.tar'
        self.archive.write_bytes(b'fixture archive')
        self.inputs = self.state / 'inputs'
        self.inputs.mkdir()
        self.input_config = self.inputs / 'input.json'
        self.fixture_root = self.state / 'repository'
        (self.fixture_root / 'Scripts').mkdir(parents=True)
        self.proof = 'A' * 43
        (self.fixture_root / 'Scripts/alchemy_jwt_request_proof_key.sha256').write_text(hashlib.sha256(self.proof.encode()).hexdigest())
        for target, replacement in [('ROOT', self.fixture_root)]:
            patcher = patch.object(host, target, replacement)
            patcher.start()
            self.addCleanup(patcher.stop)
        patcher = patch.object(host, 'cached_xcode_archive', return_value=(self.archive, host.hash_regular_file(self.archive)))
        patcher.start()
        self.addCleanup(patcher.stop)
        def copy(command, **_):
            self.assertEqual(command[:2], ['/bin/cp', '-c'])
            shutil.copyfile(command[2], command[3])
            return b''
        patcher = patch.object(host, 'checked', side_effect=copy)
        patcher.start()
        self.addCleanup(patcher.stop)

    def args(self, *options):
        return host.parser().parse_args(['setup', *map(str, options)])

    def stage(self, args, name):
        exchange = host.private_directory(self.state / 'setup' / name)
        return exchange, host.stage_provisioning(args, self.state, exchange, self.environment, self.record, self.binaries)

    def explicit_package(self):
        (self.inputs / 'password.txt').write_text('fixture password')
        host.atomic_json(self.input_config, {'consoleUser': 'requested-user', 'autologin': {'passwordFile': 'password.txt'}})
        exchange, configuration = self.stage(self.args('--provision-config', self.input_config), 'setup-first')
        self.record['pendingProvisioning'] = {'id': configuration['provisioningRequestID'],
            'path': str(exchange / 'provision'), 'consoleUser': configuration['consoleUser']}
        return exchange, configuration

    def source_snapshot(self, exchange):
        snapshot = exchange / 'source/Scripts/vm'
        snapshot.mkdir(parents=True)
        for source in host.TOOLS.iterdir():
            if source.is_file():
                shutil.copyfile(source, snapshot / source.name)
        return snapshot

    def test_source_binding_accepts_current_and_exact_reused_pending_packages(self):
        current, configuration = self.stage(self.args(), 'setup-binding-current')
        original, requested = self.explicit_package()
        retry, reused = self.stage(self.args(), 'setup-binding-retry')
        captured = host.bootstrap_source_digest()
        tools = host.bootstrap_tool_hashes(self.binaries)
        for exchange, config in ((current, configuration), (original, requested), (retry, reused)):
            with self.subTest(exchange=exchange.name):
                self.source_snapshot(exchange)
                host.verify_setup_sources(exchange, captured, self.environment, config, tools)
                host.verify_setup_sources(exchange, captured, self.environment)
        self.assertEqual(reused['provisioningRequestID'], requested['provisioningRequestID'])

    def test_source_binding_rejects_snapshot_staging_configuration_and_tool_drift(self):
        for change in ('snapshot', 'installer', 'runner', 'agent', 'configuration', 'tools'):
            with self.subTest(change=change):
                exchange, configuration = self.stage(self.args(), 'setup-binding-' + change)
                snapshot = self.source_snapshot(exchange)
                captured = host.bootstrap_source_digest()
                tools = host.bootstrap_tool_hashes(self.binaries)
                if change == 'snapshot':
                    (snapshot / 'provision_guest.sh').write_text('changed during snapshot')
                elif change in ('installer', 'runner', 'agent'):
                    filename = {'installer': 'provision_guest.sh', 'runner': 'guest_bootstrap.mjs', 'agent': 'VMGuestAgent'}[change]
                    (exchange / 'provision' / filename).write_text('changed during staging')
                elif change == 'configuration':
                    staged = host.read_json(exchange / 'provision/config.json')
                    staged['xcode']['buildVersion'] = 'different'
                    host.atomic_json(exchange / 'provision/config.json', staged)
                else:
                    tools['guest_bootstrap.mjs'] = '0' * 64
                with self.assertRaisesRegex(host.RunnerError, 'does not match'):
                    host.verify_setup_sources(exchange, captured, self.environment, configuration, tools)

    def test_source_binding_rejects_environment_changed_since_host_loading(self):
        exchange, configuration = self.stage(self.args(), 'setup-binding-environment')
        self.source_snapshot(exchange)
        environment = {**self.environment, 'minimumHostFreeBytes': self.environment['minimumHostFreeBytes'] + 1}
        with self.assertRaisesRegex(host.RunnerError, 'snapshot does not match'):
            host.verify_setup_sources(exchange, host.bootstrap_source_digest(), environment, configuration,
                                      host.bootstrap_tool_hashes(self.binaries))

    def test_plain_setup_validates_the_recorded_account_without_a_new_receipt(self):
        _, configuration = self.stage(self.args(), 'setup-readiness')
        self.assertEqual(configuration['consoleUser'], 'existing-user')
        self.assertNotIn('provisioningRequestID', configuration)
        self.assertIsNone(self.args().guest_user)

    def test_no_input_retry_copies_the_exact_pending_package_and_retains_its_user(self):
        original, requested = self.explicit_package()
        (self.inputs / 'password.txt').write_text('changed original input')
        retry, configuration = self.stage(self.args(), 'setup-retry')
        self.assertEqual(configuration, requested)
        self.assertEqual(configuration['consoleUser'], 'requested-user')
        first = {file.name: file.read_bytes() for file in (original / 'provision').iterdir()}
        second = {file.name: file.read_bytes() for file in (retry / 'provision').iterdir()}
        self.assertEqual(first, second)
        self.assertEqual(second['autologin-passwordFile'], b'fixture password')

    def test_explicit_proof_input_supersedes_pending_without_mutating_the_old_package(self):
        original, requested = self.explicit_package()
        bundle = self.state / 'Fixture.app/Contents/Resources'
        bundle.mkdir(parents=True)
        (bundle / 'AlchemyJWTRequestProofKey').write_text(self.proof)
        _, next_config = self.stage(self.args('--proof-key-bundle', bundle.parent.parent), 'setup-next')
        self.assertNotEqual(next_config['provisioningRequestID'], requested['provisioningRequestID'])
        self.assertEqual(next_config['consoleUser'], 'requested-user')
        self.assertEqual(host.read_json(original / 'provision/config.json'), requested)
        self.assertTrue((original / 'provision/autologin-passwordFile').exists())

    def test_proof_only_input_config_receives_its_receipt_without_development_signing(self):
        (self.inputs / 'proof.txt').write_text(self.proof)
        host.atomic_json(self.input_config, {'signing': {'proofKeyFile': 'proof.txt'}})
        exchange, configuration = self.stage(self.args('--provision-config', self.input_config), 'setup-proof-only')
        self.assertNotIn('profiles', configuration['signing'])
        script = r'''
import {readFileSync} from 'node:fs';
const source = readFileSync(process.argv[1], 'utf8');
const functionSource = source.match(/^function appliedProvisioningRequest\([^]*?^}/m)[0];
const receipt = (0, eval)(`(${functionSource})`);
const configuration = JSON.parse(readFileSync(process.argv[2], 'utf8'));
process.stdout.write(receipt(configuration, undefined, ['request-proof key']));
'''
        result = subprocess.run(['node', '--input-type=module', '-e', script, str(host.TOOLS / 'provision_guest.sh'),
                                 str(exchange / 'provision/config.json')], check=True, capture_output=True, text=True)
        self.assertEqual(result.stdout, configuration['provisioningRequestID'])

    def test_no_input_retry_retains_initial_account_creation_intent(self):
        for source in ('cli', 'json'):
            with self.subTest(source=source):
                host.atomic_json(self.input_config, {'provisionNewAccount': True})
                args = (self.args('--provision-new-account') if source == 'cli' else
                        self.args('--provision-config', self.input_config))
                original, requested = self.stage(args, 'setup-first-account-' + source)
                self.record['pendingProvisioning'] = {'id': requested['provisioningRequestID'], 'path': str(original / 'provision'),
                    'consoleUser': requested['consoleUser'], 'initialAccountPasswordPath': str(self.state / 'initial-guest-password')}
                _, retried = self.stage(self.args(), 'setup-retry-account-' + source)
                self.assertEqual(retried, requested)
                self.assertIs(retried['provisionNewAccount'], True)
                self.assertNotIn('autologin', retried)

    def test_first_boot_rejects_existing_password_before_archive_or_input_copy(self):
        cases = [('cli', ['--provision-new-account'], {}),
                 ('json', [], {'provisionNewAccount': True}),
                 ('cli-overrides-json', ['--provision-new-account'], {'provisionNewAccount': False})]
        for name, options, supplied in cases:
            with self.subTest(source=name):
                configuration = {**supplied, 'autologin': {'passwordFile': 'must-not-be-read.txt'}}
                host.atomic_json(self.input_config, configuration)
                with patch.object(host, 'cached_xcode_archive') as archive, \
                        patch.object(host, 'copy_provision_input') as copy_inputs, \
                        patch.object(host, 'checked') as commands:
                    with self.assertRaisesRegex(host.RunnerError, 'autologin.passwordFile'):
                        self.stage(self.args('--provision-config', self.input_config, *options), 'setup-conflict-' + name)
                archive.assert_not_called()
                copy_inputs.assert_not_called()
                commands.assert_not_called()
                self.assertEqual(host.read_json(self.input_config), configuration)
                self.assertEqual(list((self.state / 'setup' / ('setup-conflict-' + name) / 'provision').iterdir()), [])
                self.assertFalse((self.state / 'initial-guest-password').exists())

    def test_conflicting_pending_first_boot_package_is_preserved_without_copy_or_refresh(self):
        original, configuration = self.explicit_package()
        configuration['provisionNewAccount'] = True
        self.record['pendingProvisioning']['initialAccountPasswordPath'] = str(self.state / 'initial-guest-password')
        host.atomic_json(original / 'provision/config.json', configuration)
        for stale in (False, True):
            with self.subTest(stale=stale):
                if stale:
                    (original / 'provision/guest_bootstrap.mjs').write_text('stale fixture tool')
                preserved = {file.name: file.read_bytes() for file in (original / 'provision').iterdir()}
                with patch.object(host, 'cached_xcode_archive') as archive, \
                        patch.object(host, 'copy_provision_input') as copy_inputs, \
                        patch.object(host, 'checked') as commands, \
                        patch.object(host, 'bootstrap_tool_hashes') as tools:
                    with self.assertRaisesRegex(host.RunnerError, 'autologin.passwordFile'):
                        self.stage(self.args(), 'setup-conflict-retry-' + str(stale))
                archive.assert_not_called()
                copy_inputs.assert_not_called()
                commands.assert_not_called()
                tools.assert_not_called()
                self.assertEqual({file.name: file.read_bytes() for file in (original / 'provision').iterdir()}, preserved)
                self.assertFalse((self.state / 'initial-guest-password').exists())

    def test_setup_password_conflict_stops_before_guest_access_or_launch(self):
        candidate = self.state / 'candidate.vbvm'
        candidate.mkdir()
        for retained in (False, True):
            with self.subTest(retained=retained):
                if retained:
                    original, configuration = self.explicit_package()
                    configuration['provisionNewAccount'] = True
                    self.record['pendingProvisioning']['initialAccountPasswordPath'] = str(self.state / 'initial-guest-password')
                    host.atomic_json(original / 'provision/config.json', configuration)
                    args = self.args()
                else:
                    host.atomic_json(self.input_config, {'autologin': {'passwordFile': 'must-not-be-read.txt'}})
                    args = self.args('--provision-new-account', '--provision-config', self.input_config)
                host.atomic_json(self.state / 'candidate.json', {**self.record, 'sourceVM': str(args.vm),
                    'environment': self.environment})
                with contextlib.ExitStack() as stack:
                    for name, value in [('validate_vm', {}), ('check_capacity', None), ('build_tools', self.binaries),
                                        ('bootstrap_tool_hashes', {}), ('ensure_disk_idle', None), ('configure_build_storage', False)]:
                        stack.enter_context(patch.object(host, name, return_value=value))
                    blocked = [stack.enter_context(patch.object(host, name, side_effect=AssertionError('Guest work started')))
                               for name in ('guest_access_module', 'run_setup_doctor', 'monitor_vm', 'snapshot_source')]
                    archive = stack.enter_context(patch.object(host, 'cached_xcode_archive'))
                    stack.enter_context(patch('sys.stdout', new=io.StringIO()))
                    with self.assertRaisesRegex(host.RunnerError, 'autologin.passwordFile'):
                        host.setup(args, self.state, self.environment)
                for operation in blocked:
                    operation.assert_not_called()
                archive.assert_not_called()
                self.assertFalse((self.state / 'active.json').exists())
                self.assertFalse((self.state / 'initial-guest-password').exists())
                self.assertFalse((self.state / 'guest-access').exists())

    def test_stale_pending_tools_and_environment_restage_retained_inputs(self):
        original, requested = self.explicit_package()
        (original / 'provision/guest_bootstrap.mjs').write_text('stale guest tool')
        updated, refreshed = self.stage(self.args(), 'setup-stale-tools')
        self.assertNotEqual(refreshed['provisioningRequestID'], requested['provisioningRequestID'])
        self.assertEqual((updated / 'provision/autologin-passwordFile').read_bytes(), b'fixture password')
        self.assertEqual((updated / 'provision/guest_bootstrap.mjs').read_bytes(), (host.TOOLS / 'guest_bootstrap.mjs').read_bytes())
        self.assertEqual(host.read_json(original / 'provision/config.json'), requested)
        _, restaged = self.stage(self.args('--provision-config', original / 'provision/config.json'), 'setup-restaged')
        self.assertNotEqual(restaged['provisioningRequestID'], requested['provisioningRequestID'])
        self.assertEqual(restaged['autologin'], requested['autologin'])
        shutil.copyfile(host.TOOLS / 'guest_bootstrap.mjs', original / 'provision/guest_bootstrap.mjs')
        self.environment['node'] = {'version': 'different', 'npmVersion': 'different'}
        _, repinned = self.stage(self.args(), 'setup-stale-environment')
        self.assertEqual(repinned['node'], self.environment['node'])
        self.assertNotEqual(repinned['provisioningRequestID'], requested['provisioningRequestID'])
        self.assertEqual(host.read_json(original / 'provision/config.json'), requested)

    def test_account_selection_rejects_conflicts_and_marks_actual_account_changes(self):
        self.assertEqual(host.selected_console_user(self.args(), {}), 'wallet-test')
        self.assertEqual(host.selected_console_user(self.args('--guest-user', 'TestUser'), self.record), 'TestUser')
        self.assertFalse(host.provisioning_inputs_requested(self.args('--guest-user', 'existing-user'), self.record))
        self.assertTrue(host.provisioning_inputs_requested(self.args('--guest-user', 'another-user'), self.record))
        with self.assertRaisesRegex(host.RunnerError, 'must agree'):
            host.selected_console_user(self.args('--guest-user', 'another-user'), self.record, {'consoleUser': 'configured-user'})
        for value in ['', None, '../user']:
            with self.assertRaisesRegex(host.RunnerError, 'invalid'):
                host.selected_console_user(self.args(), self.record, {'consoleUser': value})

    def test_mismatched_pending_package_is_not_adopted_under_its_receipt(self):
        original, requested = self.explicit_package()
        host.atomic_json(original / 'provision/config.json', {**requested, 'provisioningRequestID': str(uuid.uuid4())})
        with self.assertRaisesRegex(host.RunnerError, 'recorded identity'):
            self.stage(self.args(), 'setup-mismatch')

    def test_cleanup_preserves_other_requests_and_unreceipted_inputs(self):
        applied = str(uuid.uuid4())
        packages = {'setup-applied': applied, 'setup-unapplied': str(uuid.uuid4()), 'setup-no-receipt': None}
        for name, identifier in packages.items():
            directory = host.private_directory(self.state / 'setup' / name / 'provision')
            host.atomic_json(directory / 'config.json', {'vmId': 'fixture-vm', 'provisioningRequestID': identifier})
        host.clear_applied_provisioning_packages(self.state, 'fixture-vm', applied)
        self.assertFalse((self.state / 'setup/setup-applied/provision').exists())
        self.assertTrue((self.state / 'setup/setup-unapplied/provision').exists())
        self.assertTrue((self.state / 'setup/setup-no-receipt/provision').exists())

    def test_cleanup_does_not_follow_a_symlinked_setup_exchange(self):
        applied = str(uuid.uuid4())
        external = host.private_directory(self.state / 'outside/provision')
        host.atomic_json(external / 'config.json', {'vmId': 'fixture-vm', 'provisioningRequestID': applied})
        (self.state / 'setup').mkdir()
        (self.state / 'setup/setup-link').symlink_to(external.parent, target_is_directory=True)
        host.clear_applied_provisioning_packages(self.state, 'fixture-vm', applied)
        self.assertTrue((external / 'config.json').exists())


class SetupReceiptTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.state = Path(self.temporary.name).resolve()
        self.args = host.parser().parse_args(['--vm', str(self.state / 'original.vbvm'), 'setup'])
        self.candidate = self.state / 'candidate.vbvm'
        (self.candidate / '.vbdata').mkdir(parents=True)
        self.environment = {'minimumHostFreeBytes': 1, 'buildData': {'bytes': 96 * 1024 ** 3}}
        self.record = {'version': 1, 'vmId': 'fixture-vm', 'consoleUser': 'selected-user',
                       'sourceVM': str(self.args.vm), 'environment': self.environment}
        host.atomic_json(self.state / 'candidate.json', self.record)
        self.request_id = str(uuid.uuid4())
        self.tools = {name: 'a' * 64 for name in ('VMGuestAgent', 'guest_runner', 'guest_bootstrap.mjs')}
        self.calls = []
        self.exchanges = []
        self.passwords = []

    def result(self, status='passed', user='selected-user', receipt=None):
        return {'status': status, 'identity': {'vmId': 'fixture-vm', 'consoleUser': user}, 'preflight': {
            'bootstrap': {'available': True, 'hashes': self.tools},
            'checks': {name: True for name in ('bootstrap', 'node', 'python', 'jq', 'xcode', 'macos', 'ios', 'visionos')},
            'provisioning': {'vmId': 'fixture-vm', 'consoleUser': user, 'appliedRequestID': receipt},
        }}

    def run_setup(self, results, requested=True, new_account=False):
        def stage(args, state, exchange, environment, record, binaries):
            directory = host.private_directory(exchange / 'provision')
            if requested and record.get('pendingProvisioning'):
                configuration = host.read_json(Path(record['pendingProvisioning']['path']) / 'config.json')
            else:
                configuration = {'vmId': 'fixture-vm', 'consoleUser': 'selected-user'}
                if requested:
                    configuration['provisioningRequestID'] = self.request_id
                if new_account:
                    configuration['provisionNewAccount'] = True
            host.atomic_json(directory / 'config.json', configuration)
            self.exchanges.append(exchange)
            return configuration
        def monitor(args, state, vm, exchange, run_id, binaries, environment, timeout, password=None, **options):
            self.calls.append(host.read_json(exchange / 'job.json')['kind'])
            self.passwords.append(password)
            return results[len(self.calls) - 1]
        def doctor(args, state, candidate, environment, operation, record, configuration,
                   binaries, bootstrap_tools, source, password, source_digest):
            run_id, exchange = operation['runId'], operation['exchange']
            host.atomic_json(exchange / 'job.json', {'version': 1, 'runId': run_id, 'vmId': record['vmId'],
                'kind': 'doctor', 'profile': 'all', 'payload': {'stages': [], 'onlyTesting': []}, 'source': source,
                'bootstrapTools': bootstrap_tools})
            operation['monitorCalled'] = True
            return host.monitor_vm(args, state, candidate, exchange, run_id, binaries, environment,
                args.timeout or 120, password, keep_operation=True, previous_stops=operation['previousStops']), exchange
        with contextlib.ExitStack() as stack:
            for name, value in [('validate_vm', {}), ('check_capacity', None), ('build_tools', self.state / 'tools'),
                                ('bootstrap_tool_hashes', self.tools), ('configure_build_storage', False),
                                ('ensure_disk_idle', None), ('configure_guest_hardware', None), ('prepared_guest_hook', None),
                                ('snapshot_source', {'sha256': 'b' * 64, 'commit': 'c' * 40}),
                                ('environment_attested', True), ('stage_planned_result', None), ('verify_setup_sources', None)]:
                stack.enter_context(patch.object(host, name, return_value=value))
            stack.enter_context(patch.object(host, 'stage_provisioning', side_effect=stage))
            stack.enter_context(patch.object(host, 'monitor_vm', side_effect=monitor))
            stack.enter_context(patch.object(host, 'run_setup_doctor', side_effect=doctor))
            stack.enter_context(patch.object(host, 'guest_access_module', side_effect=AssertionError('No disk access or SSH in receipt fixtures')))
            stack.enter_context(patch('sys.stdout', new=io.StringIO()))
            return host.setup(self.args, self.state, self.environment)

    def test_old_guest_cannot_promote_or_delete_new_unapplied_inputs(self):
        self.assertEqual(self.run_setup([self.result(receipt=str(uuid.uuid4()))]), 2)
        self.assertEqual(self.calls, ['doctor'])
        record = host.read_json(self.state / 'candidate.json')
        self.assertEqual(record['pendingProvisioning']['id'], self.request_id)
        self.assertNotIn('baseVerifiedAt', record)
        self.assertTrue(Path(record['pendingProvisioning']['path']).exists())
        self.assertFalse((self.state / 'baseline.json').exists())

    def test_retry_after_unapplied_initial_boot_reuses_the_private_password_and_account_intent(self):
        self.assertEqual(self.run_setup([{'status': 'blocked', 'reason': 'guest_access_required'}], new_account=True), 2)
        password = self.passwords[0]
        original = password.read_bytes()
        self.assertEqual(password.stat().st_mode & 0o777, 0o600)
        record = host.read_json(self.state / 'candidate.json')
        self.assertEqual(record['pendingProvisioning']['initialAccountPasswordPath'], str(password))
        self.calls.clear()
        self.args = host.parser().parse_args(['--vm', str(self.args.vm), 'setup'])
        with patch.object(host.secrets, 'token_urlsafe', side_effect=AssertionError('Retry must not replace the initial password')):
            self.assertEqual(self.run_setup([self.result(status='failed', receipt=self.request_id)]), 2)
        self.assertEqual(self.passwords[-1], password)
        self.assertEqual(password.read_bytes(), original)

    def test_interrupted_initial_password_generation_can_retry_the_pending_setup(self):
        password = self.state / 'initial-guest-password'
        with patch.object(host.secrets, 'token_urlsafe', side_effect=KeyboardInterrupt):
            self.assertEqual(self.run_setup([], new_account=True), 2)
        self.assertEqual(self.calls, [])
        self.assertEqual(list(self.state.glob('initial-guest-password*')), [])
        pending = host.read_json(self.state / 'candidate.json')['pendingProvisioning']
        self.assertEqual(pending['id'], self.request_id)
        self.assertEqual(pending['initialAccountPasswordPath'], str(password))
        self.assertEqual(self.run_setup([{'status': 'blocked', 'reason': 'guest_access_required'}]), 2)
        self.assertEqual(self.passwords, [password])
        self.assertRegex(password.read_text(), r'^[A-Za-z0-9_-]{43}$')
        self.assertEqual(password.stat().st_mode & 0o777, 0o600)

    def test_initial_password_sync_failure_leaves_no_partial_password_and_can_retry(self):
        password = self.state / 'initial-guest-password'
        create_password = host.create_initial_guest_password
        def fail_sync(descriptor):
            self.assertFalse(password.exists())
            self.assertEqual(host.os.fstat(descriptor).st_mode & 0o777, 0o600)
            raise OSError('fixture password sync failure')
        def create_with_failed_sync(path):
            with patch.object(host.os, 'fsync', side_effect=fail_sync):
                create_password(path)
        with patch.object(host, 'create_initial_guest_password', side_effect=create_with_failed_sync):
            with self.assertRaisesRegex(OSError, 'fixture password sync failure'):
                self.run_setup([], new_account=True)
        self.assertEqual(self.calls, [])
        self.assertEqual(list(self.state.glob('initial-guest-password*')), [])
        self.assertEqual(self.run_setup([{'status': 'blocked', 'reason': 'guest_access_required'}]), 2)
        self.assertEqual(self.passwords, [password])
        self.assertRegex(password.read_text(), r'^[A-Za-z0-9_-]{43}$')
        self.assertEqual(password.stat().st_mode & 0o777, 0o600)

    def test_applied_request_can_verify_base_with_missing_unrequested_signing(self):
        result = self.result(status='failed', receipt=self.request_id)
        result['preflight']['checks']['signing'] = False
        self.assertEqual(self.run_setup([result]), 2)
        record = host.read_json(self.state / 'candidate.json')
        self.assertTrue(record['baseVerifiedAt'])
        self.assertEqual(record['pendingProvisioning']['id'], self.request_id)
        self.assertTrue(Path(record['pendingProvisioning']['path']).exists())

    def test_ordinary_readiness_can_promote_without_a_provisioning_receipt(self):
        self.assertEqual(self.run_setup([self.result(), self.result()], requested=False), 0)
        self.assertEqual(self.calls, ['doctor', 'run'])
        self.assertEqual(host.read_json(self.state / 'baseline.json')['consoleUser'], 'selected-user')

    def test_matching_applied_request_is_required_through_validation_and_cleaned_after_promotion(self):
        self.assertEqual(self.run_setup([self.result(receipt=self.request_id), self.result(receipt=self.request_id)]), 0)
        record = host.read_json(self.state / 'baseline.json')
        self.assertNotIn('pendingProvisioning', record)
        self.assertEqual(record['consoleUser'], 'selected-user')
        self.assertFalse((self.exchanges[0] / 'provision').exists())

    def test_wrong_account_or_changed_validation_receipt_cannot_promote(self):
        for phase, result in [('doctor', self.result(user='wrong-user', receipt=self.request_id)),
                              ('run', self.result(user='wrong-user', receipt=self.request_id)),
                              ('run', self.result(receipt=str(uuid.uuid4())))]:
            with self.subTest(phase=phase, result=result):
                self.calls.clear()
                values = [result] if phase == 'doctor' else [self.result(receipt=self.request_id), result]
                self.assertEqual(self.run_setup(values), 2)
                self.assertFalse((self.state / 'baseline.json').exists())
                record = host.read_json(self.state / 'candidate.json')
                self.assertNotIn('baseVerifiedAt', record)
                self.assertTrue(Path(record['pendingProvisioning']['path']).exists())

    def test_baseline_fast_path_requires_the_requested_account(self):
        shutil.rmtree(self.candidate)
        (self.state / 'candidate.json').unlink()
        (self.state / 'baseline.vbvm').mkdir()
        host.atomic_json(self.state / 'baseline.json', {**self.record, 'bootstrapTools': self.tools,
                        'bootstrapSourceDigest': host.bootstrap_source_digest()})
        with patch.object(host, 'validate_vm', return_value={}), patch.object(host, 'check_capacity'), \
                patch.object(host, 'build_tools', return_value=self.state / 'tools'), \
                patch.object(host, 'bootstrap_tool_hashes', return_value=self.tools), \
                patch.object(host, 'monitor_vm') as monitor, patch('sys.stdout', new=io.StringIO()):
            self.assertEqual(host.setup(self.args, self.state, self.environment), 0)
            monitor.assert_not_called()
            self.args.guest_user = 'another-user'
            with patch.object(host, 'clone_vm', side_effect=host.RunnerError('requires candidate validation')):
                with self.assertRaisesRegex(host.RunnerError, 'requires candidate validation'):
                    host.setup(self.args, self.state, self.environment)
