"""Shared business core for PicHarbor mobile backup (Android + iOS).

Pure Python: no platform imports, no network, no file access except the
explicit ``store_save`` / ``store_load`` paths the caller supplies.
Android (Chaquopy) and iOS (embedded Python 3.13 + PythonBridge) both call
this module through :func:`dispatch` / :func:`dispatch_json`.

Scope split with :mod:`gpmc.protocol` (see ``docs/HARBOR-CORE.md``):

* ``harbor_core`` makes *business decisions*: task state machine, dedup
  decisions (including per-resource decisions for Live / Motion Photo
  pairs), retry backoff, cleanup-guidance eligibility (page-level and
  per-item), batch pause / resume, backup-scope evaluation, proxy
  configuration validation, LiveLink capability handshake and scope
  checks, task persistence, log redaction.
* ``Protocol`` *executes* the Google Photos wire protocol: prepare / commit /
  confirm / sync against the remote API.

No deletion of local assets
----------------------------
Per PicHarbor-iOS ``docs/REQUIREMENTS.md`` (2026-10-19 scope revision) and
Yuto's 2026-11-13 decision, local cleanup is handed to Google Photos'
official "free up space". PicHarbor's own local-cleanup feature is
cancelled. This module therefore contains **no ability to delete local
assets**: no delete function, no delete action, no delete backdoor.
:func:`decide_cleanup` only decides whether the cloud-confirmation evidence
is sufficient to *guide the user to the official Google Photos free-up-space
feature* (in-app guidance / deep link). ``eligible: True`` means "the cloud
original is confirmed with fresh evidence, so the official-cleanup guidance
may be shown" -- it never authorises PicHarbor itself to delete anything.
"""
import json
import os
import re
import tempfile
import time
from contextlib import suppress
from datetime import UTC, datetime
from pathlib import Path

from .errors import classify
from .exceptions import ProtocolError as _Failure

__all__ = [
    "HARBOR_CORE_VERSION",
    "PROTOCOL_VERSION",
    "STATES",
    "ACTIONS",
    "MEDIA_KINDS",
    "CLEANUP_EVIDENCE_MAX_AGE_SECONDS",
    "RETRY_BASE_SECONDS",
    "RETRY_MAX_SECONDS",
    "STORE_VERSION",
    "HarborCore",
    "dispatch",
    "dispatch_json",
    "create_task",
    "transition",
    "decide_prepare",
    "decide_cleanup",
    "retry_delay",
    "store_save",
    "store_load",
    "migrate_legacy",
    "log_event",
    "capabilities",
]

HARBOR_CORE_VERSION = 1
PROTOCOL_VERSION = 2

STATES = (
    "queued",
    "preparing",
    "dedup_hit",
    "uploading",
    "submitting",
    "confirming",
    "done",
    "paused",
    "failed",
    "waiting_network",
    "waiting_confirmation",
    "cancelled",
    "interrupted",
)
_STATE_SET = frozenset(STATES)

ACTIONS = (
    "create_task",
    "transition",
    "decide_prepare",
    "decide_cleanup",
    "batch_pause",
    "batch_resume",
    "evaluate_scope",
    "validate_proxy",
    "select_proxy",
    "select_versions",
    "livelink_handshake",
    "livelink_scope",
    "retry_delay",
    "store_save",
    "store_load",
    "migrate_legacy",
    "log_event",
    "capabilities",
)
_ACTION_SET = frozenset(ACTIONS)

MEDIA_KINDS = ("photo", "video", "live_photo", "motion_photo")

# Resource roles inside one media item (a Live Photo / Motion Photo pair is
# one item made of a photo resource and a video resource).
RESOURCE_ROLES = ("photo", "video")

# Capabilities a LiveLink peer must announce at /v1/hello (paired-backup
# scope doc): scope2 (structured backup scope) and catalog2 (album catalog).
LIVELINK_REQUIRED_CAPABILITIES = ("scope2", "catalog2")

# Structured-scope (scope2) bounds, mirroring LiveLinkScopeRules.parse:
# minImageKb must lie in 10..1024.
SCOPE_MIN_IMAGE_KB = 10
SCOPE_MAX_IMAGE_KB = 1024
SCOPE_MODES = ("default", "all", "date", "advanced")

# Cleanup-guidance evidence is fresh for one hour (same bound as the
# protocol snapshot freshness window used by Protocol.check_cleanup).
CLEANUP_EVIDENCE_MAX_AGE_SECONDS = 3600

RETRY_BASE_SECONDS = 5
RETRY_MAX_SECONDS = 300

STORE_VERSION = 1

# Legal state edges. Happy path:
# queued -> preparing -> uploading -> submitting -> confirming -> done.
# Any running state may go to paused / cancelled / failed; failed and
# interrupted may return to queued for retry; done and cancelled are terminal.
_ALLOWED = {
    "queued": {"preparing", "paused", "cancelled", "failed", "waiting_network"},
    "preparing": {"uploading", "dedup_hit", "paused", "cancelled", "failed",
                  "waiting_network", "interrupted"},
    "dedup_hit": {"done", "paused", "cancelled", "failed"},
    "uploading": {"submitting", "paused", "cancelled", "failed",
                  "waiting_network", "interrupted"},
    "submitting": {"confirming", "paused", "cancelled", "failed",
                   "waiting_network", "interrupted"},
    "confirming": {"done", "waiting_confirmation", "paused", "cancelled",
                   "failed", "waiting_network", "interrupted"},
    "waiting_network": {"queued", "preparing", "uploading", "paused",
                        "cancelled", "failed", "interrupted"},
    "waiting_confirmation": {"confirming", "done", "paused", "cancelled",
                             "failed", "interrupted"},
    "paused": {"queued", "cancelled", "failed"},
    "failed": {"queued", "cancelled"},
    "interrupted": {"queued", "cancelled", "failed"},
    "done": set(),
    "cancelled": set(),
}

# Legacy task states (pre-unification records) -> current states.
_LEGACY_STATES = {
    "confirmed": "done",
    "confirmation_pending": "waiting_confirmation",
    "uploading": "interrupted",
    "interrupted": "interrupted",
}

_SHA1_RE = re.compile(r"[0-9a-f]{40}")
_SHA256_RE = re.compile(r"[0-9a-f]{64}")

# Keys whose values must never reach a log. Substring match, case-insensitive,
# per the Android diagnostics design: secrets are dropped before persistence,
# never stored in plaintext and redacted at export.
_REDACTED_SUBSTRINGS = ("token", "password", "auth", "credential",
                        "account_id", "secret")
# Content-hash keys: hashes are never written to logs (charter redaction
# ruling on conflict C6, coordinator decision 2026-11-13).
_SHA_SUBSTRINGS = ("sha1", "sha256")
# Keys whose values are file names / paths: basename only, never full paths.
_FILENAME_KEYS = frozenset({"filename", "file_name"})
# Keys whose values are media bodies, never log payloads.
_MEDIA_BODY_KEYS = frozenset({"media_body", "media_bytes"})
REDACTED = "[redacted]"


def _now_iso():
    return datetime.now(UTC).isoformat()


def _error(code):
    return {"ok": False, "error": code}


def _validate_digest(asset):
    """Same digest boundary as Protocol.digest; raises _Failure(INVALID_DIGEST)."""
    sha1 = asset.get("sha1", "")
    sha256 = asset.get("sha256", "")
    size = asset.get("size", 0)
    if (not isinstance(sha1, str) or not _SHA1_RE.fullmatch(sha1)
            or not isinstance(sha256, str) or not _SHA256_RE.fullmatch(sha256)
            or type(size) is not int or size <= 0):
        raise _Failure("INVALID_DIGEST")


