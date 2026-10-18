"""Version 2 stateless media protocol; native SQLite owns all new backup jobs.

No guessed Live Photo RPC is sent. Apple-pair support stays an explicit missing
capability until an observed protocol and official-client round trip prove it.
"""
import base64
import re
import time
from urllib.parse import quote, urlparse, urljoin

from blackboxprotobuf import decode_message
from gpmc.db_update_parser import parse_db_update, _parse_media_item, _get_nested


class Protocol:
    actions = {"prepare_upload", "commit_resource", "confirm_resource", "sync_cloud",
               "check_cleanup", "create_album", "add_to_album", "pair_apple"}

    def __init__(self, service):
        self.service = service
        self.snapshot = {}
        self.snapshot_at = 0

    @property
    def api(self):
        return self.service.api

    @staticmethod
    def capabilities():
        return {"protocol_version": 2, "native_file_transport": True,
                "apple_pair": False, "apple_pair_reason": "PAIR_PROTOCOL_UNVERIFIED",
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
        if action == "pair_apple":
            raise Failure("PAIR_PROTOCOL_UNVERIFIED")
        if action == "prepare_upload":
            digest = self.digest(value)
            remote = self.api.find_remote_media_by_hash(digest)
            if remote and not value.get("force", False):
                return {"exists": True, "remote_key": remote}
            token = self.api.get_upload_token(base64.b64encode(digest).decode(), value["size"])
            return {"exists": False, "url": "https://photos.googleapis.com/data/upload/uploadmedia/interactive?upload_id=" + quote(token, safe=""),
                    "headers": {"Authorization": "Bearer " + self.api.bearer_token,
                                "User-Agent": self.api.user_agent, "Accept-Language": self.api.language,
                                "Accept-Encoding": "gzip"}}
        if action == "commit_resource":
            self.digest(value)
            quality = value.get("quality", "original")
            if quality not in ("original", "quota", "saver"):
                raise Failure("INVALID_QUALITY")
            path = self.service.path(value["response_path"])
            if path.stat().st_size > 4 * 1024 * 1024:
                raise Failure("INVALID_RESPONSE")
            decoded, _ = decode_message(path.read_bytes())
            key = self.api.commit_upload(decoded, value["name"], bytes.fromhex(value["sha1"]),
                quality="saver" if quality == "saver" else "original",
                model={"original": "Pixel XL", "quota": "Pixel 8", "saver": "Pixel 2"}[quality])
            if not isinstance(key, str) or not key:
                raise Failure("COMMIT_UNCONFIRMED")
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
        self.snapshot, self.snapshot_at = {}, 0
        values, token, ready = {}, "", False
        for _ in range(10):
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
                        values[item.media_key] = {"size": details.get("10"), "status": details.get("11"),
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
                response = self.api.get_library_page(resume, token) if ready else self.api.get_library_page_init(resume)
            if not token:
                raise Failure("SYNC_TOKEN_MISSING")
            if not more:
                self.snapshot, self.snapshot_at = values, time.monotonic()
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
