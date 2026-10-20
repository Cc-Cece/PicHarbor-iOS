"""iOS boundary around the pinned gpmc snapshot; no cloud/local delete operations.

Only the caller's Keychain owns reusable credentials. SQLite stores account-scoped
observations, never tokens. A hash lookup confirms content existence, not cleanup
eligibility or original quality. Legacy database work is exclusive; protocol calls use isolated request contexts.
"""
import base64
import copy
import threading
from types import SimpleNamespace
import hashlib
import json
import logging
import os
import re
from pathlib import Path
import sqlite3
import time
import uuid
from urllib.parse import parse_qs

import requests
from gpmc.api import Api
from gpmc.auth import authenticate
from gpmc.exceptions import AuthenticationError, BrowserAuthenticationRequiredError


class Failure(Exception):
    pass


class IOSApi(Api):
    def _new_session(self):
        # No inherited proxy/TLS override or hidden retry multiplication.
        session = requests.Session()
        session.verify = True
        session.trust_env = False
        if self.proxy:
            session.proxies.update({"http": self.proxy, "https": self.proxy})
        return session


def classify(error):
    if isinstance(error, Failure):
        return str(error)
    if isinstance(error, (AuthenticationError, BrowserAuthenticationRequiredError)):
        return "LOGIN_REQUIRED"
    if isinstance(error, requests.HTTPError):
        code = error.response.status_code if error.response is not None else 0
        return "LOGIN_REQUIRED" if code in (401, 403) else "NETWORK_ERROR"
    if isinstance(error, requests.RequestException):
        return "NETWORK_ERROR"
    if isinstance(error, OSError):
        return "FILE_ACCESS"
    # Never expose exception text, HTTP URLs, response bodies or tracebacks.
    return "ENGINE_ERROR"


class Reader:
    def __init__(self, stream, size, emit):
        self.stream, self.len, self.emit = stream, size, emit

    def read(self, size=-1):
        result = self.stream.read(size)
        self.emit("uploading", self.stream.tell(), self.len)
        return result

    def tell(self):
        return self.stream.tell()

    def seek(self, *args):
        return self.stream.seek(*args)