def _validate_resource(resource):
    """Validate one resource of a multi-resource media item.

    A resource is ``{role: photo|video, digest?, sha1?, sha256?,
    size_bytes?, filename?}``. ``digest`` is a single 40- or 64-hex
    content hash; ``sha1`` / ``sha256`` are the same boundary as
    :func:`_validate_digest`. Returns a normalised copy.
    Raises ``_Failure`` (``INVALID_ARGUMENT`` / ``INVALID_DIGEST``).
    """
    if not isinstance(resource, dict):
        raise _Failure("INVALID_ARGUMENT")
    role = resource.get("role")
    if role not in RESOURCE_ROLES:
        raise _Failure("INVALID_ARGUMENT")
    clean = {"role": role}
    for key in ("sha1", "sha256"):
        value = resource.get(key)
        if value is not None:
            pattern = _SHA1_RE if key == "sha1" else _SHA256_RE
            if not isinstance(value, str) or not pattern.fullmatch(value):
                raise _Failure("INVALID_DIGEST")
            clean[key] = value
    digest = resource.get("digest")
    if digest is not None:
        if (not isinstance(digest, str)
                or not (_SHA1_RE.fullmatch(digest)
                        or _SHA256_RE.fullmatch(digest))):
            raise _Failure("INVALID_DIGEST")
        clean["digest"] = digest
    size = resource.get("size_bytes", resource.get("size"))
    if size is not None:
        if type(size) is not int or size <= 0:
            raise _Failure("INVALID_ARGUMENT")
        clean["size_bytes"] = size
    filename = resource.get("filename")
    if filename is not None:
        if not isinstance(filename, str) or not filename:
            raise _Failure("INVALID_ARGUMENT")
        clean["filename"] = filename
    return clean


def _validate_resources(resources):
    if not isinstance(resources, list) or not resources:
        raise _Failure("INVALID_ARGUMENT")
    seen = set()
    clean = []
    for resource in resources:
        item = _validate_resource(resource)
        if item["role"] in seen:
            raise _Failure("INVALID_ARGUMENT")
        seen.add(item["role"])
        clean.append(item)
    return clean


def _validate_asset(asset):
    if not isinstance(asset, dict):
        raise _Failure("INVALID_ARGUMENT")
    for field in ("local_id", "filename"):
        if not isinstance(asset.get(field), str) or not asset[field]:
            raise _Failure("INVALID_ARGUMENT")
    if asset.get("media_kind") not in MEDIA_KINDS:
        raise _Failure("INVALID_MEDIA_KIND")
    _validate_digest(asset)
    clean = {
        "local_id": asset["local_id"],
        "filename": asset["filename"],
        "sha1": asset["sha1"],
        "sha256": asset["sha256"],
        "size": asset["size"],
        "media_kind": asset["media_kind"],
        "created_at": asset.get("created_at") or _now_iso(),
    }
    duration = asset.get("duration_seconds")
    if duration is not None:
        if (type(duration) is bool
                or not isinstance(duration, (int, float)) or duration < 0):
            raise _Failure("INVALID_ARGUMENT")
        clean["duration_seconds"] = duration
    if asset.get("resources") is not None:
        clean["resources"] = _validate_resources(asset["resources"])
    if isinstance(asset.get("scope"), dict):
        clean["scope"] = asset["scope"]
    return clean


def create_task(task_id, asset, idempotency_key=None):
    """Create a new task in ``queued`` state.

    Returns ``{"task": {...}}`` or ``{"ok": False, "error": CODE}``.
    """
    if not isinstance(task_id, str) or not task_id:
        return _error("INVALID_ARGUMENT")
    if idempotency_key is not None and not isinstance(idempotency_key, str):
        return _error("INVALID_ARGUMENT")
    try:
        clean_asset = _validate_asset(asset)
    except _Failure as exc:
        return _error(str(exc))
    now = _now_iso()
    task = {
        "task_id": task_id,
        "asset": clean_asset,
        "state": "queued",
        "revision": 0,
        "error_code": None,
        "attempts": 0,
        "idempotency_key": idempotency_key,
        "remote_key": None,
        "cloud_confirmed": False,
        "created_at": now,
        "updated_at": now,
        "history": [{"state": "queued", "at": now, "event": "created"}],
    }
    return {"task": task}


def transition(task, to_state, event="transition", error_code=None,
               remote_key=None, cloud_confirmed=None, idempotency_key=None):
    """Move a task to ``to_state`` if the edge is legal.

    Idempotent: if the task is already in ``to_state``, the stored task is
    returned unchanged -- attempts are not counted again, no history entry
    is appended, and no duplicate submit marker is produced (submission is
    derived from history, so a repeated ``submitting`` transition adds no
    second marker). Returns ``{"task": {...}}`` (with
    ``"idempotent_replay": True`` on a no-op replay) or
    ``{"ok": False, "error": "INVALID_TRANSITION" | "INVALID_TASK"}``.

    ``attempts`` counts upload attempts: it increments only on
    ``queued -> preparing`` (the start of an attempt). Retrying from
    ``failed`` / ``interrupted`` / ``waiting_network`` back to ``queued``
    clears ``error_code``; the next ``queued -> preparing`` counts the new
    attempt. Entering ``done`` sets ``cloud_confirmed`` to True.
    """
    if not isinstance(task, dict) or not isinstance(task.get("task_id"), str):
        return _error("INVALID_TASK")
    current = task.get("state")
    if current not in _STATE_SET:
        return _error("INVALID_TASK")
    if not isinstance(to_state, str) or to_state not in _STATE_SET:
        return _error("INVALID_TRANSITION")
    if current == to_state:
        # Replay of an already-applied transition: no-op success.
        return {"task": task, "idempotent_replay": True}
    if to_state not in _ALLOWED[current]:
        return _error("INVALID_TRANSITION")
    if error_code is not None and not isinstance(error_code, str):
        return _error("INVALID_ARGUMENT")
    if remote_key is not None and not isinstance(remote_key, str):
        return _error("INVALID_ARGUMENT")
    if cloud_confirmed is not None and type(cloud_confirmed) is not bool:
        return _error("INVALID_ARGUMENT")
    if to_state == "done" and cloud_confirmed is not True and task.get("cloud_confirmed") is not True:
        return _error("CLOUD_CONFIRMATION_REQUIRED")

    updated = dict(task)
    updated["history"] = [dict(entry) for entry in task.get("history", [])]
    updated["asset"] = dict(task.get("asset", {}))
    now = _now_iso()
    updated["revision"] = task.get("revision", 0) + 1
    updated["state"] = to_state
    updated["updated_at"] = now
    updated["history"].append({"state": to_state, "at": now, "event": event})
    if to_state == "preparing" and current == "queued":
        updated["attempts"] = task.get("attempts", 0) + 1
    if current in ("failed", "interrupted", "waiting_network") and to_state == "queued":
        updated["error_code"] = None
    if error_code is not None:
        updated["error_code"] = error_code
    if remote_key is not None:
        updated["remote_key"] = remote_key
    if to_state == "done":
        updated["cloud_confirmed"] = True
    elif cloud_confirmed is not None:
        updated["cloud_confirmed"] = cloud_confirmed
    if idempotency_key is not None:
        updated["idempotency_key"] = idempotency_key
    return {"task": updated}


def _resource_remote_key(resource, remote_keys):
    """Look up a resource's remote key from a caller-supplied mapping.

    ``remote_keys`` may be a dict keyed by role (``"photo"`` / ``"video"``)
    or by content hash (``digest`` / ``sha1`` / ``sha256``), or a list
    aligned with the asset's ``resources`` order (the caller passes the
    list position when it builds the call). Returns the remote key string
    or ``None``.
    """
    if isinstance(remote_keys, dict):
        for key in (resource.get("role"), resource.get("digest"),
                    resource.get("sha1"), resource.get("sha256")):
            if key is not None and isinstance(remote_keys.get(key), str):
                return remote_keys[key]
        return None
    if isinstance(remote_keys, list):
        return None  # Positional lookup needs the index; handled by caller.
    return None


