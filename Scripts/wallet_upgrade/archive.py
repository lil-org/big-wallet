#!/usr/bin/env python3

import argparse
import base64
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tarfile
import tempfile
import zlib


ROOT = Path(__file__).resolve().parents[2]
ARCHIVE_DIRECTORY = Path('Tests/Fixtures/ShippedMain/1.0.98-147')
BASELINE = {
    'commit': '03b1eb841180081063c6a64e5afe58c76d7f3732',
    'marketingVersion': '1.0.98',
    'buildVersion': '147',
    'platform': 'macos',
}
PROVENANCE = {'releaseConfirmation': 'user', 'confirmedOn': '2026-10-26'}
SWIFT_SOURCES = tuple('''App macOS/Content/Images.swift
Safari Shared/Models/InpageProvider.swift
Safari Shared/SharedDefaults.swift
Shared/Ethereum/EthereumAccessListEntry.swift
Shared/Ethereum/EthereumNetwork.swift
Shared/Ethereum/NetworkCatalog.swift
Shared/Extensions/FixedWidthInteger.swift
Shared/Extensions/Notification.swift
Shared/Extensions/String.swift
Shared/Extensions/WalletCoin.swift
Shared/Models/PlatformSpecificImage.swift
Shared/Models/SpecificWalletAccount.swift
Shared/Services/AlchemyJWTProvider.swift
Shared/Services/Defaults.swift
Shared/Services/Keychain.swift
Shared/Supporting Files/Strings.swift
Shared/Utilities/BigUInt.swift
Shared/Utilities/Blockies.swift
Shared/WalletCoreProxy/WalletCoreProxy.swift
Shared/WalletCoreProxy/WalletCoreProxyBIP39WordList.swift
Shared/WalletCoreProxy/WalletCoreProxyCrypto.swift
Shared/WalletCoreProxy/WalletCoreProxyEncoding.swift
Shared/WalletCoreProxy/WalletCoreProxyEthereum.swift
Shared/WalletCoreProxy/WalletCoreProxyHD.swift
Shared/WalletCoreProxy/WalletCoreProxySecp256k1.swift
Shared/WalletCoreProxy/WalletCoreProxyStoredKey.swift
Shared/Wallets/Account.swift
Shared/Wallets/WalletContainer.swift
Shared/Wallets/WalletsManager.swift
Shared/Wallets/WalletsMetadataService.swift'''.splitlines())
SECP_DIRECTORY = 'Shared/WalletCoreProxy/Secp256k1Backend/secp256k1/'
SECP_FILES = tuple(SECP_DIRECTORY + path for path in '''include/secp256k1.h
include/secp256k1_preallocated.h
include/secp256k1_recovery.h
src/assumptions.h
src/checkmem.h
src/ecdsa.h
src/ecdsa_impl.h
src/eckey.h
src/eckey_impl.h
src/ecmult.h
src/ecmult_compute_table.h
src/ecmult_compute_table_impl.h
src/ecmult_const.h
src/ecmult_const_impl.h
src/ecmult_gen.h
src/ecmult_gen_compute_table.h
src/ecmult_gen_compute_table_impl.h
src/ecmult_gen_impl.h
src/ecmult_impl.h
src/field.h
src/field_10x26.h
src/field_10x26_impl.h
src/field_5x52.h
src/field_5x52_impl.h
src/field_5x52_int128_impl.h
src/field_impl.h
src/group.h
src/group_impl.h
src/hash.h
src/hash_impl.h
src/hsort.h
src/hsort_impl.h
src/int128.h
src/int128_impl.h
src/int128_native.h
src/int128_native_impl.h
src/int128_struct.h
src/int128_struct_impl.h
src/modinv32.h
src/modinv32_impl.h
src/modinv64.h
src/modinv64_impl.h
src/modules/recovery/main_impl.h
src/precomputed_ecmult.c
src/precomputed_ecmult.h
src/precomputed_ecmult_gen.c
src/precomputed_ecmult_gen.h
src/scalar.h
src/scalar_4x64.h
src/scalar_4x64_impl.h
src/scalar_8x32.h
src/scalar_8x32_impl.h
src/scalar_impl.h
src/scalar_low.h
src/scalar_low_impl.h
src/scratch.h
src/scratch_impl.h
src/secp256k1.c
src/selftest.h
src/util.h
src/util_local_visibility.h'''.splitlines())
C_SOURCES = (
    'Shared/WalletCoreProxy/ScryptBackend/big_wallet_scrypt_shim.c',
    'Shared/WalletCoreProxy/Secp256k1Backend/big_wallet_secp256k1_shim.c',
    SECP_DIRECTORY + 'src/secp256k1.c',
    SECP_DIRECTORY + 'src/precomputed_ecmult.c',
    SECP_DIRECTORY + 'src/precomputed_ecmult_gen.c',
)
FILE_PATHS = tuple(sorted(set(SWIFT_SOURCES + SECP_FILES + C_SOURCES + (
    'LICENSE', SECP_DIRECTORY + 'COPYING',
))))
DEFINITIONS = ['ENABLE_MODULE_RECOVERY=1']
MAX_ARCHIVE_BYTES = 4 * 1024 * 1024
MAX_TAR_BYTES = 8 * 1024 * 1024
MAX_FILE_BYTES = 4 * 1024 * 1024
MAX_MANIFEST_BYTES = 256 * 1024
MAX_PROOF_OBJECT_BYTES = 32 * 1024
MAX_PROOF_BYTES = 128 * 1024


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def git_id(kind, data):
    return hashlib.sha1(kind.encode('ascii') + b' ' + str(len(data)).encode('ascii') + b'\0' + data).hexdigest()


