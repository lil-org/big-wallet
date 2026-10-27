import base64
import contextlib
import copy
import gzip
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import tarfile
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location('upgrade_archive', Path(__file__).resolve().parents[2] / 'wallet_upgrade/archive.py')
archive = importlib.util.module_from_spec(spec)
spec.loader.exec_module(archive)


class UpgradeArchiveTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        directory = archive.ROOT / archive.ARCHIVE_DIRECTORY
        cls.manifest_bytes = (directory / 'manifest.json').read_bytes()
        cls.manifest = archive.parse_manifest(cls.manifest_bytes)
        cls.archive_bytes = (directory / 'source.tar.gz').read_bytes()
        cls.files = archive.verify(cls.manifest, cls.archive_bytes)

    def assert_invalid_manifest(self, manifest):
        with self.assertRaises(ValueError):
            archive.verify(manifest, self.archive_bytes)

    def tar_variant(self, change):
        output = io.BytesIO()
        with tarfile.open(fileobj=output, mode='w', format=tarfile.PAX_FORMAT) as target:
            for index, (path, data) in enumerate(self.files.items()):
                member = tarfile.TarInfo(path)
                member.mode = 0o644
                member.size = len(data)
                members = [(member, data)]
                if index == 0:
                    members = change(member, data)
                for item, contents in members:
                    target.addfile(item, io.BytesIO(contents) if contents is not None else None)
        compressed = io.BytesIO()
        with gzip.GzipFile(filename='', fileobj=compressed, mode='wb', compresslevel=9, mtime=0) as target:
            target.write(output.getvalue())
        return compressed.getvalue()

    def test_checked_in_archive_is_canonical_and_anchored_to_the_confirmed_commit(self):
        self.assertEqual(len(self.files), 95)
        self.assertEqual(len(self.manifest['swiftSources']), 30)
        self.assertEqual(len(self.manifest['cSources']), 5)
        self.assertEqual(len(self.manifest['gitProof']['trees']), 21)
        self.assertEqual(sum(map(len, self.files.values())), 3_658_711)
        self.assertEqual(len(self.archive_bytes), 1_717_856)
        self.assertEqual(archive.sha256(self.archive_bytes), 'abc40a4b3315a83734b6685b33afd59c0e32cfa3efd04b3d825d5ee3a3a12912')
        self.assertEqual(archive.canonical_manifest(self.manifest), self.manifest_bytes)
        self.assertEqual(archive.canonical_archive(self.files), self.archive_bytes)

    def test_offline_verification_never_invokes_git(self):
        with patch.object(archive.subprocess, 'check_output', side_effect=AssertionError('Offline verification invoked Git')):
            manifest, files = archive.load_verified()
        self.assertEqual(manifest, self.manifest)
        self.assertEqual(files, self.files)

    def test_artifact_reads_reject_nonregular_files_without_blocking(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            fifo = root / 'fifo'
            os.mkfifo(fifo)
            regular = root / 'regular'
            regular.write_bytes(b'fixture')
            symlink = root / 'symlink'
            symlink.symlink_to(regular)
            for path in (fifo, root, symlink):
                with self.subTest(path=path), self.assertRaises((ValueError, OSError)):
                    archive.read_regular_file(path, 100)

    def test_generator_reproduces_archive_and_manifest_from_only_pinned_objects(self):
        proof = self.manifest['gitProof']
        objects = {item['id']: (item['type'], base64.b64decode(item['base64']))
                   for item in [proof['commit'], *proof['trees']]}
        tree_data = {identifier: archive.parse_tree(data) for identifier, (kind, data) in objects.items() if kind == 'tree'}
        root = base64.b64decode(proof['commit']['base64']).split(b'\n')[0][5:].decode('ascii')
        records = {record['path']: record for record in self.manifest['files']}
        blobs = {record['gitBlob']: self.files[record['path']] for record in records.values()}

        def git(_, *arguments):
            if arguments[:2] == ('cat-file', 'commit'):
                self.assertEqual(arguments[2], archive.BASELINE['commit'])
                return objects[arguments[2]][1]
            if arguments[:2] == ('cat-file', 'tree'):
                return objects[arguments[2]][1]
            if arguments[:2] == ('cat-file', 'blob'):
                return blobs[arguments[2]]
            if arguments[:2] == ('ls-tree', '-z'):
                self.assertEqual(arguments[2:4], (archive.BASELINE['commit'], '--'))
                record = records[arguments[4]]
                return f'100644 blob {record["gitBlob"]}\t{record["path"]}\0'.encode()
            if arguments[0] == 'rev-parse':
                value = arguments[1]
                self.assertTrue(value.startswith(archive.BASELINE['commit']))
                tree = root
                if not value.endswith('^{tree}'):
                    for part in value.split(':', 1)[1].split('/'):
                        mode, tree = tree_data[tree][part]
                        self.assertEqual(mode, '40000')
                return (tree + '\n').encode()
            self.fail(f'Unexpected Git operation: {arguments}')

        with patch.object(archive, '_git', side_effect=git):
            manifest, data = archive.generate(Path('/unused-source'))
        self.assertEqual(archive.canonical_manifest(manifest), self.manifest_bytes)
        self.assertEqual(data, self.archive_bytes)

    def test_manifest_rejects_unknown_fields_wrong_baseline_and_compilation_changes(self):
        mutations = [
            lambda value: value.update(extra=True),
            lambda value: value.update(schemaVersion=True),
            lambda value: value.update(schemaVersion=2),
            lambda value: value['baseline'].update(commit='0' * 40),
            lambda value: value['baseline'].update(marketingVersion='1.0.99'),
            lambda value: value['baseline'].update(buildVersion='148'),
            lambda value: value['baseline'].update(platform='ios'),
            lambda value: value['provenance'].update(confirmedOn='2026-10-25'),
            lambda value: value['swiftSources'].reverse(),
            lambda value: value['cSources'].append('outside.c'),
            lambda value: value['definitions'].append('ENABLE_MODULE_ECDH=1'),
            lambda value: value['archive'].update(file='../outside.tar.gz'),
            lambda value: value['archive'].update(bytes=True),
            lambda value: value['archive'].update(bytes=archive.MAX_ARCHIVE_BYTES + 1),
            lambda value: value['archive'].update(sha256='bad'),
        ]
        for index, mutate in enumerate(mutations):
            with self.subTest(index=index):
                value = copy.deepcopy(self.manifest)
                mutate(value)
                self.assert_invalid_manifest(value)

    def test_manifest_rejects_missing_duplicate_and_unsafe_file_entries(self):
        for path in ('../escape', '/absolute', './relative', 'dir//file', 'dir/../file', 'dir\\file', 'file\0x', 'unexpected.swift'):
            with self.subTest(path=path):
                value = copy.deepcopy(self.manifest)
                value['files'][0]['path'] = path
                self.assert_invalid_manifest(value)
        for kind in ('missing', 'duplicate', 'mode', 'size', 'unknown'):
            with self.subTest(kind=kind):
                value = copy.deepcopy(self.manifest)
                if kind == 'missing': value['files'].pop()
                if kind == 'duplicate': value['files'][1] = value['files'][0]
                if kind == 'mode': value['files'][0]['mode'] = '100755'
                if kind == 'size': value['files'][0]['bytes'] = archive.MAX_FILE_BYTES + 1
                if kind == 'unknown': value['files'][0]['extra'] = None
                self.assert_invalid_manifest(value)

    def test_manifest_parser_rejects_duplicates_invalid_utf8_and_nonfinite_numbers(self):
        for data in (b'{"files":[],"files":[]}', b'\xff', b'{"x":NaN}', b'{"x":Infinity}', b'{'):
            with self.subTest(data=data), self.assertRaises(ValueError):
                archive.parse_manifest(data)
        with self.assertRaises(ValueError):
            archive.parse_manifest(b' ' * (archive.MAX_MANIFEST_BYTES + 1))

    def test_git_proof_rejects_corrupt_and_unanchored_objects(self):
        for kind in ('commit', 'commit-id', 'tree', 'tree-id', 'missing', 'duplicate', 'unused', 'encoding', 'record-blob'):
            with self.subTest(kind=kind):
                value = copy.deepcopy(self.manifest)
                proof = value['gitProof']
                if kind == 'commit': proof['commit']['base64'] = base64.b64encode(b'changed commit').decode()
                if kind == 'commit-id': proof['commit']['id'] = '0' * 40
                if kind == 'tree': proof['trees'][0]['base64'] = base64.b64encode(b'changed tree').decode()
                if kind == 'tree-id': proof['trees'][0]['id'] = '0' * 40
                if kind == 'missing': proof['trees'].pop()
                if kind == 'duplicate': proof['trees'].append(proof['trees'][0])
                if kind == 'unused':
                    proof['trees'].append(archive._proof_object('tree', b''))
                    proof['trees'].sort(key=lambda item: item['id'])
                if kind == 'encoding': proof['commit']['base64'] += '\n'
                if kind == 'record-blob': value['files'][0]['gitBlob'] = value['files'][1]['gitBlob']
                self.assert_invalid_manifest(value)

    def test_source_change_cannot_be_hidden_by_updating_manifest_digests(self):
        files = dict(self.files)
        files['LICENSE'] += b'changed\n'
        data = archive.canonical_archive(files)
        for update_blob in (False, True):
            with self.subTest(update_blob=update_blob):
                value = copy.deepcopy(self.manifest)
                value['archive'].update(bytes=len(data), sha256=archive.sha256(data))
                record = next(item for item in value['files'] if item['path'] == 'LICENSE')
                record.update(bytes=len(files['LICENSE']), sha256=archive.sha256(files['LICENSE']))
                if update_blob: record['gitBlob'] = archive.git_id('blob', files['LICENSE'])
                with self.assertRaises(ValueError):
                    archive.verify(value, data)

    def test_tar_rejects_links_directories_traversal_duplicates_and_extra_metadata(self):
        def mutate(kind):
            def change(member, data):
                if kind == 'symlink': member.type = tarfile.SYMTYPE; member.linkname = '../escape'; member.size = 0
                elif kind == 'hardlink': member.type = tarfile.LNKTYPE; member.linkname = 'LICENSE'; member.size = 0
                elif kind == 'directory': member.type = tarfile.DIRTYPE; member.size = 0
                elif kind == 'device': member.type = tarfile.CHRTYPE; member.size = 0
                elif kind == 'absolute': member.name = '/escape'
                elif kind == 'traversal': member.name = '../escape'
                elif kind == 'duplicate': return [(member, data), (copy.copy(member), data)]
                elif kind == 'mode': member.mode = 0o755
                elif kind == 'mtime': member.mtime = 1
                elif kind == 'owner': member.uid = 501
                elif kind == 'pax': member.pax_headers = {'comment': 'untrusted'}
                return [(member, data if member.type == tarfile.REGTYPE else None)]
            return change
        for kind in ('symlink', 'hardlink', 'directory', 'device', 'absolute', 'traversal', 'duplicate', 'mode', 'mtime', 'owner', 'pax'):
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                archive.decode_archive(self.tar_variant(mutate(kind)))

    def test_gzip_rejects_corruption_truncation_concatenation_and_decompression_bombs(self):
        corrupt = bytearray(self.archive_bytes)
        corrupt[len(corrupt) // 2] ^= 1
        values = [bytes(corrupt), self.archive_bytes[:-1], self.archive_bytes + self.archive_bytes,
                  gzip.compress(b'\0' * (archive.MAX_TAR_BYTES + 1), mtime=0), b'x' * (archive.MAX_ARCHIVE_BYTES + 1)]
        for index, data in enumerate(values):
            with self.subTest(index=index), self.assertRaises(ValueError):
                archive.decode_archive(data)

    def test_extraction_uses_new_private_directory_and_exact_verified_bytes(self):
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary).resolve() / 'source'
            archive.extract_verified(self.files, target)
            self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o700)
            self.assertEqual({path.relative_to(target).as_posix() for path in target.rglob('*') if path.is_file()}, set(self.files))
            for path, data in self.files.items():
                self.assertEqual((target / path).read_bytes(), data)
                self.assertEqual(stat.S_IMODE((target / path).stat().st_mode), 0o644)

    def test_extraction_rejects_existing_paths_and_symlink_ancestors_without_overwrite(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            existing = root / 'existing'
            existing.mkdir()
            marker = existing / 'marker'
            marker.write_bytes(b'preserved')
            link = root / 'link'
            link.symlink_to(existing, target_is_directory=True)
            for target in (existing, marker, link, link / 'child', Path('relative-source'), root / '..' / 'escape'):
                with self.subTest(target=target), self.assertRaises((ValueError, OSError)):
                    archive.extract_verified(self.files, target)
            self.assertEqual(marker.read_bytes(), b'preserved')
            self.assertEqual(set(existing.iterdir()), {marker})

    def test_extraction_rejects_an_inserted_symlink_directory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            outside = root / 'outside'
            outside.mkdir()
            real_mkdir = archive.os.mkdir

            def mkdir(path, mode=0o777, *, dir_fd=None):
                if path == 'App macOS':
                    os.symlink(str(outside), path, dir_fd=dir_fd)
                    raise FileExistsError(path)
                return real_mkdir(path, mode, dir_fd=dir_fd)

            with patch.object(archive.os, 'mkdir', side_effect=mkdir), self.assertRaises(OSError):
                archive.extract_verified(self.files, root / 'source')
            self.assertEqual(list(outside.iterdir()), [])

    def test_cli_verifies_offline_and_validates_before_creating_destination(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            artifacts = root / archive.ARCHIVE_DIRECTORY
            artifacts.mkdir(parents=True)
            (artifacts / 'manifest.json').write_bytes(self.manifest_bytes)
            (artifacts / 'source.tar.gz').write_bytes(self.archive_bytes)
            output = io.StringIO()
            with contextlib.redirect_stdout(output), patch.object(archive.subprocess, 'check_output', side_effect=AssertionError('Git was invoked')):
                self.assertEqual(archive.main(['--verify', '--root', str(root), '--extract', str(root / 'source')]), 0)
            self.assertEqual(json.loads(output.getvalue())['files'], 95)
            (artifacts / 'source.tar.gz').write_bytes(b'corrupt')
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(archive.main(['--verify', '--root', str(root), '--extract', str(root / 'rejected')]), 1)
            self.assertFalse((root / 'rejected').exists())

    def test_cli_write_and_check_are_canonical_and_reject_symlink_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            with patch.object(archive, 'generate', return_value=(self.manifest, self.archive_bytes)), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(archive.main(['--write', '--root', str(root)]), 0)
                self.assertEqual(archive.main(['--check', '--root', str(root)]), 0)
                artifacts = root / archive.ARCHIVE_DIRECTORY
                (artifacts / 'manifest.json').write_bytes(b'changed')
                with contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(archive.main(['--check', '--root', str(root)]), 1)
                (artifacts / 'manifest.json').unlink()
                outside = root / 'outside'
                outside.write_bytes(b'preserved')
                (artifacts / 'manifest.json').symlink_to(outside)
                with contextlib.redirect_stderr(io.StringIO()):
                    self.assertEqual(archive.main(['--write', '--root', str(root)]), 1)
                self.assertEqual(outside.read_bytes(), b'preserved')


if __name__ == '__main__':
    unittest.main()