def decide_prepare(asset, remote_key=None, remote_keys=None, scope=None):
    """Dedup decision for an asset, before any upload work.

    Validates sha1 (40 hex) / sha256 (64 hex) / size > 0, the same boundary
    as :meth:`gpmc.protocol.Protocol.digest`. Returns
    ``{"exists": True, "remote_key": ...}`` when the remote already holds
    the asset, otherwise ``{"exists": False}``. Invalid digests return
    ``{"ok": False, "error": "INVALID_DIGEST"}``. No network is performed
    here: the caller supplies ``remote_key`` from a prior
    ``Protocol.prepare_upload`` / hash lookup.

    Extended (unification phase 2), backwards compatible:

    * ``asset["media_kind"]`` may be ``photo`` / ``video`` /
      ``live_photo`` / ``motion_photo``; when present it must be one of
      these (``INVALID_MEDIA_KIND`` otherwise). Absent ``media_kind``
      still means a plain photo asset, as before.
    * ``asset["duration_seconds"]`` (video / live-photo / motion-photo
      length, >= 0) is validated when present.
    * ``asset["resources"]`` lists the parts of one media item -- a Live
      Photo / Motion Photo pair is one item with a ``photo`` resource and
      a ``video`` resource. Each resource is
      ``{role: photo|video, digest?, sha1?, sha256?, size_bytes?,
      filename?}``. The result then carries a per-resource decision list
      ``"resources": [{role, filename?, exists, remote_key?}]`` and the
      top-level ``"exists"`` is True only when *every* resource already
      exists remotely. ``remote_keys`` supplies per-resource remote keys
      (dict keyed by role or by hash, or a list aligned with
      ``resources``); a single ``remote_key`` still applies to the whole
      asset when no ``resources`` are given.
    * ``scope`` (argument, or ``asset["scope"]``) is evaluated with the
      same semantics as :func:`evaluate_scope`; the result adds
      ``"in_scope"`` / ``"scope_reason"``. Scope only annotates the
      decision -- it never changes the dedup outcome. An invalid scope
      returns ``{"ok": False, "error": "INVALID_SCOPE"}``.
    """
    if remote_key is not None and (not isinstance(remote_key, str) or not remote_key):
        return _error("INVALID_ARGUMENT")
    if not isinstance(asset, dict):
        return _error("INVALID_ARGUMENT")
    try:
        _validate_digest(asset)
    except _Failure as exc:
        return _error(str(exc))
    if asset.get("media_kind") is not None and asset.get("media_kind") not in MEDIA_KINDS:
        return _error("INVALID_MEDIA_KIND")
    duration = asset.get("duration_seconds")
    if (duration is not None
            and (type(duration) is bool
                 or not isinstance(duration, (int, float)) or duration < 0)):
        return _error("INVALID_ARGUMENT")
    resources = asset.get("resources")
    clean_resources = None
    if resources is not None:
        if remote_key is not None:
            # Ambiguous: a single whole-asset key cannot say which
            # resource it belongs to; use remote_keys instead.
            return _error("INVALID_ARGUMENT")
        try:
            clean_resources = _validate_resources(resources)
        except _Failure as exc:
            return _error(str(exc))
        if isinstance(remote_keys, list):
            if len(remote_keys) != len(clean_resources):
                return _error("INVALID_ARGUMENT")
            for item, key in zip(clean_resources, remote_keys):
                if key is not None and (not isinstance(key, str) or not key):
                    return _error("INVALID_ARGUMENT")
    elif remote_keys is not None:
        return _error("INVALID_ARGUMENT")

    result = {}
    if clean_resources is None:
        if remote_key:
            result = {"exists": True, "remote_key": remote_key}
        else:
            result = {"exists": False}
    else:
        decisions = []
        all_exist = True
        for index, resource in enumerate(clean_resources):
            key = None
            if isinstance(remote_keys, list):
                key = remote_keys[index]
            else:
                key = _resource_remote_key(resource, remote_keys)
            entry = {"role": resource["role"], "exists": bool(key)}
            if resource.get("filename"):
                entry["filename"] = resource["filename"]
            if key:
                entry["remote_key"] = key
            else:
                all_exist = False
            decisions.append(entry)
        result = {"exists": all_exist, "resources": decisions}

    scope_value = scope if scope is not None else asset.get("scope")
    if scope_value is not None:
        scoped = _evaluate_scope(scope_value, asset)
        if isinstance(scoped, dict) and scoped.get("ok") is False:
            return scoped
        result["in_scope"] = scoped["in_scope"]
        result["scope_reason"] = scoped["reason"]
    return result


def _parse_scope_date(value):
    """Strict ``yyyy-MM-dd`` parse (mirrors LiveLinkScopeRules.formatter:
    Gregorian, en_US_POSIX, non-lenient). Returns a ``date`` or ``None``."""
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.strptime(value, "%Y-%m-%d")
    except ValueError:
        return None
    if parsed.strftime("%Y-%m-%d") != value:
        return None
    return parsed.date()


def _asset_date(asset):
    """The asset's creation date as a ``date``, or ``None`` when unknown
    or unparseable. Accepts an ISO-8601 / ``yyyy-MM-dd`` string or epoch
    seconds under ``created_at`` (falling back to ``date`` /
    ``creation_date``)."""
    for field in ("created_at", "date", "creation_date"):
        value = asset.get(field)
        if value is None:
            continue
        if type(value) in (int, float):
            try:
                return datetime.fromtimestamp(value, tz=UTC).date()
            except (OverflowError, OSError, ValueError):
                return None
        if isinstance(value, str) and len(value) >= 10:
            parsed = _parse_scope_date(value[:10])
            if parsed is not None:
                return parsed
            return None
    return None


def _asset_media_side(asset):
    """Map an asset's kind to the scope type side: ``"photo"`` (photo /
    live_photo / motion_photo) or ``"video"``. Returns ``None`` when the
    kind is present but unknown."""
    kind = asset.get("media_kind", asset.get("type"))
    if kind is None:
        return "photo"
    if kind in ("photo", "live_photo", "motion_photo"):
        return "photo"
    if kind == "video":
        return "video"
    return None


def _asset_albums(asset):
    albums = asset.get("albums", asset.get("album_ids"))
    if isinstance(albums, list):
        return [item for item in albums if isinstance(item, str)]
    single = asset.get("album_id")
    return [single] if isinstance(single, str) else []


