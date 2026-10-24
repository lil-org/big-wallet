import copy
import datetime
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import uuid


def pins_module():
    spec = importlib.util.spec_from_file_location('vm_environment_pins', Path(__file__).with_name('environment_pins.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def installed_xcode(host, xcode):
    with host.open_regular(Path(xcode) / 'Contents/version.plist') as file:
        value = plistlib.load(file)
    version, build = value.get('CFBundleShortVersionString'), value.get('ProductBuildVersion')
    if (not isinstance(version, str) or re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,2}', version) is None or
            not isinstance(build, str) or re.fullmatch(r'[0-9]+[A-Z][0-9]+[a-z]?', build) is None):
        raise host.RunnerError('Installed Xcode has invalid version/build metadata')
    return {'version': version, 'buildVersion': build}


def inspect_xcode(host, xcode):
    xcode = Path(xcode)
    if xcode.is_symlink() or not xcode.is_dir() or xcode.name != 'Xcode.app':
        raise host.RunnerError('Select a real Xcode.app directory with --xcode')
    identity = installed_xcode(host, xcode)
    seal = host.hash_regular_file(xcode / 'Contents/_CodeSignature/CodeResources')
    try:
        host.checked(['/usr/bin/codesign', '--verify', '--strict', xcode], timeout=300)
    except subprocess.TimeoutExpired as error:
        raise host.RunnerError('Xcode signature verification timed out; retry after installation completes') from error
    framework = xcode / 'Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks/XCUIAutomation.framework'
    with host.open_regular(framework / 'Info.plist') as file:
        info = plistlib.load(file)
    if (info.get('CFBundleIdentifier') != 'com.apple.dt.XCUIAutomation' or
            info.get('CFBundleExecutable') != 'XCUIAutomation' or
            not isinstance(info.get('CFBundleVersion'), str) or
            re.fullmatch(r'[1-9][0-9]*', info['CFBundleVersion']) is None):
        raise host.RunnerError('Installed Xcode has unsupported XCUIAutomation framework metadata')
    try:
        output = host.checked(['/usr/bin/xcrun', 'dwarfdump', '--uuid', framework / 'XCUIAutomation'],
                              env=dict(os.environ, DEVELOPER_DIR=str(xcode / 'Contents/Developer')), text=True, timeout=60)
    except subprocess.TimeoutExpired as error:
        raise host.RunnerError('XCUIAutomation image inspection timed out') from error
    matches = re.findall(r'^UUID: ([0-9A-Fa-f-]{36}) \(arm64\) ', output, re.MULTILINE)
    if len(matches) != 1:
        raise host.RunnerError('XCUIAutomation must contain exactly one arm64 image UUID')
    try:
        image_uuid = str(uuid.UUID(matches[0])).upper()
    except ValueError as error:
        raise host.RunnerError('XCUIAutomation has an invalid arm64 image UUID') from error
    if identity != installed_xcode(host, xcode) or seal != host.hash_regular_file(xcode / 'Contents/_CodeSignature/CodeResources'):
        raise host.RunnerError('Xcode changed during inspection; retry after installation completes')
    return {'xcode': identity, 'safariSynchronization': {'framework': {
        'bundleIdentifier': info['CFBundleIdentifier'], 'version': info['CFBundleVersion'], 'imageUUID': image_uuid}},
        'codeResourcesSHA256': seal}


def pin_paths(root):
    return (Path(root) / 'Scripts/vm/environment.json',
            Path(root) / 'Tests/SafariUI/BWSafariSynchronizationPin.generated.h')


def read_pin(host, path):
    if path.resolve() != path:
        raise host.RunnerError(f'Toolchain pin must not traverse a symlink: {path}')
    with host.open_regular(path) as file:
        data = file.read(1024 * 1024 + 1)
    if len(data) > 1024 * 1024:
        raise host.RunnerError('Toolchain pin exceeds the supported file size')
    return data.decode('utf-8')


def pending_update(host, state, root):
    path = state / 'xcode-pin-update.json'
    if not path.exists() and not path.is_symlink():
        return None
    value = host.read_json(path)
    if (not isinstance(value, dict) or set(value) != {'version', 'repository', 'files'} or value['version'] != 1 or
            value['repository'] != str(root) or not isinstance(value['files'], list) or len(value['files']) != 2):
        raise host.RunnerError('An unrelated or invalid Xcode pin update is pending; preserve it before retrying')
    for entry, target in zip(value['files'], pin_paths(root)):
        if (not isinstance(entry, dict) or set(entry) != {'path', 'before', 'after', 'mode'} or
                entry['path'] != str(target) or not all(isinstance(entry[key], str) for key in ('before', 'after')) or
                type(entry['mode']) is not int or not 0 <= entry['mode'] <= 0o777 or
                read_pin(host, target) not in (entry['before'], entry['after'])):
            raise host.RunnerError('Toolchain pin changed during an interrupted update; preserve local edits before retrying')
    return value


def write_pin(host, path, before, after, mode):
    if read_pin(host, path) != before:
        raise host.RunnerError('Toolchain pin changed before replacement; local edits were preserved')
    temporary = path.with_name(path.name + '.' + uuid.uuid4().hex + '.tmp')
    try:
        with open(temporary, 'x', encoding='utf-8') as file:
            file.write(after)
            file.flush()
            os.fsync(file.fileno())
        temporary.chmod(mode)
        if read_pin(host, path) != before:
            raise host.RunnerError('Toolchain pin changed during replacement; local edits were preserved')
        os.replace(temporary, path)
        sync_directory(path.parent)
    finally:
        temporary.unlink(missing_ok=True)


def sync_directory(path):
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def finish_pin_update(host, state, root):
    pending = pending_update(host, state, root)
    if pending is None:
        return
    for entry in pending['files']:
        path = Path(entry['path'])
        if read_pin(host, path) != entry['after']:
            write_pin(host, path, entry['before'], entry['after'], entry['mode'])
    (state / 'xcode-pin-update.json').unlink()
    sync_directory(state)


def target_environment(environment, installed):
    target = copy.deepcopy(environment)
    target['xcode'].update(installed['xcode'])
    target.setdefault('safariSynchronization', {}).update(installed['safariSynchronization'])
    return target


def adopt_pins(host, state, root, installed):
    finish_pin_update(host, state, root)
    environment_path, header_path = pin_paths(root)
    original = read_pin(host, environment_path)
    environment = json.loads(original)
    pins = pins_module()
    header = read_pin(host, header_path)
    if header != pins.render_safari_header(environment).decode('utf-8'):
        raise host.RunnerError('Generated Safari pins differ from environment.json; preserve local edits and regenerate before upgrading')
    target = target_environment(environment, installed)
    if target == environment:
        return target
    replacements = [json.dumps(target, indent=2, ensure_ascii=False) + '\n',
                    pins.render_safari_header(target).decode('utf-8')]
    entries = [{'path': str(path), 'before': before, 'after': after, 'mode': stat.S_IMODE(path.stat().st_mode)}
               for path, before, after in zip((environment_path, header_path), (original, header), replacements)]
    host.atomic_json(state / 'xcode-pin-update.json', {'version': 1, 'repository': str(root), 'files': entries})
    sync_directory(state)
    finish_pin_update(host, state, root)
    return target


def preview(host, args, state):
    installed = inspect_xcode(host, args.xcode)
    environment_path, header_path = pin_paths(host.ROOT)
    environment = json.loads(read_pin(host, environment_path))
    pending = pending_update(host, state, host.ROOT)
    if pending is None and read_pin(host, header_path) != pins_module().render_safari_header(environment).decode('utf-8'):
        raise host.RunnerError('Generated Safari pins differ from environment.json; regenerate them before upgrading')
    target = target_environment(environment, installed)
    prerequisites = []
    pins_module().render_safari_header(target)
    def check(name, action):
        try:
            prerequisites.append({'name': name, 'status': 'passed', 'detail': action()})
        except (host.RunnerError, OSError, ValueError, KeyError) as error:
            prerequisites.append({'name': name, 'status': 'blocked', 'detail': str(error)})
    check('vm', lambda: host.validate_vm(args.vm)['hardware']['cpuCount'])
    capacity_path = state
    while not capacity_path.exists():
        capacity_path = capacity_path.parent
    check('disk', lambda: host.check_capacity(capacity_path, environment['minimumHostFreeBytes']))
    check('manifestNode', host.manifest_node)
    def baseline():
        candidate_path = state / 'candidate.json'
        candidate = host.read_json(candidate_path) if candidate_path.exists() else {}
        pending_promotion = candidate.get('promotionPending')
        record = candidate if pending_promotion else host.read_json(state / 'baseline.json')
        if not host.matches_source_vm(record, args.vm) or not record.get('verifiedAt') or not record.get('consoleUser'):
            raise host.RunnerError('Xcode upgrade requires the existing verified baseline and guest account; run setup first')
        template = state / 'baseline.vbvm'
        if pending_promotion:
            template = state / 'candidate.vbvm' if (state / 'candidate.vbvm').exists() else template
            metadata = template.lstat()
            if [metadata.st_dev, metadata.st_ino] != pending_promotion.get('candidateFileID'):
                raise host.RunnerError('Pending baseline promotion no longer owns its candidate')
        host.validate_vm(template)
        inherited = host.inherited_safari_preparation(state, record, record['consoleUser'])
        return {'consoleUser': record['consoleUser'], 'xcode': record.get('environment', {}).get('xcode'),
                'safariPreparation': inherited.get('safariPreparation'), 'promotionPending': bool(pending_promotion)}
    check('baseline', baseline)
    report = {'version': 1, 'status': 'ready' if all(item['status'] == 'passed' for item in prerequisites) else 'blocked',
              'xcodePath': str(args.xcode), 'pinned': {'xcode': environment['xcode'],
                  'safariSynchronization': environment.get('safariSynchronization')},
              'target': {key: target[key] for key in ('xcode', 'safariSynchronization')},
              'runtimes': target['runtimes'], 'changesRequired': target != environment,
              'pendingPinUpdate': pending is not None, 'prerequisites': prerequisites,
              'verification': 'Guest setup, iOS hook test, macOS/iOS Safari roundtrips, then unfiltered run all with local signing'}
    return report, installed


def upgrade(host, args, state):
    report, installed = preview(host, args, state)
    print(json.dumps(report, indent=2), flush=True)
    if report['status'] != 'ready':
        return 2
    if args.check:
        return 0
    identifier = 'xcode-upgrade-' + datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8]
    directory = host.private_directory(state / 'upgrades' / identifier)
    report_path = directory / 'result.json'
    result = {'version': 1, 'status': 'running', 'target': report['target'], 'runtimes': report['runtimes'],
              'repository': str(host.ROOT), 'steps': [], 'fullSuiteVerified': False}
    def save():
        host.atomic_json(report_path, result)
        host.atomic_json(state / 'latest-xcode-upgrade.json', {'version': 1, 'result': str(report_path)})
    save()
    print(f'Xcode upgrade results: {report_path}', flush=True)
    try:
        environment = adopt_pins(host, state, host.ROOT, installed)
        setup_args = host.parser().parse_args(['setup'])
        for key in ('vm', 'xcode', 'state_dir', 'timeout'):
            setattr(setup_args, key, getattr(args, key))
        step = {'name': 'setup', 'status': 'running'}
        result['steps'].append(step)
        save()
        def observed(path, native_result):
            step['result'] = str(path)
            step['source'] = native_result.get('source')
            step['coverage'] = native_result.get('coverage')
            step['guestStatus'] = native_result.get('status')
            step['reason'] = native_result.get('reason')
            step['versions'] = native_result.get('preflight', {}).get('versions')
        code = host.setup(setup_args, state, environment, result_callback=observed)
        step['status'] = 'passed' if code == 0 else step.get('guestStatus', 'blocked')
        if code:
            result['status'] = step['status'] if step['status'] in ('failed', 'cancelled', 'blocked') else 'blocked'
            return code
        result['baselineSetupVerified'] = True
        save()
        baseline = host.read_json(state / 'baseline.json')
        if not host.inherited_safari_preparation(state, baseline, baseline['consoleUser']):
            reason = ('Run Scripts/test_vm.sh setup --interactive --safari-activation with the same '
                      '--vm, --state-dir and --xcode, then rerun upgrade-xcode')
            result['steps'].append({'name': 'safari-preparation', 'status': 'blocked', 'reason': reason})
            result['status'] = 'blocked'
            print(reason, flush=True)
            return 2
        commands = [
            ('safari-hook', ['run', 'all', '--stage', 'test', '--configuration', 'Debug',
                             '--only-testing', 'Tests iOS/BWSafariSynchronizationTests']),
            ('safari-roundtrips', ['run', 'all', '--stage', 'safari', '--configuration', 'Debug',
                                   '--only-testing', 'SafariLifecycleTests/testInstallAndNativeRoundtrip']),
            ('full-suite', ['run', 'all']),
        ]
        for name, command in commands:
            run_args = host.parser().parse_args(command)
            for key in ('vm', 'xcode', 'state_dir', 'timeout'):
                setattr(run_args, key, getattr(args, key))
            step = {'name': name, 'status': 'running'}
            result['steps'].append(step)
            save()
            code = host.run_tests(run_args, state, environment, result_callback=observed)
            if code:
                step['status'] = step.get('guestStatus', 'failed')
                result['status'] = step['status'] if step['status'] in ('failed', 'cancelled', 'blocked') else 'failed'
                return code
            if name == 'full-suite':
                if (step.get('coverage') or {}).get('fullSuiteVerified') is not True:
                    raise host.RunnerError('The unfiltered VM run did not attest full-suite verification')
                result['fullSuiteVerified'] = True
            step['status'] = 'passed'
            save()
        result['status'] = 'passed'
        return 0
    except BaseException as error:
        result['status'] = 'cancelled' if isinstance(error, KeyboardInterrupt) else 'blocked'
        result['reason'] = str(error)
        if result['steps'] and result['steps'][-1]['status'] == 'running':
            result['steps'][-1]['status'] = result['status']
        raise
    finally:
        result['finishedAt'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        save()
        print(f'{result["status"].upper()}: {report_path}', flush=True)