def exact_keys(value, keys, label):
    if not isinstance(value, dict) or set(value) != set(keys):
        raise ValueError(f'Invalid {label} fields')


def hex_digest(value, length, label):
    if not isinstance(value, str) or re.fullmatch(f'[0-9a-f]{{{length}}}', value) is None:
        raise ValueError(f'Invalid {label}')


def bounded_integer(value, maximum, label):
    if type(value) is not int or not 0 <= value <= maximum:
        raise ValueError(f'Invalid {label}')


def safe_relative_path(path):
    if not isinstance(path, str) or not path or '\\' in path or '\0' in path or path.startswith('/'):
        raise ValueError('Invalid archive path')
    if any(part in ('', '.', '..') for part in path.split('/')):
        raise ValueError('Invalid archive path components')
    return path


def canonical_manifest(manifest):
    return (json.dumps(manifest, ensure_ascii=True, sort_keys=True, indent=2) + '\n').encode('utf-8')


def parse_manifest(data):
    if not isinstance(data, bytes) or len(data) > MAX_MANIFEST_BYTES:
        raise ValueError('Manifest exceeds its byte limit')

    def object_pairs(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('Duplicate manifest field')
            result[key] = value
        return result

    try:
        return json.loads(data, object_pairs_hook=object_pairs,
                          parse_constant=lambda _: (_ for _ in ()).throw(ValueError('Invalid JSON constant')))
    except (UnicodeError, RecursionError, json.JSONDecodeError) as error:
        raise ValueError('Invalid archive manifest JSON') from error


def canonical_tar(files):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode='w', format=tarfile.USTAR_FORMAT) as archive:
        for path in sorted(files):
            info = tarfile.TarInfo(safe_relative_path(path))
            info.size = len(files[path])
            info.mode = 0o644
            info.uid = info.gid = info.mtime = 0
            info.uname = info.gname = ''
            archive.addfile(info, io.BytesIO(files[path]))
    return output.getvalue()


def canonical_archive(files):
    output = io.BytesIO()
    with gzip.GzipFile(filename='', fileobj=output, mode='wb', compresslevel=9, mtime=0) as archive:
        archive.write(canonical_tar(files))
    return output.getvalue()


def parse_tree(data):
    entries = {}
    offset = 0
    while offset < len(data):
        separator = data.find(b' ', offset)
        end = data.find(b'\0', separator + 1)
        if separator < offset or end < separator or end + 21 > len(data):
            raise ValueError('Malformed Git tree object')
        mode = data[offset:separator].decode('ascii')
        name = data[separator + 1:end].decode('utf-8')
        if mode not in ('40000', '100644', '100755', '120000', '160000') or '/' in name:
            raise ValueError('Invalid Git tree entry')
        safe_relative_path(name)
        if name in entries:
            raise ValueError('Duplicate Git tree entry')
        entries[name] = (mode, data[end + 1:end + 21].hex())
        offset = end + 21
    return entries


def decode_proof_object(value, kind):
    exact_keys(value, ('id', 'type', 'base64'), f'Git {kind} object')
    hex_digest(value['id'], 40, 'Git object id')
    if value['type'] != kind or not isinstance(value['base64'], str) or len(value['base64']) > MAX_PROOF_OBJECT_BYTES * 2:
        raise ValueError('Invalid Git object encoding')
    try:
        data = base64.b64decode(value['base64'], validate=True)
    except (ValueError, UnicodeError) as error:
        raise ValueError('Invalid Git object base64') from error
    if len(data) > MAX_PROOF_OBJECT_BYTES or base64.b64encode(data).decode('ascii') != value['base64']:
        raise ValueError('Noncanonical or oversized Git object')
    if git_id(kind, data) != value['id']:
        raise ValueError('Git object id does not match its bytes')
    return data