def _normalize_scope(scope):
    """Normalise a scope to the scope2 dict form.

    Accepts the wire strings (``"all"`` / ``"library"`` / ``"selected"``,
    ``"range:<from>:<to>"``, ``"scope2:<json>"``) and dicts using either
    the scope2 camelCase names or the snake_case names
    (``date_from`` / ``date_to`` / ``min_image_kb`` /
    ``ignore_small_images`` / ``date_enabled`` / ``filter_cache`` /
    ``types``). Returns ``(scope_dict, None)`` or
    ``(None, {"ok": False, "error": "INVALID_SCOPE"})``.

    Unknown versions never fall back to full scope: a ``scope<N>:``
    prefix with N != 2, a dict ``"version"`` other than 2, or an unknown
    ``mode`` all return ``INVALID_SCOPE``.
    """
    if isinstance(scope, str):
        if scope.startswith("scope2:"):
            try:
                parsed = json.loads(scope[len("scope2:"):])
            except ValueError:
                return None, _error("INVALID_SCOPE")
            if not isinstance(parsed, dict):
                return None, _error("INVALID_SCOPE")
            scope = parsed
        elif scope.startswith("scope"):
            # scope3:, scope1:, ... -- unknown structured-scope version.
            return None, _error("INVALID_SCOPE")
        elif scope.startswith("range:"):
            parts = scope.split(":")
            if len(parts) != 3:
                return None, _error("INVALID_SCOPE")
            scope = {"mode": "date", "dateEnabled": True,
                     "from": parts[1], "to": parts[2]}
        elif scope in ("all", "library", "selected"):
            # Mirrors LiveLinkScopeRules.parse: these wire values pass
            # validation without setting a mode, i.e. full-library scope.
            scope = {"mode": "all"}
        else:
            return None, _error("INVALID_SCOPE")
    if not isinstance(scope, dict):
        return None, _error("INVALID_SCOPE")
    if scope.get("version") is not None and scope.get("version") != 2:
        return None, _error("INVALID_SCOPE")
    value = dict(scope)
    for snake, camel in (("date_from", "from"), ("date_to", "to"),
                         ("min_image_kb", "minImageKb"),
                         ("ignore_small_images", "ignoreSmallImages"),
                         ("date_enabled", "dateEnabled"),
                         ("filter_cache", "filterCache")):
        if snake in value and camel not in value:
            value[camel] = value[snake]
    types = value.get("types")
    if types is not None:
        if (not isinstance(types, list)
                or any(item not in ("photo", "video", "live_photo",
                                   "motion_photo") for item in types)):
            return None, _error("INVALID_SCOPE")
        if "photos" not in value:
            value["photos"] = any(item in ("photo", "live_photo",
                                           "motion_photo") for item in types)
        if "videos" not in value:
            value["videos"] = "video" in types
    value.setdefault("mode", "all")
    value.setdefault("photos", True)
    value.setdefault("videos", True)
    value.setdefault("albums", [])
    value.setdefault("dateEnabled", False)
    value.setdefault("ignoreSmallImages", False)
    value.setdefault("minImageKb", 100)
    value.setdefault("filterCache", False)
    if value["mode"] not in SCOPE_MODES:
        return None, _error("INVALID_SCOPE")
    if type(value["photos"]) is not bool or type(value["videos"]) is not bool:
        return None, _error("INVALID_SCOPE")
    if not value["photos"] and not value["videos"]:
        return None, _error("INVALID_SCOPE")
    if (not isinstance(value["albums"], list)
            or any(not isinstance(item, str) for item in value["albums"])):
        return None, _error("INVALID_SCOPE")
    if value["mode"] == "advanced" and not value["albums"]:
        return None, _error("INVALID_SCOPE")
    if (type(value["minImageKb"]) is not int
            or not SCOPE_MIN_IMAGE_KB <= value["minImageKb"] <= SCOPE_MAX_IMAGE_KB):
        return None, _error("INVALID_SCOPE")
    if type(value["dateEnabled"]) is not bool:
        return None, _error("INVALID_SCOPE")
    if type(value["ignoreSmallImages"]) is not bool:
        return None, _error("INVALID_SCOPE")
    if type(value["filterCache"]) is not bool:
        return None, _error("INVALID_SCOPE")
    if value["dateEnabled"]:
        start = _parse_scope_date(value.get("from"))
        end = _parse_scope_date(value.get("to"))
        if ((value.get("from") not in (None, "") and start is None)
                or (value.get("to") not in (None, "") and end is None)):
            return None, _error("INVALID_SCOPE")
        if start is not None and end is not None and start > end:
            return None, _error("INVALID_SCOPE")
    return value, None


def _evaluate_scope(scope, asset):
    """Shared scope evaluation used by :func:`evaluate_scope`,
    :func:`decide_prepare` and :func:`livelink_scope`."""
    if not isinstance(asset, dict):
        return _error("INVALID_ARGUMENT")
    normalized, error = _normalize_scope(scope)
    if error is not None:
        return error
    side = _asset_media_side(asset)
    if side is None:
        return _error("INVALID_MEDIA_KIND")
    if side == "photo" and not normalized["photos"]:
        return {"in_scope": False, "reason": "TYPE_EXCLUDED"}
    if side == "video" and not normalized["videos"]:
        return {"in_scope": False, "reason": "TYPE_EXCLUDED"}
    mode = normalized["mode"]
    albums = _asset_albums(asset)
    if mode == "advanced":
        if not set(albums) & set(normalized["albums"]):
            return {"in_scope": False, "reason": "ALBUM_NOT_SELECTED"}
    elif mode == "default":
        defaults = normalized.get("default_albums")
        if isinstance(defaults, list) and defaults:
            if not set(albums) & set(defaults):
                return {"in_scope": False, "reason": "ALBUM_NOT_SELECTED"}
        elif asset.get("in_default_album") is False:
            return {"in_scope": False, "reason": "ALBUM_NOT_SELECTED"}
    if normalized["dateEnabled"]:
        taken = _asset_date(asset)
        if taken is None:
            return {"in_scope": False, "reason": "DATE_UNKNOWN"}
        start = _parse_scope_date(normalized.get("from"))
        end = _parse_scope_date(normalized.get("to"))
        if start is not None and taken < start:
            return {"in_scope": False, "reason": "DATE_OUT_OF_RANGE"}
        if end is not None and taken > end:
            return {"in_scope": False, "reason": "DATE_OUT_OF_RANGE"}
    if normalized["ignoreSmallImages"]:
        # Mirrors LiveLinkScope.select: only plain still images, never
        # Live / Motion Photo parts and never video; an asset whose size
        # is unknown stays included.
        size = asset.get("size_bytes", asset.get("size"))
        kind = asset.get("media_kind", asset.get("type"))
        if kind in (None, "photo") and type(size) is int:
            if size < normalized["minImageKb"] * 1024:
                return {"in_scope": False, "reason": "SMALL_IMAGE"}
    if normalized["filterCache"] and asset.get("cached") is True:
        return {"in_scope": False, "reason": "FILTERED_CACHE"}
    return {"in_scope": True, "reason": "IN_SCOPE"}


def evaluate_scope(scope, asset):
    """Judge whether one asset falls inside a backup scope.

    ``scope`` is a scope2 dict (camelCase or snake_case names), or one of
    the wire strings ``"all"`` / ``"library"`` / ``"selected"``,
    ``"range:<from>:<to>"`` or ``"scope2:<json>"`` (see
    ``docs/HARBOR-CORE.md`` §6). ``asset`` carries ``media_kind`` /
    ``type``, ``created_at`` (ISO / ``yyyy-MM-dd`` / epoch), ``size`` /
    ``size_bytes`` and ``albums`` / ``album_ids`` / ``album_id``.

    Returns ``{"in_scope": bool, "reason": str}``; ``reason`` is
    ``IN_SCOPE`` on success, otherwise ``ALBUM_NOT_SELECTED``,
    ``DATE_OUT_OF_RANGE``, ``DATE_UNKNOWN``, ``TYPE_EXCLUDED``,
    ``SMALL_IMAGE`` or ``FILTERED_CACHE``. An unknown scope version,
    unknown mode, or out-of-range ``minImageKb`` (10..1024) returns
    ``{"ok": False, "error": "INVALID_SCOPE"}`` -- never a fallback to
    full scope. No network is performed.
    """
    return _evaluate_scope(scope, asset)


def decide_cleanup(task, evidence):
    """Decide whether cloud-confirmation evidence is sufficient to guide the
    user to Google Photos' official "free up space".

    .. warning::
        This is **not** a decision to delete a local original, and this
        module performs no deletion of any kind. Per PicHarbor-iOS
        ``docs/REQUIREMENTS.md`` (2026-10-19 scope revision) and Yuto's
        2026-11-13 decision, local cleanup is handed to Google Photos'
        official free-up-space feature; PicHarbor's own local cleanup is
        cancelled. ``{"eligible": True}`` only means the cloud original is
        confirmed with fresh evidence, so the client may show the official
        cleanup guidance / deep link. The client must never treat it as
        permission for PicHarbor to scan or delete local assets.

    ``evidence`` must contain ``cloud_state`` and ``checked_at`` (epoch
    seconds) no older than 3600 seconds; missing or stale evidence returns
    ``{"eligible": False, "reason": "CLOUD_STATE_EXPIRED"}`` -- evidence
    problems deny guidance, they never grant it, and they are reported
    before any policy error. ``policy`` (whether showing official-cleanup
    guidance is allowed for this task/account) must be a bool, taken from
    ``evidence["policy"]`` or the caller's ``policy`` argument; once the
    evidence is fresh, a missing or non-bool policy returns
    ``{"ok": False, "error": "INVALID_CHECK_POLICY"}``. Only
    ``cloud_state == "confirmed_original"`` with policy allowed returns
    ``{"eligible": True}``; anything else returns
    ``{"eligible": False, "reason": CODE}``.

    Per-item evidence (unification phase 2): ``evidence`` may instead
    carry ``"items": [{task_id, cloud_confirmed, confirmed_at,
    evidence_fresh_seconds?}]``. Each item is judged on its own
    evidence and the result carries ``"items": [{task_id, eligible,
    reason?}]``; the page-level ``eligible`` is True only when every
    item is eligible and the policy allows guidance. Items with missing,
    stale or unconfirmed evidence are never passed, and no evidence is
    ever fabricated. See :func:`_decide_cleanup_items`.
    """
    return _decide_cleanup(task, evidence, None)


