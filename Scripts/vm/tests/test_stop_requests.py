import fcntl
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest


host_path = Path(__file__).resolve().parents[1] / 'host.py'
spec = importlib.util.spec_from_file_location('stop_requests_host', host_path)
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)


class StopRequestTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.exchange = host.private_directory(Path(temporary.name).resolve() / 'exchange')
        self.run_id = 'fixture-run'

    def record(self):
        return host.operation_stop_record(self.exchange, self.run_id)

    def test_explicit_requests_saturate_and_internal_publication_preserves_them(self):
        self.assertIsNone(self.record())
        self.assertFalse(host.operation_stop_requested(self.exchange, self.run_id))
        host.publish_stop(self.exchange, self.run_id)
        self.assertEqual(self.record(), {'version': 1, 'runId': self.run_id, 'requestCount': 0})
        self.assertTrue(host.operation_stop_requested(self.exchange, self.run_id))
        for expected in (1, 2, 2):
            host.publish_stop(self.exchange, self.run_id, requested=True)
            self.assertEqual(self.record()['requestCount'], expected)
            host.publish_stop(self.exchange, self.run_id)
            self.assertEqual(self.record()['requestCount'], expected)

    def test_another_run_record_does_not_request_cancellation(self):
        host.publish_stop(self.exchange, 'another-run', requested=True)
        self.assertIsNone(self.record())
        self.assertFalse(host.operation_stop_requested(self.exchange, self.run_id))
        for requested in (False, True):
            with self.assertRaises(host.RunnerError):
                host.publish_stop(self.exchange, self.run_id, requested=requested)
        self.assertEqual(host.operation_stop_record(self.exchange, 'another-run')['requestCount'], 1)

    def test_stop_records_require_the_current_bounded_schema(self):
        valid = {'version': 1, 'runId': self.run_id, 'requestCount': 1}
        values = [
            [], {}, {'version': 1, 'runId': self.run_id},
            {**valid, 'version': True}, {**valid, 'version': 2},
            {**valid, 'runId': 1}, {**valid, 'extra': True},
            *({**valid, 'requestCount': count} for count in (-1, 3, True, 1.0, '1', None)),
        ]
        for value in values:
            with self.subTest(value=value):
                host.atomic_json(self.exchange / 'stop.json', value)
                with self.assertRaises(host.RunnerError):
                    self.record()

    def test_concurrent_cli_requests_and_internal_publication_share_one_lock(self):
        script = '''
import importlib.util
from pathlib import Path
import sys
spec = importlib.util.spec_from_file_location('stop_request_worker', sys.argv[1])
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)
Path(sys.argv[5]).touch()
host.publish_stop(Path(sys.argv[2]), sys.argv[3], requested=sys.argv[4] == 'true')
'''
        host.publish_stop(self.exchange, self.run_id)
        lock_path = self.exchange / 'stop.lock'
        identity = lock_path.stat().st_ino
        descriptor = os.open(lock_path, os.O_RDWR | os.O_NOFOLLOW)
        children = []
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
            for index, requested in enumerate(('true', 'false', 'true')):
                ready = self.exchange / f'ready-{index}'
                child = subprocess.Popen([sys.executable, '-c', script, str(host_path), str(self.exchange),
                    self.run_id, requested, str(ready)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                children.append((child, ready))
            deadline = time.monotonic() + 10
            while not all(ready.exists() for _, ready in children):
                self.assertLess(time.monotonic(), deadline, 'Stop publishers did not reach the lock')
                time.sleep(0.01)
            for child, _ in children:
                with self.assertRaises(subprocess.TimeoutExpired):
                    child.wait(timeout=0.05)
            self.assertEqual(self.record()['requestCount'], 0)
            fcntl.flock(descriptor, fcntl.LOCK_UN)
            for child, _ in children:
                stdout, stderr = child.communicate(timeout=10)
                self.assertEqual(child.returncode, 0, (stdout, stderr))
            self.assertEqual(self.record()['requestCount'], 2)
            self.assertEqual(lock_path.stat().st_ino, identity)
            host.publish_stop(self.exchange, self.run_id)
            self.assertEqual(self.record()['requestCount'], 2)
        finally:
            os.close(descriptor)
            for child, _ in children:
                if child.poll() is None:
                    child.terminate()
                child.communicate(timeout=10)


if __name__ == '__main__':
    unittest.main()