class Service:
    def __init__(self, home, api_factory=IOSApi, notify=None):
        self.home = Path(home).resolve()
        self.home.mkdir(parents=True, exist_ok=True)
        self.staging = self.home / "Staging"
        self.staging.mkdir(exist_ok=True)
        self.identity_condition = threading.Condition(threading.RLock())
        self.active_protocol_calls = 0
        self.changing_identity = False
        self.protocol_pool = {}
        self.identity_generation = 0
        self.api_factory, self.notify = api_factory, notify
        self.last_event = ("", 0.0)
        self.api, self.account = None, ""
        self.db = sqlite3.connect(self.home / "observations.sqlite", check_same_thread=False)
        self.db.row_factory = sqlite3.Row
        self.db.execute("""CREATE TABLE IF NOT EXISTS records (
            id TEXT PRIMARY KEY, account TEXT NOT NULL, name TEXT NOT NULL,
            sha1 TEXT NOT NULL, sha256 TEXT NOT NULL, size INTEGER NOT NULL,
            remote_key TEXT NOT NULL, state TEXT NOT NULL, origin TEXT NOT NULL,
            error TEXT NOT NULL, updated INTEGER NOT NULL)""")
        self.db.execute("UPDATE records SET state='interrupted',error='INTERRUPTED' WHERE state='uploading'")
        self.db.commit()
        logging.disable(logging.CRITICAL)

    def control_dispatch(self, action, value):
        # Login/logout and the legacy observations database form an exclusive
        # barrier. An in-flight request never changes its account or proxy.
        with self.identity_condition:
            while self.changing_identity:
                self.identity_condition.wait()
            self.changing_identity = True
            try:
                while self.active_protocol_calls:
                    self.identity_condition.wait()
                if self.api is not None:
                    self.api.proxy = value.get("proxy_url", "")
                result = self.dispatch(action, value)
                if action in ("connect", "logout"):
                    self.identity_generation += 1
                    self.protocol_pool.clear()
                return result
            finally:
                self.changing_identity = False
                self.identity_condition.notify_all()

    def protocol_dispatch(self, action, value):
        from harbor_protocol import Protocol
        with self.identity_condition:
            while self.changing_identity:
                self.identity_condition.wait()
            if self.api is None:
                raise Failure("LOGIN_REQUIRED")
            if value.get("account") != self.account:
                raise Failure("ACCOUNT_CHANGED")
            request_api = copy.copy(self.api)
            request_api.proxy = value.get("proxy_url", "")
            if hasattr(request_api, "auth_response_cache"):
                request_api.auth_response_cache = dict(self.api.auth_response_cache)
                # Serialize bearer renewal only, not the media protocol request.
                _ = request_api.bearer_token
                self.api.auth_response_cache = dict(request_api.auth_response_cache)
            generation = self.identity_generation
            identity = (generation, self.account, request_api.proxy)
            pool = self.protocol_pool.get(identity, [])
            context = pool.pop() if pool else Protocol(SimpleNamespace(api=request_api, staging=self.staging))
            context.service.api = request_api
            self.active_protocol_calls += 1
        try:
            return context.dispatch(action, value)
        finally:
            with self.identity_condition:
                pool = self.protocol_pool.setdefault(identity, [])
                if len(pool) < 32:
                    pool.append(context)
                self.active_protocol_calls -= 1
                self.identity_condition.notify_all()

    def emit(self, phase, completed=0, total=0):
        previous, emitted = self.last_event
        now = time.monotonic()
        if phase == previous and now - emitted < 0.15 and completed != total:
            return
        self.last_event = (phase, now)
        if self.notify:
            self.notify(json.dumps({"phase": phase, "completed": completed, "total": total}))

    def connect(self, value):
        # Clear old identity even when the new connection fails.
        self.api, self.account = None, ""
        self.protocol = None
        credential = value["credential"].strip()
        if not credential or len(credential) > 16384 or any(c in credential for c in "\r\n"):
            raise Failure("INVALID_CREDENTIAL")
        if "androidId=" not in credential:
            credential = authenticate(credential, proxy=value.get("proxy_url", ""), timeout=60)
        fields = parse_qs(credential)
        account = fields.get("Email", [""])[0].strip().lower()
        if "@" not in account or any(c.isspace() for c in account):
            raise Failure("INVALID_CREDENTIAL")
        api = self.api_factory(credential, timeout=60)
        api.proxy = value.get("proxy_url", "")
        _ = api.bearer_token
        self.api, self.account = api, account
        from harbor_protocol import Protocol
        self.protocol = Protocol(self)
        return {"account": account, "credential": credential}

    def records(self):
        return [dict(row) for row in self.db.execute(
            "SELECT * FROM records WHERE account=? ORDER BY updated DESC, rowid DESC LIMIT 100", (self.account,))]

    def save(self, record, **changes):
        record.update(changes, updated=int(time.time()))
        columns = list(record)
        with self.db:
            self.db.execute(f"INSERT OR REPLACE INTO records ({','.join(columns)}) VALUES ({','.join('?' for _ in columns)})",
                            [record[key] for key in columns])

    def path(self, value):
        path = Path(value).resolve()
        if not path.is_relative_to(self.staging) or not path.is_file():
            raise Failure("FILE_ACCESS")
        return path

    def hashes(self, path):
        sha1, sha256 = hashlib.sha1(), hashlib.sha256()
        before = path.stat()
        size = 0
        with path.open("rb") as stream:
            for block in iter(lambda: stream.read(1024 * 1024), b""):
                size += len(block)
                sha1.update(block)
                sha256.update(block)
                self.emit("hashing", size, before.st_size)
        after = path.stat()
        if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns) or size != before.st_size:
            raise Failure("SOURCE_CHANGED")
        return {"sha1": sha1.hexdigest(), "sha256": sha256.hexdigest(), "size": size}

    def confirm(self, record):
        self.emit("confirming")
        try:
            key = self.api.find_remote_media_by_hash(bytes.fromhex(record["sha1"]))
            if key:
                self.save(record, remote_key=key, state="confirmed", error="")
            else:
                self.save(record, state="confirmation_pending", error="REMOTE_NOT_VISIBLE")
        except Exception as error:
            self.save(record, state="confirmation_pending", error=classify(error))
        return record

    def upload(self, value):
        quality = value.get("quality", "original")
        if quality not in ("quota", "original", "saver"):
            raise Failure("INVALID_QUALITY")
        path = self.path(value["path"])
        digest = self.hashes(path)
        if digest["size"] == 0:
            raise Failure("EMPTY_FILE")
        record = {"id": str(uuid.uuid4()), "account": self.account,
                  "name": Path(value["name"]).name, **digest, "remote_key": "",
                  "state": "uploading", "origin": "", "error": "", "updated": 0}
        self.save(record)
        try:
            self.emit("checking")
            remote = self.api.find_remote_media_by_hash(bytes.fromhex(digest["sha1"]))
            if remote:
                self.save(record, remote_key=remote, state="confirmed", origin="content_exists")
                return record
            token = self.api.get_upload_token(base64.b64encode(bytes.fromhex(digest["sha1"])).decode(), digest["size"])
            with path.open("rb") as stream:
                response = self.api.upload_file(Reader(stream, digest["size"], self.emit), token)
            if self.hashes(path) != digest:
                raise Failure("SOURCE_CHANGED")
            self.emit("committing")
            remote = self.api.commit_upload(response, record["name"], bytes.fromhex(digest["sha1"]),
                quality="saver" if quality == "saver" else "original",
                model={"quota": "Pixel 8", "original": "Pixel XL", "saver": "Pixel 2"}[quality])
            if not isinstance(remote, str) or not remote:
                raise Failure("COMMIT_UNCONFIRMED")
            # A submitted key is not yet an independent cloud observation.
            self.save(record, remote_key=remote, state="confirmation_pending", origin="uploaded")
        except Exception as error:
            self.save(record, state="failed", error=classify(error))
            return record
        return self.confirm(record)

    def dispatch(self, action, value):
        from harbor_protocol import Protocol
        if action == "capabilities":
            return Protocol.capabilities()
        if action == "probe":
            import ssl
            import sys
            import blackboxprotobuf
            # Exercise native extensions as well as pure Python imports offline.
            assert blackboxprotobuf.decode_message(blackboxprotobuf.encode_message({"1": 7}, {"1": {"type": "int"}}))[0]["1"] == 7
            return {"python": sys.version.split()[0], "tls": ssl.OPENSSL_VERSION,
                    "sqlite": sqlite3.sqlite_version, "gpmc_imported": True}
        if action == "logout":
            self.api, self.account = None, ""
            return {}
        if action == "connect":
            return self.connect(value)
        if self.api is None:
            raise Failure("LOGIN_REQUIRED")
        if value.get("account") != self.account:
            raise Failure("ACCOUNT_CHANGED")
        if action in Protocol.actions:
            return self.protocol.dispatch(action, value)
        if action == "records":
            return {"records": self.records()}
        if action == "upload":
            return {"record": self.upload(value)}
        if action == "verify":
            row = self.db.execute("SELECT * FROM records WHERE id=? AND account=?", (value["id"], self.account)).fetchone()
            if not row:
                raise Failure("RECORD_MISSING")
            return {"record": self.confirm(dict(row))}
        raise Failure("UNKNOWN_OPERATION")


