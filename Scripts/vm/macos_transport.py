import base64
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import sys
import tempfile


_spec = importlib.util.spec_from_file_location('big_wallet_macos_access', Path(__file__).with_name('guest_access.py'))
access = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(access)
PREFIX = b'BIG_WALLET_MACOS_UPDATE='
MARKER = b'BIG_WALLET_MACOS_UPDATE_INPUT_V1'


class TransportError(RuntimeError):
    pass


class TransportUnavailable(TransportError):
    pass


def _request(context, target, upgrade_id):
    if (not isinstance(target, dict) or set(target) != {'version', 'buildVersion'} or
            not re.fullmatch(r'[1-9][0-9]*\.[0-9]+(?:\.[0-9]+)?', str(target.get('version', ''))) or
            not re.fullmatch(r'[0-9]{2}[A-Z][0-9]{1,6}', str(target.get('buildVersion', ''))) or
            not re.fullmatch(r'[a-f0-9]{64}', str(context.get('upgradeNonce', ''))) or
            not re.fullmatch(r'macos-upgrade-[A-Za-z0-9_-]{1,100}', str(upgrade_id)) or
            not re.fullmatch(r'[A-Za-z0-9_-]{1,128}', str(context.get('vmId', ''))) or
            not re.fullmatch(r'[A-Za-z0-9_-]{1,64}', str(context.get('user', '')))):
        raise TransportError('Invalid macOS upgrade target or guest identity')
    return {'target': target, 'upgradeID': upgrade_id, 'vmId': context['vmId'],
            'consoleUser': context['user'], 'upgradeNonce': context['upgradeNonce']}


def _response(contents, request):
    if len(contents) > 1024 * 1024:
        raise TransportError('Guest macOS response exceeded its limit')
    lines = [line[len(PREFIX):] for line in contents.splitlines() if line.startswith(PREFIX)]
    try:
        value = json.loads(lines[0]) if len(lines) == 1 else None
    except (ValueError, UnicodeError):
        value = None
    if not isinstance(value, dict) or value.get('status') not in ('ready', 'installing', 'complete', 'blocked', 'failed'):
        raise TransportError('Invalid guest macOS response')
    actual = value.get('actual')
    if (not isinstance(actual, dict) or set(actual) != {'version', 'buildVersion'} or
            not re.fullmatch(r'[0-9]+\.[0-9]+(?:\.[0-9]+)?', str(actual.get('version', ''))) or
            not re.fullmatch(r'[0-9]{2}[A-Z][0-9]{1,6}[a-z]?', str(actual.get('buildVersion', ''))) or
            not re.fullmatch(r'[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}', str(value.get('bootIdentity', ''))) or
            type(value.get('safeToStop')) is not bool):
        raise TransportError('Guest macOS response omitted a valid OS and boot identity')
    if value['status'] == 'complete' and actual != request['target']:
        raise TransportError('Guest macOS result does not match the requested target')
    receipt = value.get('receipt')
    if receipt is not None and (not isinstance(receipt, dict) or receipt.get('version') != 1 or
                               any(receipt.get(key) != request[key] for key in request) or
                               receipt.get('phase') not in ('starting', 'installing', 'restart-pending', 'complete', 'failed')):
        raise TransportError('Guest macOS receipt does not match this upgrade')
    if 'reason' in value and not re.fullmatch(r'[a-z0-9_]{1,128}', str(value['reason'])):
        raise TransportError('Guest macOS response has an invalid reason')
    if 'diagnostics' in value and (not isinstance(value['diagnostics'], dict) or
                                  len(json.dumps(value['diagnostics']).encode()) > 32768):
        raise TransportError('Guest macOS diagnostics exceeded their limit')
    abandonment = value.get('abandonment')
    if abandonment is not None and (not isinstance(abandonment, dict) or abandonment.get('version') != 1 or
            any(abandonment.get(key) != request[key] for key in request) or
            not re.fullmatch(r'[a-f0-9]{64}', str(abandonment.get('receiptSHA256', '')))):
        raise TransportError('Guest macOS abandonment does not match this upgrade')
    return value


def _guest_error(contents):
    if len(contents) > 1024 * 1024:
        raise TransportError('Guest macOS error response exceeded its limit')
    lines = [line[len(PREFIX):] for line in contents.splitlines() if line.startswith(PREFIX)]
    if not lines:
        return None
    try:
        value = json.loads(lines[0]) if len(lines) == 1 else None
    except (ValueError, UnicodeError):
        value = None
    if (not isinstance(value, dict) or set(value) not in ({'status', 'reason'}, {'status', 'reason', 'scope'}) or
            value.get('status') != 'failed' or not re.fullmatch(r'[a-z][a-z0-9_]{0,127}', str(value.get('reason', ''))) or
            'scope' in value and value['scope'] != 'live-os-probe'):
        raise TransportError('Invalid guest macOS error response')
    return value


