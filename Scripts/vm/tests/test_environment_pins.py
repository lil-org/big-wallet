import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import stat
import tempfile
import unittest
from unittest.mock import patch


spec = importlib.util.spec_from_file_location('environment_pins', Path(__file__).resolve().parents[1] / 'environment_pins.py')
pins = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pins)


class EnvironmentPinsTests(unittest.TestCase):
    def setUp(self):
        self.environment = json.loads((pins.ROOT / 'Scripts/vm/environment.json').read_text())

    def test_checked_in_header_matches_the_environment(self):
        self.assertEqual((pins.ROOT / pins.HEADER).read_bytes(), pins.render_safari_header(self.environment))

    def test_rendering_updated_framework_pins_preserves_the_environment(self):
        self.environment['safariSynchronization']['framework'].update(
            version='30000', imageUUID='12345678-1234-4123-8123-123456789ABC')
        original = copy.deepcopy(self.environment)
        rendered = pins.render_safari_header(self.environment)
        self.assertIn(b'#define BW_SAFARI_FRAMEWORK_VERSION @"30000"', rendered)
        self.assertIn(b'#define BW_SAFARI_FRAMEWORK_UUID @"12345678-1234-4123-8123-123456789ABC"', rendered)
        self.assertEqual(self.environment, original)
        detached = pins.validate_safari_framework(self.environment)
        detached['version'] = '40000'
        self.assertEqual(self.environment, original)

    def test_invalid_framework_pins_cannot_generate_objc_source(self):
        invalid_frameworks = [None, {}, {'unexpected': True}]
        for field, value in [('bundleIdentifier', 'com.apple.other'), ('version', 25229),
                             ('version', '25229\n'), ('version', '1"\n#error injected'),
                             ('imageUUID', 'unsupported'),
                             ('imageUUID', '8bf9e0bc-f620-35f8-9f7e-49542744f323')]:
            framework = dict(self.environment['safariSynchronization']['framework'])
            framework[field] = value
            invalid_frameworks.append(framework)
        invalid_frameworks.append({**self.environment['safariSynchronization']['framework'], 'extra': True})
        for framework in invalid_frameworks:
            with self.subTest(framework=framework):
                environment = {**self.environment, 'safariSynchronization': {'framework': framework}}
                with self.assertRaises(ValueError):
                    pins.render_safari_header(environment)
        for environment in [None, {}, {**self.environment, 'safariSynchronization': None},
                            {**self.environment, 'safariSynchronization': {'framework': {}, 'extra': True}}]:
            with self.subTest(environment=environment), self.assertRaises(ValueError):
                pins.render_safari_header(environment)

    def test_check_rejects_stale_or_missing_headers_without_writing(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = root / 'Scripts/vm/environment.json'
            environment.parent.mkdir(parents=True)
            environment.write_text(json.dumps(self.environment))
            header = root / pins.HEADER
            header.parent.mkdir(parents=True)
            for contents in [None, b'stale header\n']:
                with self.subTest(contents=contents):
                    if contents is not None:
                        header.write_bytes(contents)
                    errors = io.StringIO()
                    with contextlib.redirect_stderr(errors):
                        self.assertEqual(pins.main(['--check', '--root', str(root)]), 1)
                    self.assertTrue(errors.getvalue())
                    self.assertEqual(header.read_bytes() if header.exists() else None, contents)
            header.write_bytes(pins.render_safari_header(self.environment))
            self.assertEqual(pins.main(['--check', '--root', str(root)]), 0)

    def test_write_replaces_the_header_atomically_and_preserves_its_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'pins.h'
            path.write_bytes(b'previous header\n')
            path.chmod(0o640)
            expected = pins.render_safari_header(self.environment)
            with patch.object(pins.os, 'replace', side_effect=OSError('fixture replacement failure')):
                with self.assertRaises(OSError):
                    pins.write_safari_header(path, expected)
            self.assertEqual(path.read_bytes(), b'previous header\n')
            self.assertEqual(list(path.parent.iterdir()), [path])
            self.assertTrue(pins.write_safari_header(path, expected))
            self.assertEqual(path.read_bytes(), expected)
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o640)
            self.assertFalse(pins.write_safari_header(path, expected))
            path.unlink()
            self.assertTrue(pins.write_safari_header(path, expected))
            self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o644)
            path.unlink()
            other = path.with_name('other.h')
            other.write_bytes(b'other header')
            path.symlink_to(other)
            with self.assertRaises(ValueError):
                pins.write_safari_header(path, expected)
            self.assertEqual(other.read_bytes(), b'other header')


if __name__ == '__main__':
    unittest.main()