_service = None


def initialize(home):
    global _service
    try:
        from _harbor_native import event
    except ImportError:
        event = None
    _service = Service(home, notify=event)


def dispatch(action, payload):
    request_id = ""
    try:
        value = json.loads(payload)
        request_id = value.get("request_id", "")
        if value.get("protocol_version", 2) != 2:
            raise Failure("PROTOCOL_VERSION")
        proxy = value.get("proxy_url", "")
        if proxy:
            match = re.fullmatch(r"http://127\.0\.0\.1:([0-9]{1,5})", proxy) if isinstance(proxy, str) else None
            if not match or not 24500 <= int(match[1]) < 24564:
                raise Failure("INVALID_PROXY")
        from harbor_protocol import Protocol
        if isinstance(_service, Service):
            result = _service.protocol_dispatch(action, value) if action in Protocol.actions else _service.control_dispatch(action, value)
        else:
            # Test doubles and older embedders retain the legacy boundary.
            if _service.api is not None:
                _service.api.proxy = proxy
            result = _service.dispatch(action, value)
        return json.dumps({"ok": True, "protocol_version": 2, "request_id": request_id, **result})
    except Exception as error:
        code = classify(error)
        return json.dumps({"ok": False, "protocol_version": 2, "request_id": request_id, "error": code,
                           "failure": {"code": code, "retryable": code == "NETWORK_ERROR"}})
