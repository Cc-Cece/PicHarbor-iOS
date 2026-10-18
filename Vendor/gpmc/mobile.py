"""PicHarbor mobile integration. The existing auth and wire payloads remain in Api.

Content evidence is distinct from filename skips and optimistic local caches.
This module never deletes either local or remote media.
"""
from contextlib import closing, contextmanager
import hashlib
import json
import os
import re
import sqlite3
import threading
import time
import uuid
from pathlib import Path
from urllib.parse import urlparse

import requests
from .api import Api
from .client import Client
from .db_update_parser import parse_db_update
from .utils import parse_email


class Cancelled(Exception):
    pass


def known_integer(value):
    return value if isinstance(value,int) and not isinstance(value,bool) and value >= 0 else None


def error_code(error):
    value = str(error)
    for marker, code in (
        ("encrypted auth token", "ENCRYPTED_TOKEN"), ("TokenEncrypted", "ENCRYPTED_TOKEN"),
        ("MissingDroidguard", "DEVICE_VERIFICATION"), ("device verification", "DEVICE_VERIFICATION"),
        ("NeedsBrowser", "LOGIN_REQUIRED"), ("browser sign-in", "LOGIN_REQUIRED"),
        ("fresh browser sign-in", "LOGIN_REQUIRED"), ("BadAuthentication", "LOGIN_REQUIRED"),
        ("rejected the credential", "LOGIN_REQUIRED"),
    ):
        if marker in value:
            return code
    if isinstance(error, Cancelled):
        return "CANCELLED"
    if isinstance(error, requests.exceptions.HTTPError):
        status = error.response.status_code if error.response is not None else 0
        return "LOGIN_REQUIRED" if status in (401, 403) else ("RATE_LIMITED" if status == 429 else "NETWORK_ERROR")
    if isinstance(error, requests.exceptions.RequestException):
        return "NETWORK_ERROR"
    if isinstance(error, (OSError, PermissionError)) or "SecurityException" in type(error).__name__:
        return "FILE_ACCESS"
    return "ENGINE_ERROR"


class MobileApi(Api):
    """Transport constraints only: reuse Api's authentication and protobuf logic."""
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.auth_lock = threading.RLock()

    @property
    def bearer_token(self):
        with self.auth_lock:
            return super().bearer_token

    def _new_session(self):
        # Retry is controlled per item below, rather than multiplying urllib3 retries.
        session = requests.Session()
        session.verify = True
        if self.proxy:
            session.proxies.update({"https": self.proxy, "http": self.proxy})
        return session


class UploadReader:
    def __init__(self, stream, size, checkpoint):
        self.stream, self.len, self.checkpoint = stream, size, checkpoint
    def read(self, size=-1):
        self.checkpoint(self.stream.tell())
        data = self.stream.read(size)
        self.checkpoint(self.stream.tell())
        return data
    def tell(self): return self.stream.tell()
    def seek(self, *args): return self.stream.seek(*args)
    def fileno(self): return self.stream.fileno()


