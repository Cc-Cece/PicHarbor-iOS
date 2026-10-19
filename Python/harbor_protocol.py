"""Version 2 stateless media protocol; native SQLite owns all new backup jobs.

Original pairing is experimental, based on published protocol implementations.
Capability means executable test support, not completed device acceptance.
"""
import base64
import re
import time
from urllib.parse import quote, urlparse, urljoin

from blackboxprotobuf import decode_message
from gpmc.db_update_parser import parse_db_update, _parse_media_item, _get_nested


class Protocol:
    actions = {"prepare_upload", "commit_resource", "confirm_resource", "sync_cloud",
               "check_cleanup", "create_album", "add_to_album", "pair_apple", "confirm_pair", "prepare_pair_component", "commit_pair_photo", "motion_status"}

    def __init__(self, service):
        self.service = service
        self.snapshot = {}
        self.snapshot_at = 0
        self.sync_token = ""

    @property
    def api(self):
        return self.service.api

    @staticmethod
    def capabilities():
        return {"protocol_version": 2, "native_file_transport": True,
                "apple_pair": True, "apple_pair_experimental": True, "apple_pair_routes": ["joint", "reconcile"],
                "motion_mux_version": 1, "cloud_delete": False}

    def digest(self, value):
        # Native hashing is repeated before commit. Boundary rejects malformed digests.
        sha1, sha256, size = value.get("sha1", ""), value.get("sha256", ""), value.get("size", 0)
        if not re.fullmatch(r"[0-9a-f]{40}", sha1) or not re.fullmatch(r"[0-9a-f]{64}", sha256) or type(size) is not int or size <= 0:
            from harbor_ios import Failure
            raise Failure("INVALID_DIGEST")
        return bytes.fromhex(sha1)

    def dispatch(self, action, value):
        from harbor_ios import Failure
        if action in ("pair_apple", "confirm_pair"):
            if not isinstance(value.get("photo"), dict) or not isinstance(value.get("video"), dict):
                raise Failure("INVALID_PAIR_RESOURCES")
            from harbor_live import LiveProtocol
            adapter = LiveProtocol(self)
            return adapter.commit(value) if action == "pair_apple" else adapter.status(value)
        if action in ("prepare_upload", "prepare_pair_component"):
            digest = self.digest(value)
            remote = self.api.find_remote_media_by_hash(digest) if action == "prepare_upload" else None
            if remote and not value.get("force", False):
                return {"exists": True, "remote_key": remote}
            token = self.api.get_upload_token(base64.b64encode(digest).decode(), value["size"])
            return {"exists": False, "url": "https://photos.googleapis.com/data/upload/uploadmedia/interactive?upload_id=" + quote(token, safe=""),
                    "headers": {"Authorization": "Bearer " + self.api.bearer_token,
                                "User-Agent": self.api.user_agent, "Accept-Language": self.api.language,
                                "Accept-Encoding": "gzip"}}
        pair_photo = action == "commit_pair_photo"
        if action == "commit_resource" or pair_photo:
            self.digest(value)
            quality = value.get("quality", "original")
            if quality not in ("original", "quota", "saver"):
                raise Failure("INVALID_QUALITY")
            if pair_photo:
                from harbor_live import LiveProtocol
                LiveProtocol(self).receipt(value)
            from pathlib import Path
            try:
                path = Path(value["response_path"]).resolve()
                if not path.is_relative_to(self.service.staging.resolve()):
                    raise Failure("UPLOAD_RESPONSE_PATH")
                if not path.is_file():
                    raise Failure("UPLOAD_RESPONSE_MISSING")
                size = path.stat().st_size
                if size == 0:
                    raise Failure("UPLOAD_RESPONSE_EMPTY")
                if size > 4 * 1024 * 1024:
                    raise Failure("UPLOAD_RESPONSE_TOO_LARGE")
                data = path.read_bytes()
            except OSError:
                raise Failure("UPLOAD_RESPONSE_READ") from None
            try:
                decoded, _ = decode_message(data, {"1": {"type": "int"}, "2": {"type": "bytes"}}) if pair_photo else decode_message(data)
            except Exception:
                raise Failure("UPLOAD_RESPONSE_INVALID") from None
            key = self.api.commit_upload(decoded, value["name"], bytes.fromhex(value["sha1"]),
                quality="saver" if quality == "saver" else "original",
                model={"original": "Pixel XL", "quota": "Pixel 8", "saver": "Pixel 2"}[quality])
            if not isinstance(key, str) or not key:
                raise Failure("COMMIT_UNCONFIRMED")
            self.snapshot_at = 0
            return {"remote_key": key}
        if action == "confirm_resource":
            key = self.api.find_remote_media_by_hash(self.digest(value))
            return {"confirmed": bool(key), "remote_key": key or ""}
        if action == "create_album":
            title = value.get("title", "").strip()
            if not title or len(title) > 500:
                raise Failure("INVALID_ALBUM")
            return {"remote_key": self.api.create_album(title, value["keys"])}
        if action == "add_to_album":
            self.api.add_media_to_album(value["remote_key"], value["keys"])
            return {}
        if action == "sync_cloud":
            self.synchronize()
            return {"count": len(self.snapshot), "complete": True}
        if action == "motion_status":
            keys = value.get("keys", [])
            if not isinstance(keys, list) or not keys or not all(isinstance(key, str) and key for key in keys):
                raise Failure("INVALID_REMOTE_KEYS")
            if not 0 <= time.monotonic() - self.snapshot_at < 15:
                self.synchronize()
            checks = []
            for key in keys:
                item = self.snapshot.get(key)
                reason = ("REMOTE_MOTION_NOT_INDEXED" if item is None else
                          "REMOTE_MOTION_TRASHED" if item.get("motion_trash", item.get("trash")) not in (0, None) else
                          "REMOTE_MOTION_TRASH_UNKNOWN" if item.get("motion_trash", item.get("trash")) is None else
                          "REMOTE_MOTION_PROCESSING" if item.get("status") != 100 else
                          "REMOTE_MOTION_NOT_DYNAMIC" if item.get("motion") is not True else "")
                checks.append(reason)
            return {"recognized": not any(checks), "reason": next((reason for reason in checks if reason), "")}
        if action == "check_cleanup":
            key = self.api.find_remote_media_by_hash(self.digest(value))
            if not key:
                return {"eligible": False, "reason": "REMOTE_MISSING"}
            state, access = value.get("cloud_state", True), value.get("original_access", True)
            if type(state) is not bool or type(access) is not bool:
                raise Failure("INVALID_CHECK_POLICY")
            if state:
                if not 0 <= time.monotonic() - self.snapshot_at < 300:
                    return {"eligible": False, "reason": "CLOUD_STATE_EXPIRED"}
                cloud = self.snapshot.get(key)
                if not cloud or cloud["trash"] != 0 or cloud["status"] != 100 or cloud["original"] is not True or cloud["size"] != value["size"]:
                    return {"eligible": False, "reason": "CLOUD_ORIGINAL_UNCONFIRMED"}
            if access and not self.original_access(key, value["size"]):
                return {"eligible": False, "reason": "ORIGINAL_UNAVAILABLE"}
            return {"eligible": True, "remote_key": key}
        raise Failure("UNKNOWN_OPERATION")

    def synchronize(self):
        from harbor_ios import Failure
        # Publish the snapshot only after every page/cycle has completed successfully.
        values = dict(self.snapshot) if self.sync_token else {}
        token, ready = self.sync_token, bool(self.sync_token)
        # A failed refresh invalidates evidence and the token. The next attempt
        # starts a full sync; never publish a partially applied delta.
        self.snapshot, self.snapshot_at, self.sync_token = {}, 0, ""
        for _ in range(10):
            page_token = token  # Pagination belongs to the input sync context.
            response = self.api.get_library_state(token if ready else "")
            more = _get_nested(response, "1", "7") == 2
            seen = set()
            while True:
                new_token, resume, _, deleted = parse_db_update(response)
                token = new_token or token
                raw_items = _get_nested(response, "1", "2") or []
                if isinstance(raw_items, dict):
                    raw_items = [raw_items]
                for raw in raw_items:
                    try:
                        item = _parse_media_item(raw)
                        details = raw.get("2", {})
                        marker = details.get("16")
                        trash = _get_nested(details, "16", "3")
                        empty = (isinstance(marker, (bytes, str)) and not marker) or (isinstance(marker, dict) and "3" not in marker)
                        values[item.media_key] = {"size": details.get("10"), "status": item.upload_status,
                            "motion": item.is_micro_video,
                            # Upstream treats an omitted optional trash marker as not trashed.
                            # Keep cleanup's stronger explicit-marker evidence separate.
                            "motion_trash": 0 if marker is None or empty else (trash if type(trash) is int else None),
                            "original": item.is_original_quality if _get_nested(details, "35", "3") is not None else None,
                            "trash": 0 if trash is None and empty else trash}
                    except (TypeError, ValueError, KeyError, RuntimeError):
                        continue
                for key in deleted:
                    values.pop(key, None)
                if not resume:
                    break
                if resume in seen:
                    raise Failure("SYNC_CYCLE")
                seen.add(resume)
                response = self.api.get_library_page(resume, page_token) if ready else self.api.get_library_page_init(resume)
            if not token:
                raise Failure("SYNC_TOKEN_MISSING")
            if not more:
                self.snapshot, self.snapshot_at = values, time.monotonic()
                self.sync_token = token
                return
            ready = True
        raise Failure("SYNC_INCOMPLETE")

    @staticmethod
    def allowed_url(url):
        parsed = urlparse(url)
        return parsed.scheme == "https" and parsed.username is None and parsed.password is None and parsed.port in (None, 443) and any(
            parsed.hostname == suffix or (parsed.hostname or "").endswith("." + suffix)
            for suffix in ("google.com", "googleusercontent.com", "googlevideo.com"))

    def original_access(self, key, expected):
        url = _get_nested(self.api.get_download_urls(key), "1", "5", "2", "6")
        if isinstance(url, bytes):
            url = url.decode("utf-8")
        if not isinstance(url, str) or not self.allowed_url(url):
            return False
        with self.api._new_session() as session:
            for method in ("HEAD", "GET"):
                current = url
                for _ in range(6):
                    if not self.allowed_url(current):
                        return False
                    headers = {"Accept-Encoding": "identity"}
                    if method == "GET":
                        headers["Range"] = "bytes=0-0"
                    with session.request(method, current, headers=headers, allow_redirects=False, stream=True, timeout=(15, 30)) as response:
                        if response.status_code in (301, 302, 303, 307, 308):
                            current = urljoin(current, response.headers.get("Location", ""))
                            continue
                        if response.status_code == 429 or response.status_code >= 500:
                            response.raise_for_status()
                        length = response.headers.get("Content-Length", "")
                        if method == "HEAD" and (response.status_code in (400, 403, 405, 501) or (response.status_code == 200 and not length.isdigit())):
                            break
                        if response.status_code == 206:
                            match = re.fullmatch(r"bytes 0-0/(\d+)", response.headers.get("Content-Range", ""))
                            length = match.group(1) if match else ""
                        return response.status_code in (200, 206) and length.isdigit() and int(length) == expected
        return False