def validate_proof(proof, records):
    exact_keys(proof, ('commit', 'trees'), 'Git proof')
    commit = decode_proof_object(proof['commit'], 'commit')
    if proof['commit']['id'] != BASELINE['commit']:
        raise ValueError('Git proof does not identify the pinned shipped commit')
    tree_line = commit.split(b'\n', 1)[0]
    if re.fullmatch(b'tree [0-9a-f]{40}', tree_line) is None:
        raise ValueError('Pinned commit has no canonical root tree')
    root_tree = tree_line[5:].decode('ascii')
    values = proof['trees']
    if not isinstance(values, list) or not 1 <= len(values) <= 64:
        raise ValueError('Invalid Git tree proof inventory')
    trees = {}
    total = len(commit)
    for value in values:
        data = decode_proof_object(value, 'tree')
        if value['id'] in trees:
            raise ValueError('Duplicate Git tree proof')
        total += len(data)
        if total > MAX_PROOF_BYTES:
            raise ValueError('Git proof exceeds its byte limit')
        trees[value['id']] = parse_tree(data)
    if [value['id'] for value in values] != sorted(trees):
        raise ValueError('Git tree proof must be sorted')
    visited = set()
    for record in records:
        tree = root_tree
        parts = record['path'].split('/')
        for index, part in enumerate(parts):
            if tree not in trees or part not in trees[tree]:
                raise ValueError(f'Incomplete Git proof for {record["path"]}')
            visited.add(tree)
            mode, identifier = trees[tree][part]
            if index == len(parts) - 1:
                if mode != record['mode'] or identifier != record['gitBlob']:
                    raise ValueError(f'File does not belong to the pinned commit: {record["path"]}')
            else:
                if mode != '40000':
                    raise ValueError('Git proof traverses a non-directory')
                tree = identifier
    if visited != set(trees):
        raise ValueError('Git proof contains unused tree objects')


def validate_manifest(manifest):
    exact_keys(manifest, ('schemaVersion', 'baseline', 'provenance', 'archive', 'files',
                          'swiftSources', 'cSources', 'definitions', 'gitProof'), 'manifest')
    if type(manifest['schemaVersion']) is not int or manifest['schemaVersion'] != 1:
        raise ValueError('Unsupported archive manifest version')
    if manifest['baseline'] != BASELINE or manifest['provenance'] != PROVENANCE:
        raise ValueError('Manifest does not identify the confirmed shipped baseline')
    if manifest['swiftSources'] != list(SWIFT_SOURCES) or manifest['cSources'] != list(C_SOURCES) or manifest['definitions'] != DEFINITIONS:
        raise ValueError('Manifest changes the pinned compilation inventory')
    archive = manifest['archive']
    exact_keys(archive, ('file', 'bytes', 'sha256'), 'archive descriptor')
    if archive['file'] != 'source.tar.gz':
        raise ValueError('Unexpected source archive filename')
    bounded_integer(archive['bytes'], MAX_ARCHIVE_BYTES, 'archive byte count')
    hex_digest(archive['sha256'], 64, 'archive digest')
    records = manifest['files']
    if not isinstance(records, list) or len(records) != len(FILE_PATHS):
        raise ValueError('Unexpected source file count')
    total = 0
    for record in records:
        exact_keys(record, ('path', 'mode', 'bytes', 'gitBlob', 'sha256'), 'source file')
        safe_relative_path(record['path'])
        if record['mode'] != '100644':
            raise ValueError('Source files must have regular nonexecutable Git mode')
        bounded_integer(record['bytes'], MAX_FILE_BYTES, 'source file byte count')
        hex_digest(record['gitBlob'], 40, 'source Git blob id')
        hex_digest(record['sha256'], 64, 'source digest')
        total += record['bytes']
    if tuple(record['path'] for record in records) != FILE_PATHS or total > MAX_TAR_BYTES:
        raise ValueError('Source file inventory does not match the pinned selection')
    validate_proof(manifest['gitProof'], records)