def _failed_transport(code, contents):
    failure = _guest_error(contents)
    if failure is not None:
        reason = failure['reason']
        if failure.get('scope') == 'live-os-probe' and reason in ('guest_update_probe_unavailable', 'guest_update_probe_failed'):
            raise TransportUnavailable(f'Guest live OS probe is temporarily unavailable ({reason})')
        raise TransportError(f'Guest rejected the macOS update request ({reason})')
    rejected = re.search(rb'permission denied|authentication failed|too many authentication failures|'
                         rb'host key verification failed|remote host identification has changed|'
                         rb'no matching host key type found|incorrect password attempt', contents, re.IGNORECASE)
    if rejected:
        raise TransportError('Guest macOS authentication or pinned SSH identity was rejected')
    if code == 255 or code < 0:
        raise TransportUnavailable('Guest macOS SSH disconnected; the update may still be running')
    raise TransportError('Guest rejected the macOS update request or authentication')


def _redact_diagnostics(value, password):
    def redact(item):
        if isinstance(item, str):
            return item.replace(password, '[REDACTED]') if password else item
        if isinstance(item, list):
            return [redact(entry) for entry in item]
        if isinstance(item, dict):
            return {key: redact(entry) for key, entry in item.items()}
        return item
    if 'diagnostics' in value:
        value['diagnostics'] = redact(value['diagnostics'])
        if len(json.dumps(value['diagnostics']).encode()) > 32768:
            value['diagnostics'] = {'unavailable': ['diagnostic_redaction_exceeded_limit']}
    return value


def _stop(child):
    if child.poll() is None:
        try:
            os.killpg(child.pid, signal.SIGTERM)
            child.wait(timeout=3)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait(timeout=3)
        except ProcessLookupError:
            child.wait(timeout=3)


def _growth(value):
    numbers = ('oldBytes', 'newBytes', 'sectorBytes', 'mainPartitionBytes', 'expectedContainerBytes', 'gapBytes',
               'mainFirstLBA', 'mainLastLBA', 'recoveryFirstLBA', 'recoveryLastLBA', 'recoveryBytes', 'trailingPaddingSectors')
    identifiers = ('diskGUID', 'mainPartitionGUID', 'recoveryPartitionGUID')
    if (not isinstance(value, dict) or any(type(value.get(key)) is not int or value[key] < 0 for key in numbers) or
            any(not isinstance(value.get(key), str) or
                not re.fullmatch(r'[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}', value[key]) for key in identifiers)):
        raise TransportError('Invalid public system-disk growth proof')
    return {**{key: value[key] for key in numbers}, **{key: value[key].upper() for key in identifiers}}


def _resize_result(value, growth, request):
    storage = value.get('storage')
    if not isinstance(storage, dict) or storage.get('status') not in ('growing', 'grown', 'preflight-rejected'):
        raise TransportError('Guest did not return a storage-growth observation')
    if storage['status'] == 'preflight-rejected':
        if (value['status'] != 'blocked' or not value['safeToStop'] or not value.get('reason') or
                storage.get('request') != request or storage.get('growth') != growth):
            raise TransportError('Guest did not prove the resize was rejected before recording intent')
        return value
    if storage['status'] == 'growing':
        if value['status'] != 'installing' or value['safeToStop']:
            raise TransportError('Guest claimed a safe stop during storage growth')
        return value
    after = storage.get('after')
    low_space = value['status'] == 'blocked' and value.get('reason') == 'guest_storage_insufficient_free_space_after_growth'
    if ((value['status'] != 'ready' and not low_space) or not value['safeToStop'] or not isinstance(after, dict) or
            not isinstance(storage.get('before'), dict) or
            storage.get('upgradeID') != request['upgradeID'] or storage.get('vmId') != request['vmId'] or
            storage.get('growth') != growth or
            not isinstance(after.get('main'), dict) or not isinstance(after.get('recovery'), dict) or
            not isinstance(after.get('mainContainer'), dict) or
            after['mainContainer'].get('capacityBytes') != growth['expectedContainerBytes'] or
            storage.get('expectedContainerBytes') != growth['expectedContainerBytes'] or
            after.get('main', {}).get('bytes') != growth['expectedContainerBytes'] or
            str(after.get('main', {}).get('uuid', '')).upper() != growth['mainPartitionGUID'].upper() or
            str(after.get('recovery', {}).get('uuid', '')).upper() != growth['recoveryPartitionGUID'].upper() or
            after.get('recovery', {}).get('bytes') != growth['recoveryBytes'] or
            after.get('recovery', {}).get('offset') != growth['recoveryFirstLBA'] * growth['sectorBytes']):
        raise TransportError('Guest storage growth does not match the isolated disk proof')
    return value