class MobileService:
    def __init__(self, home):
        self.home = Path(home).resolve()
        self.home.mkdir(parents=True, exist_ok=True)
        os.environ["HOME"] = str(self.home)
        os.chdir(self.home)
        self.client = None
        self.credential = ""
        self.account = ""
        self.full_snapshot_id = ""
        self.full_snapshot_at = 0.0
        self.connection_lock = threading.RLock()
        self.sync_lock = threading.RLock()
        self.content_locks = [threading.Lock() for _ in range(64)]
        self.lifecycle = threading.Condition()
        self.active_operations = 0
        self.exclusive_operation = False
        self.waiting_writers = 0
        self.timing_context = threading.local()

    @contextmanager
    def measured(self, stage):
        start = time.monotonic()
        try:
            yield
        finally:
            metrics = getattr(self.timing_context, "values", None)
            if metrics is not None:
                value = metrics.setdefault(stage, {"ms": 0, "count": 0})
                value["ms"] += max(0, int((time.monotonic() - start) * 1000))
                value["count"] += 1

    @contextmanager
    def reading(self, callback):
        acquire = getattr(callback, "acquireRead", None) if callback else None
        acquired = False
        try:
            with self.measured("read_wait"):
                if acquire is not None:
                    if not acquire(): raise Cancelled()
                    acquired = True
            yield
        finally:
            if acquired: callback.releaseRead()

    def check_digest(self, item, bridge, callback):
        with self.reading(callback), self.measured("file_read"):
            handle = bridge.open(item["uri"], item["name"])
            try:
                result = self.hashes(str(handle.getPath()), callback)
            finally:
                handle.close()
        metrics = getattr(self.timing_context, "values", None)
        if metrics is not None:
            metrics.setdefault("read_bytes", {"ms": 0, "count": 0})["count"] += result["size"]
        return result

    @contextmanager
    def operation(self, exclusive=False):
        # Keep account/client/cache immutable for all in-flight operations,
        # while allowing concurrent uploads within that account.
        with self.lifecycle:
            if exclusive: self.waiting_writers += 1
            try:
                while self.exclusive_operation or (self.active_operations if exclusive else self.waiting_writers):
                    self.lifecycle.wait(0.2)
                if exclusive: self.exclusive_operation = True
                else: self.active_operations += 1
            finally:
                if exclusive: self.waiting_writers -= 1
        try:
            yield
        finally:
            with self.lifecycle:
                if exclusive: self.exclusive_operation = False
                else: self.active_operations -= 1
                self.lifecycle.notify_all()

    def connect(self, credential, timeout=60):
        with self.connection_lock:
            if self.client is None or self.credential != credential:
                self.client = None
                client = Client(auth_data=credential, timeout=timeout, log_level="CRITICAL")
                api = MobileApi(client.auth_data, language=client.language, timeout=timeout)
                _ = api.bearer_token
                client.api = api
                self.client = client
                self.credential = client.auth_data
                self.account = parse_email(client.auth_data).strip().lower()
                self.full_snapshot_id = ""
                self.full_snapshot_at = 0.0
                self._schema()
            before = int(self.client.api.auth_response_cache.get("Expiry", "0"))
            checked = int(time.time())
            _ = self.client.api.bearer_token
            after = int(self.client.api.auth_response_cache["Expiry"])
            return {"account": self.account, "credential": self.credential, "expiry": after,
                    "refreshed": 0 < before <= checked < after}

    def _schema(self):
        key = hashlib.sha256(self.account.encode()).hexdigest()[:32]
        self.db_path = self.home / f"cloud-{key}.sqlite"
        with closing(sqlite3.connect(self.db_path)) as db, db:
            db.executescript("""
                CREATE TABLE IF NOT EXISTS cloud (media_key TEXT PRIMARY KEY, payload TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS albums (album_key TEXT PRIMARY KEY, title TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS state (id INTEGER PRIMARY KEY, token TEXT NOT NULL, ready INTEGER NOT NULL);
                INSERT OR IGNORE INTO state VALUES(1,'',0);
            """)

    def check(self, callback):
        if callback and callback.isCancelled():
            raise Cancelled()

    def emit(self, callback, phase, completed=0, total=0):
        self.check(callback)
        if callback:
            callback.onEvent(json.dumps({"phase": phase, "completed": completed, "total": total}))

    def hashes(self, path, callback=None):
        sha1, sha256 = hashlib.sha1(), hashlib.sha256()
        size = os.stat(path).st_size
        completed = 0
        with open(path, "rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                self.emit(callback, "hashing", completed, size)
                sha1.update(chunk); sha256.update(chunk); completed += len(chunk)
        return {"sha1": sha1.hexdigest(), "sha256": sha256.hexdigest(), "size": completed}

    def process(self, item, bridge, callback):
        self.check(callback)
        handle = bridge.open(item["uri"], item["name"])
        try:
            path = str(handle.getPath())
            digest = self.hashes(path, callback)
            result = {**digest, "remote_key": item.get("remote_key", ""), "origin": item.get("origin", "")}
            if item.get("sha256") and digest["sha256"] != item["sha256"]:
                return {**result, "state": "failed", "error": "SOURCE_CHANGED"}
            if digest["size"] != int(handle.getSize()):
                return {**result, "state": "failed", "error": "SOURCE_CHANGED"}
            with self.content_locks[int(digest["sha1"][:8],16) % len(self.content_locks)]:
                self.emit(callback, "checking", 0, digest["size"])
                remote = self.client.api.find_remote_media_by_hash(bytes.fromhex(digest["sha1"]))
                if remote:
                    result.update(remote_key=remote, origin=result["origin"] or "content_exists")
                elif item.get("remote_key"):
                    return {**result, "state": "failed", "error": "REMOTE_MISSING"}
                else:
                    if item.get("same_name"):
                        self.synchronize(callback)
                        with closing(sqlite3.connect(self.db_path)) as db, db:
                            candidates = [json.loads(row[0]) for row in db.execute("SELECT payload FROM cloud")]
                        if any(x.get("name") == item["name"] for x in candidates):
                            return {**result, "state": "filename_skipped", "error": "FILENAME_ONLY"}
                    maximum = max(0, min(3, int(item.get("retries", 3))))
                    for attempt in range(maximum + 1):
                        try:
                            self.check(callback)
                            token = self.client.api.get_upload_token(
                                __import__("base64").b64encode(bytes.fromhex(digest["sha1"])).decode(), digest["size"])
                            with open(path, "rb") as stream:
                                upload = self.client.api.upload_file(UploadReader(stream, digest["size"],
                                    lambda current: self.emit(callback, "uploading", current, digest["size"])), token)
                            self.check(callback)
                            # Verify the source again before committing an immutable content hash.
                            final = self.hashes(path, callback)
                            if final != digest:
                                return {**result, "state": "failed", "error": "SOURCE_CHANGED"}
                            self.emit(callback, "finalizing", digest["size"], digest["size"])
                            quality = item.get("quality", "original")
                            remote = self.client.api.commit_upload(upload, item["name"], bytes.fromhex(digest["sha1"]),
                                quality="saver" if quality == "saver" else "original",
                                model="Pixel 2" if quality == "saver" else ("Pixel 8" if quality == "quota" else "Pixel XL"),
                                upload_timestamp=int(item.get("modified", 0)) // 1000 or None)
                            result.update(remote_key=remote, origin="uploaded")
                            break
                        except Exception as error:
                            code = error_code(error)
                            if code not in ("NETWORK_ERROR", "RATE_LIMITED") or attempt >= maximum:
                                raise
                            self.emit(callback, "retrying", attempt + 1, maximum)
                            deadline = time.monotonic() + min(30, 2 ** (attempt + 1))
                            while time.monotonic() < deadline:
                                self.check(callback); time.sleep(0.2)
                # Persist the successful upload before any potentially failing album action.
                if callback:
                    callback.onEvent(json.dumps({"phase": "uploaded", **result}))
                try:
                    self.check(callback)
                    mode, value = item.get("album_mode", "none"), item.get("album_value", "")
                    if mode == "folder": value = item.get("folder", "")
                    if mode == "existing" and value:
                        self.client.add_to_existing_album([result["remote_key"]], value)
                    elif mode in ("folder", "custom") and value:
                        with self.sync_lock:
                            with closing(sqlite3.connect(self.db_path)) as db, db:
                                found = db.execute("SELECT album_key FROM albums WHERE title=? ORDER BY album_key LIMIT 1", (value,)).fetchone()
                            if found:
                                self.client.add_to_existing_album([result["remote_key"]], found[0])
                            else:
                                album_key = self.client.api.create_album(value, [result["remote_key"]])
                                with closing(sqlite3.connect(self.db_path)) as db, db:
                                    db.execute("INSERT OR REPLACE INTO albums VALUES(?,?)", (album_key, value))
                except Cancelled:
                    return {**result, "state": "album_pending", "error": "CANCELLED"}
                except Exception as error:
                    return {**result, "state": "album_pending", "error": error_code(error)}
                return {**result, "state": "exists" if result["origin"] == "content_exists" else "done"}
        finally:
            handle.close()

    def _consume(self, response, snapshot_id=""):
        token, resume, _, deleted = parse_db_update(response)
        root = response.get("1", {})
        raw_items = root.get("2", [])
        if isinstance(raw_items, dict): raw_items = [raw_items]
        with closing(sqlite3.connect(self.db_path)) as db, db:
            for raw in raw_items:
                if not isinstance(raw, dict): continue
                try:
                    from .db_update_parser import _parse_media_item, _get_nested
                    item = _parse_media_item(raw)
                    details = raw.get("2", {})
                    trash_section = details.get("16")
                    # The wire decoder represents an empty optional submessage as b''/''.
                    # Missing section, malformed timestamps and unrecognized shapes stay unknown.
                    empty_trash_marker = (isinstance(trash_section, (bytes, str)) and len(trash_section) == 0) or (
                        isinstance(trash_section, dict) and "3" not in trash_section)
                    # Preserve field presence separately from values. An absent marker may
                    # only be interpreted with a complete, fresh library snapshot below.
                    payload = {"key": item.media_key, "dedup": item.dedup_key, "name": item.file_name, "size": known_integer(details.get("10")),
                        "original": item.is_original_quality if _get_nested(details, "35", "3") is not None else None,
                        "trash": known_integer(_get_nested(details,"16","3")),
                        "trash_marker_absent": empty_trash_marker, "snapshot_id": snapshot_id,
                        "trash_shape": type(trash_section).__name__,
                        "status": known_integer(details.get("11")), "origin": item.origin,
                        "quota": known_integer(_get_nested(details, "35", "2"))}
                    db.execute("INSERT OR REPLACE INTO cloud VALUES(?,?)", (item.media_key, json.dumps(payload)))
                except (TypeError, ValueError, KeyError, RuntimeError):
                    continue
            for key in deleted:
                db.execute("DELETE FROM cloud WHERE media_key=?", (key,))
                db.execute("DELETE FROM albums WHERE album_key=?", (key,))
            collections = root.get("3", [])
            if isinstance(collections, dict): collections = [collections]
            for collection in collections:
                if not isinstance(collection, dict): continue
                title = collection.get("2", {}).get("5") if isinstance(collection.get("2"), dict) else None
                key = collection.get("1")
                if isinstance(title, bytes): title = title.decode("utf-8", errors="replace")
                if isinstance(key, bytes): key = key.decode("utf-8", errors="replace")
                if isinstance(title, str) and isinstance(key, str):
                    db.execute("INSERT OR REPLACE INTO albums VALUES(?,?)", (key, title))
        return token, resume

    def synchronize(self, callback=None, full=False):
        with self.sync_lock:
            with closing(sqlite3.connect(self.db_path)) as db, db:
                token, ready = db.execute("SELECT token,ready FROM state WHERE id=1").fetchone()
            if full: token, ready = "", False
            snapshot_id = uuid.uuid4().hex if not ready else ""
            if not ready:
                self.full_snapshot_id = ""
                with closing(sqlite3.connect(self.db_path)) as db, db:
                    db.execute("UPDATE state SET token='',ready=0 WHERE id=1")
                    db.execute("DELETE FROM cloud")
            for cycle in range(10):
                self.check(callback)
                with self.measured("sync_requests"):
                    response = self.client.api.get_library_state(token if ready else "")
                new_token, resume = self._consume(response, snapshot_id)
                more = self.client._should_trigger_next_sync(response)
                seen = set()
                while resume:
                    self.emit(callback, "cloud_check")
                    if resume in seen: raise RuntimeError("SYNC_CYCLE")
                    seen.add(resume)
                    with self.measured("sync_requests"):
                        response = self.client.api.get_library_page(resume, token) if ready else self.client.api.get_library_page_init(resume)
                    page_token, resume = self._consume(response, snapshot_id)
                    new_token = page_token or new_token
                self.check(callback)
                token = new_token or token
                if not token: raise RuntimeError("SYNC_TOKEN_MISSING")
                if not more:
                    with closing(sqlite3.connect(self.db_path)) as db, db:
                        db.execute("UPDATE state SET token=?,ready=1 WHERE id=1", (token,))
                    if snapshot_id:
                        self.full_snapshot_id = snapshot_id
                        self.full_snapshot_at = time.monotonic()
                    return
                ready = True
            raise RuntimeError("SYNC_INCOMPLETE")

    def reconcile(self, values, callback=None):
        self.synchronize(callback)
        missing = []
        with closing(sqlite3.connect(self.db_path)) as db, db:
            for key in values.get("keys", []):
                row = db.execute("SELECT payload FROM cloud WHERE media_key=?", (key,)).fetchone()
                if row is None or json.loads(row[0]).get("trash") not in (None, 0):
                    missing.append(key)
        return {"missing": missing}

    def albums(self, callback=None):
        self.synchronize(callback)
        with closing(sqlite3.connect(self.db_path)) as db, db:
            return [{"id": key, "name": title} for key, title in db.execute("SELECT album_key,title FROM albums ORDER BY title")]

    @staticmethod
    def allowed_url(url):
        parsed = urlparse(url)
        return parsed.scheme == "https" and parsed.username is None and parsed.password is None and any(
            parsed.hostname == suffix or (parsed.hostname or "").endswith("." + suffix)
            for suffix in ("google.com", "googleusercontent.com", "googlevideo.com"))

    def original_access(self, key, expected_size, callback=None):
        self.check(callback)
        with self.measured("original_url"):
            response = self.client.api.get_download_urls(key)
        try: url = response["1"]["5"]["2"]["6"]
        except (KeyError, TypeError): return False
        if isinstance(url, bytes): url = url.decode("utf-8")
        if not isinstance(url, str) or not self.allowed_url(url): return False
        with requests.Session() as session:
            for method in ("HEAD", "GET"):
                current = url
                for _ in range(6):
                    self.check(callback)
                    if not self.allowed_url(current): return False
                    with self.measured("original_head" if method == "HEAD" else "original_range"), session.request(method, current, headers={"Accept-Encoding": "identity", **({"Range": "bytes=0-0"} if method == "GET" else {})},
                        allow_redirects=False, stream=True, timeout=(15, 30)) as check:
                        if check.status_code in (301,302,303,307,308):
                            from urllib.parse import urljoin
                            current = urljoin(current, check.headers.get("Location", "")); continue
                        if check.status_code == 429 or check.status_code >= 500:
                            check.raise_for_status()
                        if method == "HEAD" and (check.status_code in (400,403,405,501) or (check.status_code == 200 and not check.headers.get("Content-Length", "").isdigit())): break
                        if check.status_code not in (200,206): return False
                        length = check.headers.get("Content-Length", "")
                        if check.status_code == 206:
                            match = re.fullmatch(r"bytes 0-0/(\d+)", check.headers.get("Content-Range", ""))
                            length = match.group(1) if match else ""
                        return length.isdigit() and int(length) == expected_size
            return False

    def verify_cleanup(self, item, bridge, callback):
        digest = self.check_digest(item, bridge, callback)
        if item.get("sha256") and item["sha256"] != digest["sha256"]:
            return {"eligible": False, "reason": "SOURCE_CHANGED", **digest}
        with self.measured("content_query"):
            key = self.client.api.find_remote_media_by_hash(bytes.fromhex(digest["sha1"]))
        if not key: return {"eligible": False, "reason": "REMOTE_MISSING", **digest}
        if item.get("check_mode") == "quick":
            return {"eligible": False, "found": True, "reason": "STATUS_ONLY", "remote_key": key, **digest}
        with closing(sqlite3.connect(self.db_path)) as db, db:
            row = db.execute("SELECT payload FROM cloud WHERE media_key=?", (key,)).fetchone()
        if not row: return {"eligible": False, "reason": "CLOUD_ITEM_MISSING", **digest}
        cloud = json.loads(row[0])
        if not self.full_snapshot_id or cloud.get("snapshot_id") != self.full_snapshot_id or not 0 <= time.monotonic() - self.full_snapshot_at < 300:
            return {"eligible": False, "reason": "CLOUD_STATE_UNKNOWN", **digest}
        trash = cloud.get("trash")
        if trash is None and cloud.get("trash_marker_absent") is True:
            # Verified against this protocol: normal -> empty marker, trashed -> timestamp,
            # restored -> empty marker. This applies only to a fresh COMPLETE snapshot.
            trash = 0
        if trash is None: return {"eligible": False, "reason": "CLOUD_TRASH_UNKNOWN", **digest}
        if trash != 0: return {"eligible": False, "reason": "REMOTE_TRASHED", **digest}
        if cloud["original"] is None: return {"eligible": False, "reason": "CLOUD_QUALITY_UNKNOWN", **digest}
        if cloud["status"] != 100: return {"eligible": False, "reason": "CLOUD_PROCESSING", **digest}
        if cloud["original"] is not True or cloud["size"] != digest["size"]:
            return {"eligible": False, "reason": "ORIGINAL_UNCONFIRMED", **digest}
        try:
            accessible = self.original_access(key, digest["size"], callback)
        except requests.exceptions.RequestException as error:
            code = error_code(error)
            if code == "LOGIN_REQUIRED": raise
            return {"eligible": False, "reason": "RATE_LIMITED" if code == "RATE_LIMITED" else "ORIGINAL_NETWORK_ERROR", **digest}
        if not accessible:
            return {"eligible": False, "reason": "ORIGINAL_UNAVAILABLE", **digest}
        return {"eligible": True, "reason": "", "remote_key": key, **digest}


    def dispatch(self, action, payload, bridge=None, callback=None):
        self.timing_context.values = {}
        try:
            with self.measured("engine_total"):
                result = json.loads(self._dispatch(action, payload, bridge, callback))
            result["_metrics"] = self.timing_context.values
            return json.dumps(result)
        finally:
            self.timing_context.values = None

    def _dispatch(self, action, payload, bridge=None, callback=None):
        try:
            with self.operation(action in ("connect", "logout")):
                values = json.loads(payload) if isinstance(payload, str) else payload
                if action == "logout":
                    with self.connection_lock:
                        self.client = None; self.credential = ""; self.account = ""
                    return json.dumps({"ok": True})
                if action == "connect": return json.dumps({"ok": True, **self.connect(values["credential"], values.get("timeout",60))})
                if self.client is None: return json.dumps({"ok": False, "error": "LOGIN_REQUIRED"})
                if values.get("_account", self.account) != self.account:
                    return json.dumps({"ok": False, "error": "ACCOUNT_CHANGED"})
                if action == "process": result = self.process(values,bridge,callback)
                elif action == "synchronize":
                    with self.measured("cloud_sync"):
                        self.synchronize(callback, values.get("full", False))
                    result = {}
                elif action == "reconcile": result = self.reconcile(values,callback)
                elif action == "albums": result = {"albums": self.albums(callback)}
                elif action == "verify_cleanup": result = self.verify_cleanup(values,bridge,callback)
                elif action == "fingerprint":
                    handle = bridge.open(values["uri"],values["name"])
                    try: result = self.hashes(str(handle.getPath()),callback)
                    finally: handle.close()
                else: return json.dumps({"ok": False, "error": "UNKNOWN_OPERATION"})
                return json.dumps({"ok": True, **result})
        except Exception as error:
            return json.dumps({"ok": False, "error": error_code(error)})