def _decide_cleanup_items(evidence, policy):
    """Per-item cleanup-guidance decision.

    ``evidence["items"]`` is a list of
    ``{task_id, cloud_confirmed, confirmed_at,
    evidence_fresh_seconds?}``. Each item is judged on its own evidence:
    missing or stale ``confirmed_at`` (older than
    ``evidence_fresh_seconds``, default 3600 s, or from the future)
    denies with ``CLOUD_STATE_EXPIRED``; ``cloud_confirmed`` not True
    denies with ``CLOUD_ORIGINAL_UNCONFIRMED``. Evidence problems deny,
    they never grant, and no evidence is ever fabricated: an item with
    no usable evidence is reported ineligible, never assumed confirmed.

    The page-level ``eligible`` is True only when every item is eligible
    and the page policy allows guidance; the page ``reason`` is the first
    failing item's reason (or ``CLEANUP_GUIDANCE_DENIED`` when the
    policy denies). Returns ``{"eligible": bool, "items": [...]}`` with
    ``"reason"`` present only when ``eligible`` is False.
    """
    items = evidence["items"]
    if not isinstance(items, list):
        return _error("INVALID_ARGUMENT")
    now = time.time()
    judged = []
    first_reason = None
    for item in items:
        if not isinstance(item, dict) or not isinstance(item.get("task_id"), str):
            return _error("INVALID_ARGUMENT")
        checked_at = item.get("confirmed_at")
        window = item.get("evidence_fresh_seconds")
        if type(window) is not int or window <= 0:
            window = CLEANUP_EVIDENCE_MAX_AGE_SECONDS
        if type(checked_at) not in (int, float) or checked_at <= 0:
            entry = {"task_id": item["task_id"], "eligible": False,
                     "reason": "CLOUD_STATE_EXPIRED"}
        else:
            age = now - checked_at
            if age < 0 or age > window:
                entry = {"task_id": item["task_id"], "eligible": False,
                         "reason": "CLOUD_STATE_EXPIRED"}
            elif item.get("cloud_confirmed") is not True:
                entry = {"task_id": item["task_id"], "eligible": False,
                         "reason": "CLOUD_ORIGINAL_UNCONFIRMED"}
            else:
                entry = {"task_id": item["task_id"], "eligible": True}
        if not entry["eligible"] and first_reason is None:
            first_reason = entry["reason"]
        judged.append(entry)
    if not judged:
        return {"eligible": False, "reason": "CLOUD_STATE_EXPIRED", "items": []}
    if first_reason is not None:
        return {"eligible": False, "reason": first_reason, "items": judged}
    # All items have fresh, confirming evidence; only now is policy judged.
    if policy is None:
        policy = evidence.get("policy")
    if type(policy) is not bool:
        return _error("INVALID_CHECK_POLICY")
    if not policy:
        denied = [{"task_id": entry["task_id"], "eligible": False,
                   "reason": "CLEANUP_GUIDANCE_DENIED"} for entry in judged]
        return {"eligible": False, "reason": "CLEANUP_GUIDANCE_DENIED",
                "items": denied}
    return {"eligible": True, "items": judged}


def _decide_cleanup(task, evidence, policy):
    if isinstance(evidence, dict) and "items" in evidence:
        # Per-item evidence mode: the page task is optional here -- each
        # item carries its own task_id. A supplied task must still be a
        # well-formed task dict.
        if task is not None and (not isinstance(task, dict)
                                 or not isinstance(task.get("task_id"), str)):
            return _error("INVALID_TASK")
        return _decide_cleanup_items(evidence, policy)
    if not isinstance(task, dict) or not isinstance(task.get("task_id"), str):
        return _error("INVALID_TASK")
    if not isinstance(evidence, dict):
        return _error("INVALID_ARGUMENT")
    cloud_state = evidence.get("cloud_state")
    checked_at = evidence.get("checked_at")
    if (not isinstance(cloud_state, str)
            or type(checked_at) not in (int, float)
            or checked_at <= 0):
        return {"eligible": False, "reason": "CLOUD_STATE_EXPIRED"}
    age = time.time() - checked_at
    if age < 0 or age > CLEANUP_EVIDENCE_MAX_AGE_SECONDS:
        return {"eligible": False, "reason": "CLOUD_STATE_EXPIRED"}
    # Evidence is fresh; only now is the caller's policy input judged.
    if policy is None:
        policy = evidence.get("policy")
    if type(policy) is not bool:
        return _error("INVALID_CHECK_POLICY")
    if cloud_state == "confirmed_original":
        if policy:
            return {"eligible": True}
        return {"eligible": False, "reason": "CLEANUP_GUIDANCE_DENIED"}
    if cloud_state in ("missing", "not_found"):
        return {"eligible": False, "reason": "REMOTE_MISSING"}
    if cloud_state == "original_unavailable":
        return {"eligible": False, "reason": "ORIGINAL_UNAVAILABLE"}
    return {"eligible": False, "reason": "CLOUD_ORIGINAL_UNCONFIRMED"}


def _batch_transition(task_ids, tasks, to_state, event, allowed_from=None):
    """Shared batch driver for :func:`batch_pause` / :func:`batch_resume`.

    Each task is moved with :func:`transition`, so the same edge rules,
    idempotency (already in ``to_state`` counts as success) and history
    handling apply. ``allowed_from`` further restricts the source states
    (used by resume, which only accepts ``paused`` / ``interrupted``
    even though the state machine also allows ``failed -> queued``).
    One task failing never interrupts the batch; the result lists a
    per-task entry for every requested id, in request order (duplicate
    ids are folded to their first occurrence).
    """
    if (not isinstance(task_ids, list)
            or any(not isinstance(item, str) for item in task_ids)
            or not isinstance(tasks, dict)):
        return _error("INVALID_ARGUMENT")
    results = []
    succeeded = 0
    seen = set()
    for task_id in task_ids:
        if task_id in seen:
            continue
        seen.add(task_id)
        task = tasks.get(task_id)
        if task is None:
            results.append({"task_id": task_id, "ok": False,
                            "error": "TASK_NOT_FOUND"})
            continue
        if (allowed_from is not None and isinstance(task, dict)
                and task.get("state") != to_state
                and task.get("state") not in allowed_from):
            results.append({"task_id": task_id, "ok": False,
                            "error": "INVALID_TRANSITION"})
            continue
        moved = transition(task, to_state, event=event)
        if isinstance(moved, dict) and moved.get("ok") is False:
            results.append({"task_id": task_id, "ok": False,
                            "error": moved["error"]})
            continue
        succeeded += 1
        results.append({"task_id": task_id, "ok": True,
                        "task": moved["task"]})
    return {"results": results, "succeeded": succeeded,
            "failed": len(results) - succeeded}


