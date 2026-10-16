import contextlib
import ctypes
import importlib.util
import os
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch


spec = importlib.util.spec_from_file_location('capacity_host', Path(__file__).resolve().parents[1] / 'host.py')
host = importlib.util.module_from_spec(spec)
spec.loader.exec_module(host)
GIB = 1024 ** 3


class HostCapacityTests(unittest.TestCase):
    def setUp(self):
        patches = contextlib.ExitStack()
        self.addCleanup(patches.close)
        self.state = Path('/fixture/VM state')
        self.usage = SimpleNamespace(total=500 * GIB, used=487 * GIB, free=13 * GIB)
        self.disk = patches.enter_context(patch.object(host.shutil, 'disk_usage', return_value=self.usage))
        self.capacity = patches.enter_context(patch.object(host, 'macos_available_capacity', return_value=117 * GIB))

    def test_reclaimable_capacity_satisfies_reserve_and_preserves_raw_free_diagnostic(self):
        self.assertEqual(host.check_capacity(self.state, 30 * GIB), {
            'availableBytes': 117 * GIB, 'freeBytes': 13 * GIB, 'capacitySource': 'macOSImportantUsage',
        })
        self.disk.assert_called_once_with(self.state)
        self.capacity.assert_called_once_with(self.state)

    def test_available_capacity_below_reserve_blocks_even_when_raw_free_is_larger(self):
        self.usage.free = 60 * GIB
        self.capacity.return_value = 29 * GIB
        with self.assertRaisesRegex(host.RunnerError, r'29\.0 GiB available .*60\.0 GiB currently free.*30\.0 GiB reserve'):
            host.check_capacity(self.state, 30 * GIB)

    def test_zero_available_capacity_is_valid_and_blocks(self):
        self.usage.free = 60 * GIB
        self.capacity.return_value = 0
        with self.assertRaisesRegex(host.RunnerError, r'0\.0 GiB available'):
            host.check_capacity(self.state, 30 * GIB)

    def test_exact_reserve_is_sufficient(self):
        self.capacity.return_value = 30 * GIB
        self.assertEqual(host.check_capacity(self.state, 30 * GIB)['availableBytes'], 30 * GIB)

    def test_unavailable_or_invalid_estimate_falls_back_to_sufficient_raw_free(self):
        self.usage.free = 31 * GIB
        for estimate in (None, True, False, -1, 117.0 * GIB, 501 * GIB, '117'):
            with self.subTest(estimate=estimate):
                self.capacity.return_value = estimate
                self.assertEqual(host.check_capacity(self.state, 30 * GIB), {
                    'availableBytes': 31 * GIB, 'freeBytes': 31 * GIB, 'capacitySource': 'filesystemFree',
                })

    def test_unavailable_or_invalid_estimate_cannot_bypass_raw_free_reserve(self):
        self.usage.free = 29 * GIB
        for estimate in (None, True, False, -1, 117.0 * GIB, 501 * GIB, '117'):
            with self.subTest(estimate=estimate):
                self.capacity.return_value = estimate
                with self.assertRaisesRegex(host.RunnerError, r'29\.0 GiB available'):
                    host.check_capacity(self.state, 30 * GIB)

    def test_each_check_uses_current_capacity(self):
        self.capacity.side_effect = [117 * GIB, 29 * GIB]
        self.assertEqual(host.check_capacity(self.state, 30 * GIB)['availableBytes'], 117 * GIB)
        with self.assertRaises(host.RunnerError):
            host.check_capacity(self.state, 30 * GIB)
        self.assertEqual(self.capacity.call_count, 2)


class FakeCoreFoundation:
    def __init__(self):
        self.capacity = 117 * GIB
        self.create_success = True
        self.query_success = True
        self.value = 200
        self.error = None
        self.type_id = 22
        self.conversion_success = True
        self.created = []
        self.queries = []
        self.released = []
        self.conversions = []

    def CFURLCreateFromFileSystemRepresentation(self, allocator, encoded, length, directory):
        url = 100 + len(self.created) if self.create_success else None
        self.created.append((url, allocator, encoded, length, directory))
        return url

    def CFURLCopyResourcePropertyForKey(self, url, key, value, error):
        self.queries.append((url, key))
        ctypes.cast(value, ctypes.POINTER(ctypes.c_void_p))[0] = self.value
        ctypes.cast(error, ctypes.POINTER(ctypes.c_void_p))[0] = self.error
        return self.query_success

    def CFGetTypeID(self, value):
        return self.type_id

    def CFNumberGetTypeID(self):
        return 22

    def CFNumberGetValue(self, value, kind, output):
        self.conversions.append((value.value, kind))
        ctypes.cast(output, ctypes.POINTER(ctypes.c_int64))[0] = self.capacity
        return self.conversion_success

    def CFRelease(self, value):
        self.released.append(value.value if isinstance(value, ctypes.c_void_p) else value)


