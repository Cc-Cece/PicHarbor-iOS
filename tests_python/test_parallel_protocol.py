"""Real Service concurrency boundaries, offline with no account credentials."""
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from concurrent.futures import ThreadPoolExecutor
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / 'Python'), str(ROOT / 'Vendor')]
from harbor_ios import Service, Failure
from harbor_protocol import Protocol


class ParallelProtocolTests(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.TemporaryDirectory()
        self.service = Service(self.home.name)
        self.service.api = SimpleNamespace(proxy='base')
        self.service.account = 'test@example.invalid'

    def tearDown(self):
        self.service.db.close()
        self.home.cleanup()

    def test_requests_overlap_and_keep_distinct_proxy_and_cache(self):
        barrier = threading.Barrier(2)
        def invoke(context, action, value):
            proxy = context.service.api.proxy
            barrier.wait(timeout=3)
            self.assertEqual(context.service.api.proxy, proxy)
            return proxy, id(context)
        with patch.object(Protocol, 'dispatch', invoke), ThreadPoolExecutor(2) as pool:
            futures = [pool.submit(self.service.protocol_dispatch, 'confirm_resource',
                                  {'account': self.service.account, 'proxy_url': str(i)}) for i in range(2)]
            results = [value.result(timeout=4) for value in futures]
        self.assertEqual({result[0] for result in results}, {'0', '1'})
        self.assertNotEqual(results[0][1], results[1][1])
        self.assertEqual(self.service.api.proxy, 'base')
        self.assertEqual(self.service.active_protocol_calls, 0)

    def test_cache_reused_across_native_thread_lifetimes_and_errors_release_lease(self):
        def invoke(context, action, value):
            context.snapshot['cached'] = True
            return id(context)
        with patch.object(Protocol, 'dispatch', invoke):
            with ThreadPoolExecutor(1) as pool:
                first = pool.submit(self.service.protocol_dispatch, 'confirm_resource', {'account': self.service.account}).result()
            with ThreadPoolExecutor(1) as pool:
                second = pool.submit(self.service.protocol_dispatch, 'confirm_resource', {'account': self.service.account}).result()
        self.assertEqual(first, second)
        with patch.object(Protocol, 'dispatch', side_effect=Failure('NETWORK_ERROR')):
            with self.assertRaises(Failure):
                self.service.protocol_dispatch('confirm_resource', {'account': self.service.account})
        self.assertEqual(self.service.active_protocol_calls, 0)

    def test_logout_waits_for_inflight_calls_and_rejects_old_account(self):
        entered, release = threading.Event(), threading.Event()
        def invoke(context, action, value):
            entered.set(); self.assertTrue(release.wait(3))
            self.assertEqual(self.service.account, 'test@example.invalid')
            return {}
        with patch.object(Protocol, 'dispatch', invoke), ThreadPoolExecutor(2) as pool:
            active = pool.submit(self.service.protocol_dispatch, 'confirm_resource', {'account': self.service.account})
            self.assertTrue(entered.wait(2))
            logout = pool.submit(self.service.control_dispatch, 'logout', {})
            time.sleep(.03); self.assertFalse(logout.done())
            release.set(); active.result(timeout=3); logout.result(timeout=3)
        self.assertEqual(self.service.account, '')
        self.assertEqual(self.service.protocol_pool, {})
        with self.assertRaisesRegex(Failure, 'LOGIN_REQUIRED'):
            self.service.protocol_dispatch('confirm_resource', {'account': 'test@example.invalid'})