def batch_pause(task_ids, tasks):
    """Pause a batch of tasks.

    ``tasks`` is the caller's ``{task_id: task}`` map; ``task_ids`` lists
    the tasks to pause. Only states with a ``paused`` edge may pause
    (``queued``, ``preparing``, ``dedup_hit``, ``uploading``,
    ``submitting``, ``confirming``, ``waiting_network``,
    ``waiting_confirmation`` -- i.e. every running or waiting state;
    ``done`` / ``cancelled`` are terminal and ``failed`` /
    ``interrupted`` must go through ``queued`` instead). A task already
    ``paused`` counts as success (idempotent replay, as in
    :func:`transition`). Returns
    ``{"results": [{task_id, ok, task? | error?}], "succeeded": N,
    "failed": M}``; a single failure never interrupts the batch.
    Unknown ids return ``TASK_NOT_FOUND`` per task.
    """
    return _batch_transition(task_ids, tasks, "paused", "batch_pause")


def batch_resume(task_ids, tasks):
    """Resume a batch of paused / interrupted tasks back to ``queued``.

    Only ``paused`` and ``interrupted`` tasks may resume (mirroring the
    clients' ``pauseJobs`` / ``resumeJobs`` batch actions); anything
    else returns ``INVALID_TRANSITION`` for that task -- including
    ``failed``, even though the state machine allows ``failed -> queued``
    for single-task retry. A task already
    ``queued`` counts as success (idempotent replay). Returns the same
    per-task ``{"results": [...], "succeeded": N, "failed": M}`` shape
    as :func:`batch_pause`; a single failure never interrupts the batch.
    """
    return _batch_transition(task_ids, tasks, "queued", "batch_resume",
                             {"paused", "interrupted"})


_PROXY_TLS_FLAGS = ("verify_tls", "tls_verify", "verify_ssl", "verify")


def validate_proxy(proxy=None):
    """Validate an explicit proxy configuration. No network is performed
    and no credential is stored, logged or echoed back.

    The proxy is off by default: ``proxy`` absent / ``None`` / ``{}`` /
    ``{"enabled": False}`` returns ``{"ok": True, "enabled": False}``.
    When ``enabled`` is True, ``host`` (non-empty, no URL scheme prefix)
    and ``port`` (integer 1..65535) are required, ``scheme`` (default
    ``"http"``) must be ``http`` or ``https``, and TLS verification must
    stay on -- any of ``verify_tls`` / ``tls_verify`` / ``verify_ssl`` /
    ``verify`` set to ``False``, or ``insecure`` set to ``True``,
    returns ``{"ok": False, "error":
    "PROXY_TLS_VERIFICATION_DISABLED"}``. Malformed configuration
    returns ``{"ok": False, "error": "INVALID_PROXY"}``. An ``auth``
    block, when present, must be a dict of strings; its values are
    validated for type only and never appear in the result.
    """
    if proxy is None:
        return {"ok": True, "enabled": False}
    if not isinstance(proxy, dict):
        return _error("INVALID_ARGUMENT")
    enabled = proxy.get("enabled", False)
    if type(enabled) is not bool:
        return _error("INVALID_PROXY")
    if not enabled:
        return {"ok": True, "enabled": False}
    host = proxy.get("host")
    if (not isinstance(host, str) or not host.strip()
            or "://" in host or any(ch.isspace() for ch in host)):
        return _error("INVALID_PROXY")
    port = proxy.get("port")
    if type(port) is not int or not 1 <= port <= 65535:
        return _error("INVALID_PROXY")
    scheme = proxy.get("scheme", "http")
    if scheme not in ("http", "https"):
        return _error("INVALID_PROXY")
    for flag in _PROXY_TLS_FLAGS:
        if flag not in proxy:
            continue
        flag_value = proxy[flag]
        if flag_value is False:
            return _error("PROXY_TLS_VERIFICATION_DISABLED")
        if flag_value is True or (isinstance(flag_value, str) and flag_value):
            continue  # Verification on (a string is a custom CA bundle).
        return _error("INVALID_PROXY")
    if proxy.get("insecure") is True:
        return _error("PROXY_TLS_VERIFICATION_DISABLED")
    if "insecure" in proxy and type(proxy["insecure"]) is not bool:
        return _error("INVALID_PROXY")
    auth = proxy.get("auth")
    if auth is not None:
        if not isinstance(auth, dict):
            return _error("INVALID_PROXY")
        if any(not isinstance(value, str) for value in auth.values()):
            return _error("INVALID_PROXY")
    return {"ok": True, "enabled": True, "scheme": scheme,
            "host": host, "port": port}


def livelink_handshake(capabilities=None):
    """Validate a LiveLink peer's capability announcement (/v1/hello).

    The peer must announce both ``scope2`` and ``catalog2``; anything
    less is not a usable paired-backup peer. ``capabilities`` may be a
    list of names or a ``{name: bool}`` dict. Returns
    ``{"ok": True, "missing": [], "capabilities": [...]}`` on success,
    or ``{"ok": False, "error": "MISSING_CAPABILITIES",
    "missing": [...]}`` listing the capabilities the peer did not
    announce. No network is performed.
    """
    if isinstance(capabilities, dict):
        announced = {name for name, value in capabilities.items()
                     if value is True and isinstance(name, str)}
    elif isinstance(capabilities, (list, tuple, set)):
        if any(not isinstance(item, str) for item in capabilities):
            return _error("INVALID_ARGUMENT")
        announced = set(capabilities)
    elif capabilities is None:
        announced = set()
    else:
        return _error("INVALID_ARGUMENT")
    missing = [name for name in LIVELINK_REQUIRED_CAPABILITIES
               if name not in announced]
    if missing:
        return {"ok": False, "error": "MISSING_CAPABILITIES",
                "missing": missing}
    return {"ok": True, "missing": [],
            "capabilities": sorted(announced)}


def livelink_scope(scope, asset):
    """Validate a LiveLink paired-backup scope for one asset.

    Reuses the :func:`evaluate_scope` scope2 semantics (mode, albums,
    dates, types, small-image threshold, cache filter); an invalid
    scope returns ``INVALID_SCOPE``, never a fallback to full scope.
    Every transfer still needs the receiving side's confirmation, so a
    successful result always carries ``"requires_confirmation": True``.
    Returns ``{"in_scope": bool, "reason": str,
    "requires_confirmation": true}``.
    """
    result = _evaluate_scope(scope, asset)
    if isinstance(result, dict) and result.get("ok") is False:
        return result
    return {**result, "requires_confirmation": True}


def retry_delay(attempt):
    """Exponential backoff: base 5s, doubling, capped at 300s.

    ``attempt`` is the 0-based count of failed attempts so far:
    0 -> 5s, 1 -> 10s, 2 -> 20s, 3 -> 40s, 4 -> 80s, 5 -> 160s, 6+ -> 300s.
    Returns ``{"delay_seconds": N}`` or
    ``{"ok": False, "error": "INVALID_RETRY_ATTEMPT"}``.
    """
    if type(attempt) is not int or attempt < 0:
        return _error("INVALID_RETRY_ATTEMPT")
    return {"delay_seconds": min(RETRY_BASE_SECONDS * (2 ** attempt), RETRY_MAX_SECONDS)}


def store_save(path, tasks):
    """Persist tasks atomically as JSON v1: ``{"version": 1, "tasks": {...}}``.

    Writes a temporary file in the same directory and replaces the target
    with :func:`os.replace`, so a crash cannot leave a half-written store.
    ``tasks`` may be a ``{task_id: task}`` dict or a list of task dicts.
    Returns ``{"saved": True, "path": str, "count": N}`` or
    ``{"ok": False, "error": CODE}`` (``FILE_ACCESS`` / ``INVALID_TASK``).
    This is the only file access in the module, and only at the given path.
    """
    if isinstance(tasks, list):
        normalized = {}
        for item in tasks:
            if not isinstance(item, dict) or not isinstance(item.get("task_id"), str):
                return _error("INVALID_TASK")
            normalized[item["task_id"]] = item
        tasks = normalized
    if not isinstance(tasks, dict):
        return _error("INVALID_TASK")
    for item in tasks.values():
        if (not isinstance(item, dict) or item.get("state") not in _STATE_SET
                or not isinstance(item.get("task_id"), str)):
            return _error("INVALID_TASK")
    if not isinstance(path, (str, os.PathLike)):
        return _error("INVALID_ARGUMENT")
    payload = {"version": STORE_VERSION, "tasks": tasks}
    try:
        directory = Path(path).resolve().parent
        fd, tmp_name = tempfile.mkstemp(prefix=".harbor-store-", dir=directory)
        tmp_path = Path(tmp_name)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(payload, handle, ensure_ascii=False)
                handle.flush()
                os.fsync(handle.fileno())
            tmp_path.replace(path)
        except BaseException:
            with suppress(OSError):
                tmp_path.unlink()
            raise
    except OSError:
        return _error("FILE_ACCESS")
    return {"saved": True, "path": str(path), "count": len(tasks)}