def _invoke(host, context, target, upgrade_id, action, *, growth=None):
    request = _request(context, target, upgrade_id)
    growth = _growth(growth) if action == 'resize' else None
    password = b''
    askpass = None
    child = None
    try:
        work = access._private_directory(context['workDirectory'])
        password = access.read_private_password(context['passwordFile'])
        command = access.ssh_command(context['address'], context['user'], context['knownHosts'],
                                     'big-wallet-vm-' + context['vmId'])
        source = Path(__file__).with_name('macos_update_guest.py').read_bytes()
        encoded = base64.b64encode(source).decode('ascii')
        program = 'import base64; SOURCE_BYTES=base64.b64decode(' + repr(encoded) + '); '
        if action == 'resize':
            storage_source = base64.b64encode(Path(__file__).with_name('macos_storage_guest.py').read_bytes()).decode('ascii')
            program += 'STORAGE_SOURCE_BYTES=base64.b64decode(' + repr(storage_source) + '); '
        program += 'exec(compile(SOURCE_BYTES,"macos_update_guest.py","exec"))'
        invocation = ['/usr/bin/sudo', '-S', '-p', '', '--', '/usr/bin/python3', '-c', program,
                      'observe' if action == 'diagnose' else action]
        if action == 'diagnose':
            invocation.append('--diagnostics')
        root = shlex.join(invocation)
        remote = ('case "$(/usr/sbin/sysctl -n hw.model)" in VirtualMac*) ;; *) exit 71 ;; esac; '
                  '[ "$(/usr/bin/id -un)" = ' + shlex.quote(context['user']) + ' ] || exit 73; exec ' + root)
        command.append(remote)
        descriptor, name = tempfile.mkstemp(prefix='macos-askpass-', dir=work)
        askpass = Path(name)
        with os.fdopen(descriptor, 'w') as file:
            file.write('#!/bin/sh\nexec ' + shlex.join([sys.executable, str(Path(access.__file__).resolve()),
                                                     '--askpass', str(Path(context['passwordFile']).absolute())]) + '\n')
        askpass.chmod(0o700)
        environment = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(work), 'LANG': 'C',
                       'SSH_ASKPASS': str(askpass), 'SSH_ASKPASS_REQUIRE': 'force'}
        payload = password + b'\n' + MARKER + b'\n' + json.dumps(request).encode() + b'\n'
        if action in ('start', 'diagnose'):
            payload += password + b'\n'
        if action == 'resize':
            payload += json.dumps(growth).encode() + b'\n'
        with tempfile.TemporaryFile(dir=work) as output:
            child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=output, stderr=output,
                                     env=environment, start_new_session=True)
            try:
                child.communicate(input=payload, timeout=900 if action == 'resize' else 300 if action in ('probe', 'start') else 45)
            except subprocess.TimeoutExpired:
                _stop(child)
                raise TransportUnavailable('Guest macOS transport timed out; reconcile the recorded update before retrying') from None
            finally:
                payload = b''
            output.seek(0)
            contents = output.read(1024 * 1024 + 1)
            if child.returncode != 0:
                _failed_transport(child.returncode, contents)
        response = _redact_diagnostics(_response(contents, request), password.decode('utf-8', errors='replace'))
        return _resize_result(response, growth, request) if action == 'resize' else response
    except access.GuestAccessError as error:
        raise TransportError(str(error)) from None
    except (KeyError, OSError):
        raise TransportError('Could not establish the protected macOS guest transport') from None
    finally:
        if child is not None:
            _stop(child)
        if askpass is not None:
            askpass.unlink(missing_ok=True)
        password = b''


def probe(host, context, target, upgrade_id):
    return _invoke(host, context, target, upgrade_id, 'probe')


def start(host, context, target, upgrade_id):
    return _invoke(host, context, target, upgrade_id, 'start')


def observe(host, context, target, upgrade_id):
    return _invoke(host, context, target, upgrade_id, 'observe')


def diagnose(host, context, target, upgrade_id):
    return _invoke(host, context, target, upgrade_id, 'diagnose')


def abandon(host, context, target, upgrade_id):
    return _invoke(host, context, target, upgrade_id, 'abandon')


def halt_abandoned(host, context, target, upgrade_id):
    if context.get('supervisorExited') is not True:
        raise TransportError('The host must verify supervisor exit before requesting the abandoned guest shutdown')
    return _invoke(host, context, target, upgrade_id, 'halt-abandoned')


def resize(host, context, target, upgrade_id, growth):
    return _invoke(host, context, target, upgrade_id, 'resize', growth=growth)
