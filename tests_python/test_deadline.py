"""Actual loopback I/O: deadlines must stop bytes trickling below read timeout."""
from pathlib import Path
import json
import shutil
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / 'Python'), str(ROOT / 'Vendor')]
from harbor_deadline import RequestBudget, DeadlineSession, DeadlineExceeded, cancel_request, current
import harbor_ios


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'
    def handle(self):
        try:
            super().handle()
        except OSError:
            pass  # Expected when the test client cancels a keep-alive socket.
    def log_message(self, *args):
        pass
    def do_GET(self):
        try:
            if self.path == '/headers':
                time.sleep(1)
            self.send_response(200)
            self.send_header('Content-Length', '200' if self.path == '/trickle' else '2')
            self.end_headers()
            if self.path == '/trickle':
                for _ in range(200):
                    self.wfile.write(b'x'); self.wfile.flush(); time.sleep(.02)
            else:
                self.wfile.write(b'ok')
        except (BrokenPipeError, ConnectionResetError, ssl.SSLError, OSError):
            pass


class DeadlineTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        cls.server.daemon_threads = True
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.url = 'http://127.0.0.1:' + str(cls.server.server_port)

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown(); cls.server.server_close(); cls.thread.join(timeout=2)

    def request(self, path, budget, proxy=False):
        with DeadlineSession(budget) as session:
            session.trust_env = False
            if proxy:
                session.proxies = {'http': self.url}
            return session.get(self.url + path, timeout=5)

    def test_header_stall_is_aborted_at_total_deadline(self):
        start = time.monotonic()
        with RequestBudget('headers', .2) as budget:
            with self.assertRaises(DeadlineExceeded):
                self.request('/headers', budget)
        self.assertLess(time.monotonic() - start, 1.5)

    def test_trickling_body_cannot_reset_total_deadline(self):
        start = time.monotonic()
        with RequestBudget('trickle', .25) as budget:
            with self.assertRaises(DeadlineExceeded):
                self.request('/trickle', budget)
        self.assertLess(time.monotonic() - start, 1.5)

    def test_cancellation_only_stops_its_own_request(self):
        with RequestBudget('cancel-one', 5) as first, RequestBudget('keep-other', 5) as second:
            timer = threading.Timer(.15, lambda: cancel_request('cancel-one', 'NO_PROGRESS_TIMEOUT'))
            timer.start()
            with self.assertRaises(DeadlineExceeded) as error:
                self.request('/trickle', first)
            timer.join()
            self.assertEqual(error.exception.code, 'NO_PROGRESS_TIMEOUT')
            self.assertEqual(self.request('/ok', second).content, b'ok')
        self.assertIsNone(current())

    def test_cancel_before_registration_and_adapter_isolation(self):
        cancel_request('early', 'JOB_PAUSED')
        with RequestBudget('early', 5) as budget:
            with self.assertRaises(DeadlineExceeded):
                budget.check()
        with RequestBudget('normal', 5) as budget:
            with DeadlineSession(budget) as session:
                self.assertTrue(session.verify)
                import requests
                with requests.Session() as plain:
                    self.assertNotEqual(type(session.adapters['http://']), type(plain.adapters['http://']))
            self.assertEqual(self.request('/ok', budget, proxy=True).content, b'ok')

    @unittest.skipUnless(shutil.which('openssl'), 'OpenSSL CLI needed only for a temporary loopback certificate')
    def test_https_wrapped_socket_obeys_same_deadline(self):
        with tempfile.TemporaryDirectory() as folder:
            key, cert = Path(folder)/'key.pem', Path(folder)/'cert.pem'
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '1',
                            '-keyout', str(key), '-out', str(cert), '-subj', '/CN=localhost',
                            '-addext', 'subjectAltName=IP:127.0.0.1'], capture_output=True, check=True)
            server = ThreadingHTTPServer(('127.0.0.1', 0), Handler); server.daemon_threads = True
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); context.load_cert_chain(cert, key)
            server.socket = context.wrap_socket(server.socket, server_side=True)
            thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
            try:
                start = time.monotonic()
                with RequestBudget('tls', .4) as budget, DeadlineSession(budget) as session:
                    session.trust_env = False; session.verify = str(cert)
                    with self.assertRaises(DeadlineExceeded):
                        session.get('https://127.0.0.1:' + str(server.server_port) + '/trickle', timeout=5)
                self.assertLess(time.monotonic() - start, 1.5)
            finally:
                server.shutdown(); server.server_close(); thread.join(timeout=2)

    def test_bridge_envelope_preserves_timeout_error_and_request_id(self):
        class Stub:
            api = None
            def dispatch(self, action, value):
                time.sleep(.05)
                return {}
        with patch.object(harbor_ios, '_service', Stub()):
            result = json.loads(harbor_ios.dispatch('probe', json.dumps({'request_id': 'budget-envelope', 'timeout_seconds': .02})))
        self.assertEqual(result['error'], 'STAGE_TIMEOUT')
        self.assertEqual(result['request_id'], 'budget-envelope')
        self.assertFalse(result['ok'])

    def test_suspended_process_gap_does_not_spend_deadline(self):
        budget = RequestBudget('suspension', 60)
        before = budget.deadline
        budget.observed_at -= 600
        budget.check()
        self.assertGreater(budget.deadline, before + 590)
