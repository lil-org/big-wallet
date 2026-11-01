import importlib.util
import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest


spec = importlib.util.spec_from_file_location('parser_fuzz_host', Path(__file__).resolve().parents[1] / 'host.py')
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)


class ParserFuzzReplayTests(unittest.TestCase):
    def test_stages_one_json_artifact_at_the_fixed_guest_path(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'reproducer.json'
            value = {'version': 1, 'case': {'mode': 'eip712', 'input': 'fixture'}}
            source.write_text(json.dumps(value))
            result = host.stage_parser_fuzz_replay(source, root / 'exchange')
            self.assertEqual(result, {'path': '/Volumes/BigWalletBuild/Exchange/inputs/parser-fuzz-replay.json',
                                      'sha256': hashlib.sha256(source.read_bytes()).hexdigest()})
            self.assertEqual(host.read_json(root / 'exchange/inputs/parser-fuzz-replay.json'), value)
            self.assertEqual(host.read_json(source), value)

    def test_rejects_invalid_oversized_and_redirected_replays(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'reproducer.json'
            for contents in ('[]', 'null', 'not json', ' ' * (16 * 1024 * 1024 + 1),
                             '{"nested":' + '[' * 2000 + '0' + ']' * 2000 + '}',
                             '{"number":' + '9' * 10000 + '}', '{"number":NaN}'):
                source.write_text(contents)
                with self.assertRaises(host.RunnerError):
                    host.stage_parser_fuzz_replay(source, root / 'exchange')
            source.write_text('{}')
            redirected = root / 'link.json'
            redirected.symlink_to(source)
            with self.assertRaises((host.RunnerError, OSError)):
                host.stage_parser_fuzz_replay(redirected, root / 'exchange')
            fifo = root / 'fifo.json'
            os.mkfifo(fifo)
            with self.assertRaises(host.RunnerError):
                host.stage_parser_fuzz_replay(fifo, root / 'exchange')

    def test_cli_exposes_mutation_and_parser_replay_without_launching(self):
        args = host.parser().parse_args(['run', 'extended', '--stage', 'mutation'])
        self.assertEqual(args.stage, ['mutation'])
        args = host.parser().parse_args(['run', 'all', '--stage', 'fuzz', '--parser-fuzz-replay', 'case.json'])
        self.assertEqual(args.parser_fuzz_replay, Path('case.json'))


if __name__ == '__main__':
    unittest.main()