def store_load(path):
    """Load a JSON v1 store written by :func:`store_save`.

    Returns ``{"tasks": {...}}`` or ``{"ok": False, "error": CODE}``
    (``FILE_ACCESS`` for a missing/unreadable file, ``STORE_CORRUPT`` for
    invalid JSON/structure, ``STORE_VERSION_UNSUPPORTED`` for
    ``version != 1``).
    """
    if not isinstance(path, (str, os.PathLike)):
        return _error("INVALID_ARGUMENT")
    try:
        with Path(path).open(encoding="utf-8") as handle:
            payload = json.load(handle)
    except FileNotFoundError:
        return _error("FILE_ACCESS")
    except OSError:
        return _error("FILE_ACCESS")
    except (ValueError, UnicodeDecodeError):
        return _error("STORE_CORRUPT")
    if not isinstance(payload, dict) or payload.get("version") != STORE_VERSION:
        if isinstance(payload, dict) and "version" in payload:
            return _error("STORE_VERSION_UNSUPPORTED")
        return _error("STORE_CORRUPT")
    tasks = payload.get("tasks")
    if not isinstance(tasks, dict):
        return _error("STORE_CORRUPT")
    for item in tasks.values():
        if not isinstance(item, dict) or item.get("state") not in _STATE_SET:
            return _error("STORE_CORRUPT")
    return {"tasks": tasks}


def migrate_legacy(records):
    """Migrate pre-unification task records to current task dicts.

    Mapping: ``confirmed -> done``,
    ``confirmation_pending -> waiting_confirmation``,
    ``uploading`` / ``interrupted -> interrupted``. A legacy state that is
    already a current state is kept as-is. Any other (unknown) legacy state
    becomes ``failed`` with ``error_code`` ``UNKNOWN_LEGACY_STATE``.
    Missing task fields are filled with defaults. Returns
    ``{"tasks": [...]}`` or ``{"ok": False, "error": "INVALID_ARGUMENT"}``.
    ``records`` may be a list of dicts or a ``{task_id: record}`` dict.

    Unknown fields are tolerated: they are preserved on the migrated
    task and listed in ``"unknown_fields"``, so a newer writer's extra
    data is never silently dropped. Two exceptions, both about
    credentials (which must never enter core storage or logs):

    * Any top-level key whose name carries a credential substring
      (``token`` / ``password`` / ``auth`` / ``credential`` /
      ``account_id`` / ``secret``), and any ``media_body`` /
      ``media_bytes`` key, is dropped; the dropped key names are listed
      in ``"redacted_fields"``.
    * A ``"credentials"`` block is never migrated: its body is dropped
      and the task is marked ``"credentials_migrated": False`` (the
      caller must re-establish credentials through its own secure flow;
      the core never holds them). A ``"settings"`` dict is kept, but
      with credential-bearing keys stripped the same way (the stripped
      names join ``"redacted_fields"``); non-credential settings are
      preserved as-is.
    """
    if isinstance(records, dict):
        records = list(records.values())
    if not isinstance(records, list):
        return _error("INVALID_ARGUMENT")
    migrated = []
    now = _now_iso()
    for record in records:
        if not isinstance(record, dict) or not isinstance(record.get("task_id"), str):
            return _error("INVALID_ARGUMENT")
        legacy_state = record.get("state")
        if legacy_state in _LEGACY_STATES:
            state = _LEGACY_STATES[legacy_state]
            error_code = record.get("error_code")
        elif legacy_state in _STATE_SET:
            state = legacy_state
            error_code = record.get("error_code")
        else:
            state = "failed"
            error_code = "UNKNOWN_LEGACY_STATE"
        task = {}
        unknown_fields = []
        redacted_fields = []
        for key, value in record.items():
            if key in ("state", "error_code"):
                continue
            if key == "credentials":
                # Placeholder only: mark, never migrate the body. (Checked
                # before the credential-substring rule below, which would
                # otherwise swallow this key without marking it.)
                task["credentials_migrated"] = False
                continue
            if key == "settings":
                if isinstance(value, dict):
                    kept = {}
                    for setting_key, setting_value in value.items():
                        if any(part in str(setting_key).lower()
                               for part in _REDACTED_SUBSTRINGS):
                            redacted_fields.append("settings." + str(setting_key))
                        else:
                            kept[setting_key] = setting_value
                    task["settings"] = kept
                else:
                    task["settings"] = {}
                continue
            lowered = str(key).lower()
            if (any(part in lowered for part in _REDACTED_SUBSTRINGS)
                    or lowered in _MEDIA_BODY_KEYS):
                redacted_fields.append(key)
                continue
            if key not in _KNOWN_TASK_FIELDS:
                unknown_fields.append(key)
            task[key] = value
        asset = dict(record.get("asset") or {})
        for key in list(asset.keys()):
            lowered = str(key).lower()
            if (any(part in lowered for part in _REDACTED_SUBSTRINGS)
                    or lowered in _MEDIA_BODY_KEYS):
                redacted_fields.append("asset." + str(key))
                del asset[key]
        task["asset"] = asset
        task["state"] = state
        task["error_code"] = error_code
        task.setdefault("attempts", 0)
        task.setdefault("idempotency_key", None)
        task.setdefault("remote_key", None)
        task.setdefault("cloud_confirmed", state == "done")
        task.setdefault("created_at", now)
        task.setdefault("updated_at", now)
        task.setdefault("history", [{"state": state, "at": now, "event": "migrated"}])
        if unknown_fields:
            task["unknown_fields"] = unknown_fields
        if redacted_fields:
            task["redacted_fields"] = redacted_fields
        migrated.append(task)
    return {"tasks": migrated}


# Task fields the core itself reads or writes; anything else on a legacy
# record is an unknown field (preserved, listed -- see migrate_legacy).
_KNOWN_TASK_FIELDS = frozenset({
    "task_id", "asset", "state", "error_code", "attempts",
    "idempotency_key", "remote_key", "cloud_confirmed", "created_at",
    "updated_at", "history", "settings", "credentials", "revision",
    "credentials_migrated", "unknown_fields", "redacted_fields",
})


def _basename(value):
    """Reduce a file path to its basename for logging (charter rule C6).

    Full paths are never written to logs; only the basename is kept, at most
    128 characters, with control characters replaced. Non-string values pass
    through unchanged.
    """
    if not isinstance(value, str):
        return value
    parts = [part for part in value.replace("\\", "/").split("/") if part]
    name = parts[-1] if parts else ""
    name = "".join("_" if ord(ch) < 32 or ord(ch) == 127 else ch for ch in name)
    return name[:128]


def _redact(value):
    if isinstance(value, dict):
        cleaned = {}
        for key, item in value.items():
            lowered = str(key).lower()
            if lowered in _MEDIA_BODY_KEYS:
                continue
            if (any(part in lowered for part in _REDACTED_SUBSTRINGS)
                    or any(part in lowered for part in _SHA_SUBSTRINGS)):
                cleaned[key] = REDACTED
            elif lowered in _FILENAME_KEYS or "path" in lowered:
                base = _basename(item) if isinstance(item, str) else _redact(item)
                if (isinstance(base, str)
                        and ("@" in base
                             or any(part in base.lower()
                                    for part in _REDACTED_SUBSTRINGS))):
                    # A basename carrying an email address or a secret is
                    # not a usable file name for logs.
                    cleaned[key] = REDACTED
                else:
                    cleaned[key] = base
            else:
                cleaned[key] = _redact(item)
        return cleaned
    if isinstance(value, list):
        return [_redact(item) for item in value]
    if isinstance(value, (bytes, bytearray)):
        return "[binary]"
    return value


