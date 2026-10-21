import json
import os
from pathlib import Path
import re
import sys


def validate(path, run_id):
    source = Path(path)
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,127}', run_id) or '..' in run_id:
        raise ValueError('Invalid Safari VM run identity')
    if source.resolve() != source or not source.is_file() or source.stat().st_size > 8192:
        raise ValueError('Invalid Safari VM descriptor file')
    value = json.loads(source.read_text())
    if set(value) != {'version', 'runID', 'root', 'platform', 'signingMode', 'configuration'}:
        raise ValueError('Invalid Safari VM descriptor fields')
    if value['version'] != 1 or value['runID'] != run_id or value['platform'] not in ('macos', 'ios') or value['signingMode'] not in ('local', 'apple') or value['configuration'] not in ('Debug', 'Release'):
        raise ValueError('Invalid Safari VM descriptor values')
    root = Path('/Volumes/BigWalletBuild/Exchange') / run_id / 'safari' / value['platform'] / value['configuration']
    if value['root'] != str(root) or source != root / 'SafariVMRun.json' or root.resolve() != root:
        raise ValueError('Safari VM descriptor root mismatch')
    info = root.stat()
    if info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise ValueError('Safari VM root must be private and owned by the guest account')
    marker = root / '.run.json'
    if marker.resolve() != marker or marker.stat().st_size > 8192 or json.loads(marker.read_text()) != value:
        raise ValueError('Safari VM active run marker mismatch')
    return value


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('Expected descriptor path and run ID')
    validate(sys.argv[1], sys.argv[2])