class MacOSCapacityBridgeTests(unittest.TestCase):
    def setUp(self):
        patches = contextlib.ExitStack()
        self.addCleanup(patches.close)
        self.core = FakeCoreFoundation()
        self.key = ctypes.c_void_p(300)
        patches.enter_context(patch.object(host.sys, 'platform', 'darwin'))
        self.api = patches.enter_context(patch.object(host, 'macos_capacity_api', return_value=(self.core, object(), self.key)))
        self.path = Path('/fixture/VM state')

    def test_each_query_uses_a_fresh_url_and_releases_copied_resources(self):
        self.assertEqual(host.macos_available_capacity(self.path), 117 * GIB)
        self.core.capacity = 29 * GIB
        self.assertEqual(host.macos_available_capacity(self.path), 29 * GIB)
        encoded = os.fsencode(self.path)
        self.assertEqual(self.core.created, [
            (100, None, encoded, len(encoded), True),
            (101, None, encoded, len(encoded), True),
        ])
        self.assertEqual(self.core.queries, [(100, self.key), (101, self.key)])
        self.assertCountEqual(self.core.released, [100, 101, 200, 200])
        self.assertEqual(self.core.conversions, [(200, 4), (200, 4)])

    def test_zero_capacity_is_returned(self):
        self.core.capacity = 0
        self.assertEqual(host.macos_available_capacity(self.path), 0)
        self.assertCountEqual(self.core.released, [100, 200])

    def test_url_creation_failure_returns_unavailable_without_query_or_release(self):
        self.core.create_success = False
        self.assertIsNone(host.macos_available_capacity(self.path))
        self.assertEqual(self.core.queries, [])
        self.assertEqual(self.core.released, [])

    def test_query_failure_releases_url_value_and_error(self):
        self.core.query_success = False
        self.core.error = 400
        self.assertIsNone(host.macos_available_capacity(self.path))
        self.assertCountEqual(self.core.released, [100, 200, 400])
        self.assertEqual(self.core.conversions, [])

    def test_query_failure_with_no_output_values_releases_only_url(self):
        self.core.query_success = False
        self.core.value = None
        self.assertIsNone(host.macos_available_capacity(self.path))
        self.assertEqual(self.core.released, [100])

    def test_missing_resource_value_returns_unavailable_and_releases_url(self):
        self.core.value = None
        self.assertIsNone(host.macos_available_capacity(self.path))
        self.assertEqual(self.core.released, [100])
        self.assertEqual(self.core.conversions, [])

    def test_wrong_resource_type_is_not_converted_and_is_released(self):
        self.core.type_id = 7
        self.assertIsNone(host.macos_available_capacity(self.path))
        self.assertCountEqual(self.core.released, [100, 200])
        self.assertEqual(self.core.conversions, [])

    def test_negative_capacity_is_unavailable_and_resources_are_released(self):
        self.core.capacity = -1
        self.assertIsNone(host.macos_available_capacity(self.path))
        self.assertCountEqual(self.core.released, [100, 200])

    def test_failed_number_conversion_rejects_partial_output_and_releases_resources(self):
        self.core.conversion_success = False
        self.assertIsNone(host.macos_available_capacity(self.path))
        self.assertCountEqual(self.core.released, [100, 200])

    def test_missing_library_symbol_or_constant_returns_unavailable(self):
        for failure in (OSError('missing framework'), AttributeError('missing function'), ValueError('missing constant')):
            with self.subTest(failure=type(failure)):
                self.api.side_effect = failure
                self.assertIsNone(host.macos_available_capacity(self.path))
        self.assertEqual(self.core.created, [])

    def test_other_platforms_do_not_load_macos_frameworks(self):
        with patch.object(host.sys, 'platform', 'linux'):
            self.assertIsNone(host.macos_available_capacity(self.path))
        self.api.assert_not_called()


class MacOSCapacityBindingTests(unittest.TestCase):
    def test_framework_bindings_are_cached_without_caching_capacity(self):
        class Pointer(ctypes.c_void_p):
            in_dll = Mock(return_value=ctypes.c_void_p(300))

        core, foundation = Mock(), object()
        host.macos_capacity_api.cache_clear()
        self.addCleanup(host.macos_capacity_api.cache_clear)
        with patch.object(host.ctypes, 'CDLL', side_effect=[core, foundation]) as load, \
                patch.object(host.ctypes, 'c_void_p', Pointer):
            first = host.macos_capacity_api()
            second = host.macos_capacity_api()
        self.assertIs(first, second)
        self.assertEqual(load.call_count, 2)
        self.assertEqual(first[:2], (core, foundation))
        Pointer.in_dll.assert_called_once_with(foundation, 'NSURLVolumeAvailableCapacityForImportantUsageKey')


if __name__ == '__main__':
    unittest.main()
