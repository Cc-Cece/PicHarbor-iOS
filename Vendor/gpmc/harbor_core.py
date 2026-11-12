"""Shared business core for PicHarbor mobile backup (Android + iOS).

Pure Python: no platform imports, no network, no file access except the
explicit ``store_save`` / ``store_load`` paths the caller supplies.
Android (Chaquopy) and iOS (embedded Python 3.13 + PythonBridge) both call
this module through :func:`dispatch` / :func:`dispatch_json`.

Scope split with :mod:`gpmc.protocol` (see ``docs/HARBOR-CORE.md``):

* ``harbor_core`` makes *business decisions*: task state machine, dedup
  decisions, retry backoff, cleanup-guidance eligibility, task persistence,
  log redaction.
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
    "retry_delay",
    "store_save",
    "store_load",
    "log_event",
    "capabilities",
)
_ACTION_SET = frozenset(ACTIONS)

MEDIA_KINDS = ("photo", "video", "live_photo")

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
    "failed": {"queued"},
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


def _validate_asset(asset):
    if not isinstance(asset, dict):
        raise _Failure("INVALID_ARGUMENT")
    for field in ("local_id", "filename"):
        if not isinstance(asset.get(field), str) or not asset[field]:
            raise _Failure("INVALID_ARGUMENT")
    if asset.get("media_kind") not in MEDIA_KINDS:
        raise _Failure("INVALID_MEDIA_KIND")
    _validate_digest(asset)
    return {
        "local_id": asset["local_id"],
        "filename": asset["filename"],
        "sha1": asset["sha1"],
        "sha256": asset["sha256"],
        "size": asset["size"],
        "media_kind": asset["media_kind"],
        "created_at": asset.get("created_at") or _now_iso(),
    }


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

    updated = dict(task)
    updated["history"] = [dict(entry) for entry in task.get("history", [])]
    updated["asset"] = dict(task.get("asset", {}))
    now = _now_iso()
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


def decide_prepare(asset, remote_key=None):
    """Dedup decision for an asset, before any upload work.

    Validates sha1 (40 hex) / sha256 (64 hex) / size > 0, the same boundary
    as :meth:`gpmc.protocol.Protocol.digest`. Returns
    ``{"exists": True, "remote_key": ...}`` when the remote already holds
    the asset, otherwise ``{"exists": False}``. Invalid digests return
    ``{"ok": False, "error": "INVALID_DIGEST"}``. No network is performed
    here: the caller supplies ``remote_key`` from a prior
    ``Protocol.prepare_upload`` / hash lookup.
    """
    if remote_key is not None and (not isinstance(remote_key, str) or not remote_key):
        return _error("INVALID_ARGUMENT")
    if not isinstance(asset, dict):
        return _error("INVALID_ARGUMENT")
    try:
        _validate_digest(asset)
    except _Failure as exc:
        return _error(str(exc))
    if remote_key:
        return {"exists": True, "remote_key": remote_key}
    return {"exists": False}


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
    """
    return _decide_cleanup(task, evidence, None)


def _decide_cleanup(task, evidence, policy):
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
        task = dict(record)
        task["asset"] = dict(record.get("asset") or {})
        task["state"] = state
        task["error_code"] = error_code
        task.setdefault("attempts", 0)
        task.setdefault("idempotency_key", None)
        task.setdefault("remote_key", None)
        task.setdefault("cloud_confirmed", state == "done")
        task.setdefault("created_at", now)
        task.setdefault("updated_at", now)
        task.setdefault("history", [{"state": state, "at": now, "event": "migrated"}])
        migrated.append(task)
    return {"tasks": migrated}


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
        return decide_prepare(asset, value.get("remote_key"))
    if action == "decide_cleanup":
        return _decide_cleanup(value.get("task"), value.get("evidence"),
                               value.get("policy"))
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

    def decide_prepare(self, asset, remote_key=None):
        return decide_prepare(asset, remote_key)

    def decide_cleanup(self, task, evidence, policy=None):
        return _decide_cleanup(task, evidence, policy)

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