def decode_archive(data):
    if not isinstance(data, bytes) or len(data) > MAX_ARCHIVE_BYTES:
        raise ValueError('Source archive exceeds its byte limit')
    try:
        decompressor = zlib.decompressobj(16 + zlib.MAX_WBITS)
        raw = decompressor.decompress(data, MAX_TAR_BYTES + 1)
        if len(raw) > MAX_TAR_BYTES or decompressor.unconsumed_tail or decompressor.unused_data or not decompressor.eof:
            raise ValueError('Oversized, truncated, or concatenated source archive')
        files = {}
        with tarfile.open(fileobj=io.BytesIO(raw), mode='r:') as archive:
            for member in archive:
                path = safe_relative_path(member.name)
                if path not in FILE_PATHS or path in files or member.type != tarfile.REGTYPE or member.pax_headers:
                    raise ValueError('Unexpected, duplicate, or nonregular archive member')
                if (member.mode, member.uid, member.gid, member.mtime, member.uname, member.gname, member.linkname) != (0o644, 0, 0, 0, '', '', ''):
                    raise ValueError('Noncanonical archive metadata')
                bounded_integer(member.size, MAX_FILE_BYTES, 'archive member size')
                source = archive.extractfile(member)
                if source is None:
                    raise ValueError('Archive member has no file contents')
                files[path] = source.read(MAX_FILE_BYTES + 1)
                if len(files[path]) != member.size:
                    raise ValueError('Truncated archive member')
        if tuple(files) != FILE_PATHS or raw != canonical_tar(files):
            raise ValueError('Source tar inventory or encoding is not canonical')
        if data != canonical_archive(files):
            raise ValueError('Source gzip encoding is not canonical')
        return files
    except (tarfile.TarError, zlib.error, EOFError, UnicodeError) as error:
        raise ValueError('Invalid source archive') from error


def verify(manifest, archive_bytes):
    validate_manifest(manifest)
    if not isinstance(archive_bytes, bytes) or len(archive_bytes) != manifest['archive']['bytes'] or sha256(archive_bytes) != manifest['archive']['sha256']:
        raise ValueError('Source archive does not match its manifest digest')
    files = decode_archive(archive_bytes)
    for record in manifest['files']:
        data = files[record['path']]
        if len(data) != record['bytes'] or sha256(data) != record['sha256'] or git_id('blob', data) != record['gitBlob']:
            raise ValueError(f'Source file digest mismatch: {record["path"]}')
    return files


def read_regular_file(path, limit):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'rb') as file:
        metadata = os.fstat(file.fileno())
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_size > limit:
            raise ValueError(f'Expected a bounded regular file: {path}')
        data = file.read(limit + 1)
        if len(data) > limit:
            raise ValueError(f'File exceeds its byte limit: {path}')
        return data


def load_verified(root=ROOT):
    directory = Path(root) / ARCHIVE_DIRECTORY
    manifest = parse_manifest(read_regular_file(directory / 'manifest.json', MAX_MANIFEST_BYTES))
    data = read_regular_file(directory / 'source.tar.gz', MAX_ARCHIVE_BYTES)
    return manifest, verify(manifest, data)


def _git(root, *arguments):
    return subprocess.check_output(['git', '-C', str(root), *arguments], stderr=subprocess.PIPE)


def _proof_object(kind, data):
    return {'id': git_id(kind, data), 'type': kind, 'base64': base64.b64encode(data).decode('ascii')}


def generate(root=ROOT):
    revision = BASELINE['commit']
    commit = _git(root, 'cat-file', 'commit', revision)
    trees = {}
    records = []
    files = {}
    for path in FILE_PATHS:
        row = _git(root, 'ls-tree', '-z', revision, '--', path)
        expected_suffix = b'\t' + path.encode('utf-8') + b'\0'
        if not row.startswith(b'100644 blob ') or not row.endswith(expected_suffix):
            raise ValueError(f'Pinned source is not a regular file: {path}')
        identifier = row[len(b'100644 blob '):-len(expected_suffix)].decode('ascii')
        hex_digest(identifier, 40, 'pinned source blob id')
        data = _git(root, 'cat-file', 'blob', identifier)
        files[path] = data
        records.append({'path': path, 'mode': '100644', 'bytes': len(data), 'gitBlob': identifier, 'sha256': sha256(data)})
        parents = path.split('/')[:-1]
        for length in range(len(parents) + 1):
            parent = '/'.join(parents[:length])
            specifier = revision + (':' + parent if parent else '^{tree}')
            tree_id = _git(root, 'rev-parse', specifier).decode('ascii').strip()
            if tree_id not in trees:
                trees[tree_id] = _proof_object('tree', _git(root, 'cat-file', 'tree', tree_id))
    data = canonical_archive(files)
    manifest = {
        'schemaVersion': 1,
        'baseline': dict(BASELINE),
        'provenance': dict(PROVENANCE),
        'archive': {'file': 'source.tar.gz', 'bytes': len(data), 'sha256': sha256(data)},
        'files': records,
        'swiftSources': list(SWIFT_SOURCES),
        'cSources': list(C_SOURCES),
        'definitions': list(DEFINITIONS),
        'gitProof': {'commit': _proof_object('commit', commit), 'trees': [trees[key] for key in sorted(trees)]},
    }
    verify(manifest, data)
    return manifest, data


