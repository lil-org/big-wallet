#!/usr/bin/env python3

import argparse
import json
import os
from pathlib import Path
import re
import stat
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[2]
HEADER = Path('Tests/SafariUI/BWSafariSynchronizationPin.generated.h')


def validate_safari_framework(environment) -> dict:
    synchronization = environment.get('safariSynchronization') if isinstance(environment, dict) else None
    if not isinstance(synchronization, dict) or set(synchronization) != {'framework'}:
        raise ValueError('Expected safariSynchronization.framework in the VM environment')
    framework = synchronization['framework']
    if not isinstance(framework, dict) or set(framework) != {'bundleIdentifier', 'version', 'imageUUID'}:
        raise ValueError('Invalid Safari synchronization framework fields')
    if framework['bundleIdentifier'] != 'com.apple.dt.XCUIAutomation':
        raise ValueError('Unsupported Safari synchronization framework bundle identifier')
    if not isinstance(framework['version'], str) or not re.fullmatch(r'[1-9][0-9]*', framework['version']):
        raise ValueError('Invalid Safari synchronization framework version')
    if not isinstance(framework['imageUUID'], str) or not re.fullmatch(
            r'[0-9A-F]{8}(?:-[0-9A-F]{4}){3}-[0-9A-F]{12}', framework['imageUUID']):
        raise ValueError('Invalid Safari synchronization framework arm64 image UUID')
    return dict(framework)


def render_safari_header(environment) -> bytes:
    framework = validate_safari_framework(environment)
    return (
        '// Generated from Scripts/vm/environment.json by Scripts/vm/environment_pins.py.\n'
        '#ifndef BW_SAFARI_SYNCHRONIZATION_PIN_GENERATED_H\n'
        '#define BW_SAFARI_SYNCHRONIZATION_PIN_GENERATED_H\n\n'
        f'#define BW_SAFARI_FRAMEWORK_IDENTIFIER @"{framework["bundleIdentifier"]}"\n'
        f'#define BW_SAFARI_FRAMEWORK_VERSION @"{framework["version"]}"\n'
        f'#define BW_SAFARI_FRAMEWORK_UUID @"{framework["imageUUID"]}"\n\n'
        '#endif\n'
    ).encode('utf-8')


def write_safari_header(path, contents):
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        metadata = None
    if metadata is not None and not stat.S_ISREG(metadata.st_mode):
        raise ValueError('Generated Safari synchronization header must be a regular file')
    if metadata is not None and path.read_bytes() == contents:
        return False
    mode = stat.S_IMODE(metadata.st_mode) if metadata is not None else 0o644
    descriptor, name = tempfile.mkstemp(prefix=path.name + '.', suffix='.tmp', dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, 'wb') as file:
            file.write(contents)
            file.flush()
            os.fchmod(file.fileno(), mode)
            os.fsync(file.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        temporary.unlink(missing_ok=True)
    return True


def main(argv=None):
    parser = argparse.ArgumentParser(description='Validate the generated Safari synchronization pins')
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--check', action='store_true')
    mode.add_argument('--write', action='store_true')
    parser.add_argument('--root', type=Path, default=ROOT)
    args = parser.parse_args(argv)
    try:
        environment = json.loads((args.root / 'Scripts/vm/environment.json').read_text())
        expected = render_safari_header(environment)
        if args.write:
            if write_safari_header(args.root / HEADER, expected):
                print(f'Generated {HEADER}')
        elif (args.root / HEADER).read_bytes() != expected:
            raise ValueError(f'{HEADER} does not match Scripts/vm/environment.json; '
                             'run python3 Scripts/vm/environment_pins.py --write')
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
