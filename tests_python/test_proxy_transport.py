import json
import sys
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / 'Python'), str(ROOT / 'Vendor')]
import harbor_ios

class ProxyTransportTests(unittest.TestCase):
    def test_tls_verification_is_kept_with_loopback_proxy(self):
        api = object.__new__(harbor_ios.IOSApi)
        api.proxy = 'http://127.0.0.1:24500'
        session = api._new_session()
        self.assertTrue(session.verify)
        self.assertFalse(session.trust_env)
        self.assertEqual(session.proxies['https'], api.proxy)
        session.close()

    def test_bridge_rejects_nonlocal_proxy_and_out_of_range_port(self):
        fake = SimpleNamespace(api=None, dispatch=lambda action, value: {})
        with patch.object(harbor_ios, '_service', fake):
            for proxy in ['http://example.com:24500', 'http://127.0.0.1:9090', 'http://user:pass@127.0.0.1:24500', 42]:
                result = json.loads(harbor_ios.dispatch('probe', json.dumps({'proxy_url': proxy})))
                self.assertEqual(result['error'], 'INVALID_PROXY')

    def test_each_request_resets_the_previous_proxy(self):
        api = SimpleNamespace(proxy='old')
        fake = SimpleNamespace(api=api, dispatch=lambda action, value: {})
        with patch.object(harbor_ios, '_service', fake):
            harbor_ios.dispatch('probe', json.dumps({'proxy_url': 'http://127.0.0.1:24501'}))
            self.assertEqual(api.proxy, 'http://127.0.0.1:24501')
            harbor_ios.dispatch('probe', '{}')
            self.assertEqual(api.proxy, '')

if __name__ == '__main__': unittest.main()
