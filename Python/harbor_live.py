"""Original Live Photo protocol adapter; no file transport or deletion here.

Schema/opaque result mask reference: xob0t/gotohp @ 97a5dc0,
core/create_media_items.go (MIT, copyright 2024 xob0t).
Still-first reconciliation reference: g8row/PhotosBackup @ 3c88269.
Source/license details: NOTICE.md and docs/LIVE-PHOTO-PROTOCOL-RESEARCH.md.
"""
import base64
from pathlib import Path

from blackboxprotobuf import decode_message
from gpmc.message_types import FIND_REMOTE_MEDIA_BY_HASH_RESPONSE, COMMIT_UPLOAD_RESPONSE


RESULT_MASK = base64.b64decode("CnsKAggBEAEaAggBIgIIASoQCgIIARICCAEaAggBIgIIATICCAGCAQIIAYoBAggBmgECCAGiAQIIAaoBCggBKgIgATICCAHKAQIIAfIBBggBEgIIAfoBAggBggICCAGKAgQKAggBkgIGCAESAggBogICCAGqAgC6AgDCAgAQASpiCAESKggBEhIIARoGCAESAggBIgQIASIAKAEiBggBEgIQASoGCAESAggBMAE4ARoWCAESDAgBGgIIASICCAEoARoCCAEwASIKCAESBggBEgIIASoOCgQIATABEgYIARICCAE6AggBQgIIAUoKCAESAggBGgISAFoSEgIIARoCCAEiCAgBEgQIARACYgIIAXISEgIIARoCCAEiCAgBEgQIARACeggKAggBIgIIAYoBBAoCCAGSAQQIARABqgECCgA=")


def varint(value):
    value &= (1 << 64) - 1
    result = bytearray()
    while value > 127:
        result.append((value & 127) | 128)
        value >>= 7
    result.append(value)
    return bytes(result)


def integer(field, value):
    return varint(field << 3) + varint(value)


def blob(field, value):
    return varint((field << 3) | 2) + varint(len(value)) + value


class LiveProtocol:
    def __init__(self, protocol):
        self.protocol = protocol

    @property
    def api(self):
        return self.protocol.api

    def post(self, method, body, schema, commit=False):
        from harbor_ios import Failure
        headers = {"Authorization": "Bearer " + self.api.bearer_token,
                   "User-Agent": self.api.user_agent, "Content-Type": "application/x-protobuf",
                   "Accept-Language": self.api.language, "Accept-Encoding": "gzip"}
        if commit:
            headers.update({"x-goog-ext-173412678-bin": "CgcIAhClARgC", "x-goog-ext-174067345-bin": "CgIIAg=="})
        with self.api._new_session() as session:
            response = session.post("https://photosdata-pa.googleapis.com/6439526531001121323/" + method,
                                    data=body, headers=headers, timeout=self.api.timeout)
            if commit and response.status_code == 400:
                raise Failure("PAIR_COMMIT_REJECTED")
            response.raise_for_status()
            try:
                return decode_message(response.content, schema)[0]
            except Exception:
                raise Failure("COMMIT_UNCONFIRMED" if commit else "PAIR_LOOKUP_INVALID") from None

    def motion_key(self, digest):
        query = blob(1, digest) + integer(5, 2)  # PhodeoMovie, not a standalone MOV.
        response = self.post("5084965799730810217", blob(1, blob(1, query) + blob(2, b"")), FIND_REMOTE_MEDIA_BY_HASH_RESPONSE)
        from gpmc.db_update_parser import _get_nested
        key = _get_nested(response, "1", "2", "2", "1")
        return key if isinstance(key, str) and key else ""

    def status(self, value):
        photo, video = self.protocol.digest(value["photo"]), self.protocol.digest(value["video"])
        still_key = self.api.find_remote_media_by_hash(photo) or ""
        movie_key = self.motion_key(video)
        linked = bool(still_key and still_key == movie_key)
        return {"confirmed": linked, "remote_key": still_key if linked else "",
                "photo_key": still_key, "motion_key": movie_key,
                "reason": "" if linked else "PAIR_CONFIRMATION_PENDING"}

    def receipt(self, value):
        from harbor_ios import Failure
        try:
            path = Path(value["response_path"]).resolve()
            if not path.is_relative_to(self.protocol.service.staging.resolve()):
                raise Failure("UPLOAD_RESPONSE_PATH")
            if not path.is_file():
                raise Failure("UPLOAD_RESPONSE_MISSING")
            size = path.stat().st_size
            if not 0 < size <= 4 * 1024 * 1024:
                raise Failure("UPLOAD_RESPONSE_EMPTY" if size == 0 else "UPLOAD_RESPONSE_TOO_LARGE")
            data = path.read_bytes()
        except (KeyError, TypeError, ValueError):
            raise Failure("UPLOAD_RESPONSE_PATH") from None
        except OSError:
            raise Failure("UPLOAD_RESPONSE_READ") from None
        try:
            decoded, _ = decode_message(data, {"1": {"type": "int"}, "2": {"type": "bytes"}})
            if decoded.get("1") != 2 or not isinstance(decoded.get("2"), bytes) or not decoded["2"]:
                raise ValueError()
        except Exception:
            raise Failure("UPLOAD_RESPONSE_INVALID") from None
        return data  # Opaque original response bytes, never reconstruct the token.

    def commit(self, value):
        from harbor_ios import Failure
        photo, video = value["photo"], value["video"]
        photo_hash, video_hash = self.protocol.digest(photo), self.protocol.digest(video)
        route, quality = value.get("route"), value.get("quality", "original")
        if route not in ("joint", "reconcile") or quality not in ("original", "quota", "saver"):
            raise Failure("INVALID_PAIR_POLICY")
        primary = photo if route == "joint" else video
        name = primary.get("name", "")
        if not isinstance(name, str) or not name or len(name.encode()) > 2048 or "/" in name or "\\" in name:
            raise Failure("INVALID_PAIR_NAME")
        created, modified = value.get("created_at", 0), value.get("modified_at", 0)
        if type(created) is not int or type(modified) is not int or not all(-(1 << 62) < t < (1 << 62) for t in (created, modified)):
            raise Failure("INVALID_PAIR_DATE")
        video_receipt = self.receipt(video)
        primary_receipt = self.receipt(photo) if route == "joint" else video_receipt
        policy = 1 if quality == "saver" else 3
        model = {"original": "Pixel XL", "quota": "Pixel 8", "saver": "Pixel 2"}[quality]
        blueprint = (blob(1, primary_receipt) + blob(2, name.encode()) + blob(3, photo_hash if route == "joint" else video_hash)
                     + blob(5, integer(1, created)) + blob(6, integer(1, modified)) + integer(7, policy) + integer(10, 1))
        if route == "joint":
            blueprint += blob(24, blob(1, video_receipt) + blob(2, video_hash))
        else:
            blueprint += blob(9, integer(2, 1) + blob(3, photo_hash))
        device = blob(3, model.encode()) + blob(4, b"Google") + integer(5, self.api.android_api_version)
        response = self.post("16538846908252377752", blob(1, blueprint) + blob(2, device) + blob(5, RESULT_MASK), COMMIT_UPLOAD_RESPONSE, commit=True)
        self.protocol.snapshot_at = 0
        from gpmc.db_update_parser import _get_nested
        key = _get_nested(response, "1", "3", "1")
        if not isinstance(key, str) or not key:
            raise Failure("COMMIT_UNCONFIRMED")
        return {"remote_key": key, "route": route}