def log_event(event):
    """Return a redacted copy of ``event`` for safe logging.

    Charter redaction rules (coordinator ruling on doc conflict C6,
    2026-11-13):

    * File names are basename only: ``filename`` / ``file_name`` / ``*path``
      values are reduced to their basename (max 128 chars, control
      characters replaced); full paths are never written. A basename
      carrying an email address or a secret-like substring is replaced
      with ``"[redacted]"`` instead.
    * Content hashes are never written: any key containing ``sha1`` /
      ``sha256`` has its value replaced with ``"[redacted]"``.
    * Any key whose name contains ``token`` / ``password`` / ``auth`` /
      ``credential`` / ``account_id`` / ``secret`` (case-insensitive) has
      its value replaced with ``"[redacted]"``; media bodies
      (``media_body`` / ``media_bytes`` keys) are dropped, and raw bytes
      become ``"[binary]"``.

    Redaction happens here, before persistence -- the caller must never log
    the unredacted event. This is the minimum floor: adapters may apply a
    stricter allowlist on top (for example also stripping cloud identifiers
    such as ``remote_key``). This function only returns the redacted event
    dict; it writes nothing and performs no I/O. Returns the redacted
    event dict, or ``{"ok": False, "error": "INVALID_ARGUMENT"}`` when the
    event is not a dict.
    """
    if not isinstance(event, dict):
        return _error("INVALID_ARGUMENT")
    return _redact(event)


def capabilities():
    """Describe this core: versions, states and actions."""
    return {
        "harbor_core_version": HARBOR_CORE_VERSION,
        "protocol_version": PROTOCOL_VERSION,
        "states": list(STATES),
        "actions": list(ACTIONS),
    }


def _dispatch_value(action, value):
    if action == "select_proxy":
        from .proxy_selection import select_proxy
        return select_proxy(value)
    if action == "select_versions":
        from .media_versions import select_versions
        return select_versions(value)
    if value is None:
        value = {}
    if not isinstance(value, dict):
        return _error("INVALID_ARGUMENT")
    if action == "create_task":
        return create_task(value.get("task_id"), value.get("asset"),
                           value.get("idempotency_key"))
    if action == "transition":
        task = value.get("task")
        to_state = value.get("to", value.get("to_state", value.get("target_state")))
        return transition(task, to_state, event=value.get("event", "transition"),
                          error_code=value.get("error_code"),
                          remote_key=value.get("remote_key"),
                          cloud_confirmed=value.get("cloud_confirmed"),
                          idempotency_key=value.get("idempotency_key"))
    if action == "decide_prepare":
        asset = value.get("asset", value)
        return decide_prepare(asset, value.get("remote_key"),
                              value.get("remote_keys"), value.get("scope"))
    if action == "decide_cleanup":
        return _decide_cleanup(value.get("task"), value.get("evidence"),
                               value.get("policy"))
    if action == "batch_pause":
        return batch_pause(value.get("task_ids"), value.get("tasks"))
    if action == "batch_resume":
        return batch_resume(value.get("task_ids"), value.get("tasks"))
    if action == "evaluate_scope":
        return evaluate_scope(value.get("scope"), value.get("asset"))
    if action == "validate_proxy":
        proxy = value.get("proxy")
        if proxy is None and any(key in value for key in
                                 ("enabled", "host", "port", "scheme", "auth")):
            proxy = value
        return validate_proxy(proxy)
    if action == "livelink_handshake":
        return livelink_handshake(value.get("capabilities"))
    if action == "livelink_scope":
        return livelink_scope(value.get("scope"), value.get("asset"))
    if action == "migrate_legacy":
        return migrate_legacy(value.get("records", value.get("tasks", [])))
    if action == "retry_delay":
        attempt = value.get("attempt", value.get("attempts"))
        return retry_delay(attempt)
    if action == "store_save":
        return store_save(value.get("path"), value.get("tasks"))
    if action == "store_load":
        return store_load(value.get("path"))
    if action == "log_event":
        event = value.get("event", value)
        redacted = log_event(event)
        if isinstance(redacted, dict) and redacted.get("ok") is False:
            return redacted
        return {"event": redacted}
    if action == "capabilities":
        return capabilities()
    return _error("UNKNOWN_OPERATION")


def dispatch(action, value):
    """Route one action: ``{"ok": True, ...}`` or ``{"ok": False, "error": CODE}``.

    ``value`` is the per-action argument dict (see ``docs/HARBOR-CORE.md``).
    Unknown actions return ``UNKNOWN_OPERATION``. Dispatch never raises an
    unclassified exception: unexpected failures are mapped through
    :func:`gpmc.errors.classify`.
    """
    try:
        if not isinstance(action, str) or action not in _ACTION_SET:
            return _error("UNKNOWN_OPERATION")
        result = _dispatch_value(action, value)
    except Exception as exc:  # Never leak an unclassified exception.
        return _error(classify(exc))
    if not isinstance(result, dict):
        return _error("ENGINE_ERROR")
    if result.get("ok") is False:
        return result
    return {"ok": True, **result}


def dispatch_json(action, payload_str):
    """JSON-string version of :func:`dispatch`, for Chaquopy / PythonBridge.

    Parses ``payload_str`` (a JSON object) and returns the result as a JSON
    string. Malformed JSON or a non-object payload returns
    ``{"ok": false, "error": "INVALID_JSON"}``.
    """
    try:
        if not isinstance(payload_str, str):
            raise ValueError("payload must be a JSON string")
        payload = json.loads(payload_str)
        if not isinstance(payload, dict):
            raise ValueError("payload must be a JSON object")
    except (ValueError, UnicodeDecodeError):
        return json.dumps({"ok": False, "error": "INVALID_JSON"},
                          ensure_ascii=False)
    return json.dumps(dispatch(action, payload), ensure_ascii=False)


class HarborCore:
    """Object-oriented facade over the module functions.

    Stateless: every method delegates to the module-level function of the
    same name, so adapters may hold an instance or call the functions
    directly -- behaviour is identical.
    """

    def dispatch(self, action, value):
        return dispatch(action, value)

    def dispatch_json(self, action, payload_str):
        return dispatch_json(action, payload_str)

    def create_task(self, task_id, asset, idempotency_key=None):
        return create_task(task_id, asset, idempotency_key)

    def transition(self, task, to_state, **kwargs):
        return transition(task, to_state, **kwargs)

    def decide_prepare(self, asset, remote_key=None, remote_keys=None,
                       scope=None):
        return decide_prepare(asset, remote_key, remote_keys, scope)

    def decide_cleanup(self, task, evidence, policy=None):
        return _decide_cleanup(task, evidence, policy)

    def batch_pause(self, task_ids, tasks):
        return batch_pause(task_ids, tasks)

    def batch_resume(self, task_ids, tasks):
        return batch_resume(task_ids, tasks)

    def evaluate_scope(self, scope, asset):
        return evaluate_scope(scope, asset)

    def validate_proxy(self, proxy=None):
        return validate_proxy(proxy)

    def livelink_handshake(self, capabilities=None):
        return livelink_handshake(capabilities)

    def livelink_scope(self, scope, asset):
        return livelink_scope(scope, asset)

    def retry_delay(self, attempt):
        return retry_delay(attempt)

    def store_save(self, path, tasks):
        return store_save(path, tasks)

    def store_load(self, path):
        return store_load(path)

    def migrate_legacy(self, records):
        return migrate_legacy(records)

    def log_event(self, event):
        return log_event(event)

    def capabilities(self):
        return capabilities()