def _open_directory(path):
    path = Path(path)
    if not path.is_absolute() or '..' in path.parts:
        raise ValueError('Extraction destination must be an absolute path without traversal')
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    descriptor = os.open('/', flags)
    try:
        for part in path.parts[1:]:
            next_descriptor = os.open(part, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = next_descriptor
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def extract_verified(files, destination):
    if not isinstance(files, dict) or set(files) != set(FILE_PATHS) or any(
            not isinstance(data, bytes) or len(data) > MAX_FILE_BYTES for data in files.values()) or sum(map(len, files.values())) > MAX_TAR_BYTES:
        raise ValueError('Extraction requires the complete verified source inventory')
    destination = Path(destination)
    if not destination.is_absolute() or destination.name in ('', '.', '..'):
        raise ValueError('Extraction destination must be a new absolute directory')
    parent = _open_directory(destination.parent)
    root = None
    try:
        os.mkdir(destination.name, mode=0o700, dir_fd=parent)
        root = os.open(destination.name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
        os.fchmod(root, 0o700)
        for path in FILE_PATHS:
            safe_relative_path(path)
            descriptor = os.dup(root)
            try:
                parts = path.split('/')
                for part in parts[:-1]:
                    try:
                        os.mkdir(part, mode=0o700, dir_fd=descriptor)
                    except FileExistsError:
                        pass
                    next_descriptor = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
                    os.close(descriptor)
                    descriptor = next_descriptor
                file_descriptor = os.open(parts[-1], os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, mode=0o600, dir_fd=descriptor)
                with os.fdopen(file_descriptor, 'w+b') as file:
                    file.write(files[path])
                    file.flush()
                    os.fchmod(file.fileno(), 0o644)
                    os.fsync(file.fileno())
                    file.seek(0)
                    if file.read(MAX_FILE_BYTES + 1) != files[path]:
                        raise ValueError(f'Extracted source verification failed: {path}')
            finally:
                os.close(descriptor)
        os.fsync(root)
    finally:
        if root is not None:
            os.close(root)
        os.close(parent)


def _write_regular(path, data):
    try:
        metadata = path.lstat()
    except FileNotFoundError:
        metadata = None
    if metadata is not None and not stat.S_ISREG(metadata.st_mode):
        raise ValueError(f'Generated artifact must be a regular file: {path}')
    descriptor, name = tempfile.mkstemp(prefix=path.name + '.', dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, 'wb') as file:
            file.write(data)
            file.flush()
            os.fchmod(file.fileno(), 0o644)
            os.fsync(file.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description='Verify the unmodified shipped 1.0.98 wallet source archive')
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--write', action='store_true')
    mode.add_argument('--check', action='store_true')
    mode.add_argument('--verify', action='store_true')
    parser.add_argument('--extract', type=Path, metavar='ABS_NEW_DIR')
    parser.add_argument('--root', type=Path, default=ROOT)
    args = parser.parse_args(argv)
    if args.extract is not None and not args.verify:
        parser.error('--extract requires --verify')
    try:
        directory = args.root / ARCHIVE_DIRECTORY
        if args.write or args.check:
            manifest, data = generate(args.root)
            encoded = canonical_manifest(manifest)
            if args.write:
                directory.mkdir(parents=True, exist_ok=True)
                _write_regular(directory / 'source.tar.gz', data)
                _write_regular(directory / 'manifest.json', encoded)
            elif (read_regular_file(directory / 'manifest.json', MAX_MANIFEST_BYTES) != encoded or
                  read_regular_file(directory / 'source.tar.gz', MAX_ARCHIVE_BYTES) != data):
                raise ValueError('Shipped source archive differs from the pinned Git source; run archive.py --write')
        else:
            manifest, files = load_verified(args.root)
            if args.extract is not None:
                extract_verified(files, args.extract)
        print(json.dumps({'baseline': BASELINE['commit'], 'files': len(FILE_PATHS), 'sha256': manifest['archive']['sha256']}))
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
