"""Per-request wall deadline and cancellation, including trickling HTTP bodies.

Only sockets owned by this request are shut down. No interpreter-wide tracing,
asynchronous exception injection, global adapter mutation or TLS bypass.
"""
import socket
import threading
import time

import requests
from requests.adapters import HTTPAdapter
from urllib3.connection import HTTPConnection, HTTPSConnection
from urllib3.connectionpool import HTTPConnectionPool, HTTPSConnectionPool

_local = threading.local()
_lock = threading.Lock()
_active = {}
_cancelled = {}


class DeadlineExceeded(Exception):
    def __init__(self, code='STAGE_TIMEOUT'):
        self.code = code


def current():
    return getattr(_local, 'budget', None)


def check():
    if current() is not None:
        current().check()


def cancel_request(request_id, reason='STAGE_TIMEOUT'):
    if reason not in ('STAGE_TIMEOUT', 'NO_PROGRESS_TIMEOUT', 'JOB_PAUSED', 'WAITING_NETWORK'):
        reason = 'STAGE_TIMEOUT'
    with _lock:
        budget = _active.get(request_id)
        if budget is None:
            now = time.monotonic()
            for key in list(_cancelled):
                if _cancelled[key][1] < now:
                    del _cancelled[key]
            if len(_cancelled) >= 256:
                _cancelled.pop(next(iter(_cancelled)))
            _cancelled[request_id] = (reason, now + 300)
    if budget is not None:
        budget.cancel(reason)


class RequestBudget:
    def __init__(self, request_id, seconds):
        self.request_id = request_id
        self.deadline = time.monotonic() + seconds
        self.lock = threading.Lock()
        self.connections = []
        self.reason = ''
        self.timer = threading.Timer(seconds, self.cancel)
        self.timer.daemon = True

    def __enter__(self):
        self.previous = current()
        _local.budget = self
        with _lock:
            pending = _cancelled.pop(self.request_id, None)
            _active[self.request_id] = self
        if pending and pending[1] >= time.monotonic():
            self.cancel(pending[0])
        self.timer.start()
        return self

    def __exit__(self, *args):
        self.timer.cancel()
        with _lock:
            _active.pop(self.request_id, None)
        _local.budget = self.previous
        with self.lock:
            self.connections.clear()

    def check(self):
        if self.reason or time.monotonic() >= self.deadline:
            raise DeadlineExceeded(self.reason or 'STAGE_TIMEOUT')

    def remaining(self):
        self.check()
        return max(.01, self.deadline - time.monotonic())

    def track(self, connection, raw):
        with self.lock:
            self.connections.append((connection, raw))
        self.check()

    def cancel(self, reason='STAGE_TIMEOUT'):
        with self.lock:
            self.reason = self.reason or reason
            connections = list(self.connections)
        for connection, raw in connections:
            # HTTPS replaces the raw socket during TLS wrapping. Resolve the
            # current socket at cancellation time as well as the original one.
            for sock in (getattr(connection, 'sock', None), raw):
                if sock is not None:
                    try:
                        sock.shutdown(socket.SHUT_RDWR)
                    except OSError:
                        pass
                    try:
                        sock.close()
                    except OSError:
                        pass


class DeadlineAdapter(HTTPAdapter):
    def __init__(self, budget):
        self.budget = budget
        def classes(base, pool):
            class Connection(base):
                def _new_conn(conn):
                    budget.check()
                    raw = super()._new_conn()
                    try:
                        budget.track(conn, raw)
                    except Exception:
                        raw.close()
                        raise
                    return raw
            class Pool(pool):
                ConnectionCls = Connection
            return Pool
        self.classes = {'http': classes(HTTPConnection, HTTPConnectionPool),
                        'https': classes(HTTPSConnection, HTTPSConnectionPool)}
        super().__init__(max_retries=0)

    def init_poolmanager(self, *args, **kwargs):
        super().init_poolmanager(*args, **kwargs)
        self.poolmanager.pool_classes_by_scheme = self.classes

    def proxy_manager_for(self, *args, **kwargs):
        manager = super().proxy_manager_for(*args, **kwargs)
        manager.pool_classes_by_scheme = self.classes
        return manager


class DeadlineSession(requests.Session):
    def __init__(self, budget):
        super().__init__()
        self.budget = budget
        self.mount('https://', DeadlineAdapter(budget))
        self.mount('http://', DeadlineAdapter(budget))

    def request(self, *args, **kwargs):
        remaining = self.budget.remaining()
        supplied = kwargs.get('timeout') or remaining
        pair = supplied if isinstance(supplied, tuple) else (supplied, supplied)
        kwargs['timeout'] = tuple(min(remaining, value or remaining) for value in pair)
        try:
            result = super().request(*args, **kwargs)
        except Exception:
            self.budget.check()
            raise
        self.budget.check()
        return result
