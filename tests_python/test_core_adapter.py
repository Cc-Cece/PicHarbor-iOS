"""Offline checks for the harbor_core passthrough in harbor_ios.dispatch.

The Swift HarborCoreAdapter calls ``core_*`` actions through
PythonBridge; harbor_ios routes them to ``gpmc.harbor_core.dispatch_json``
without requiring a login, account or proxy. No network is used.
"""
import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "Python"), str(ROOT / "Vendor")]
import harbor_ios


def call(action, payload=None):
    return json.loads(harbor_ios.dispatch(action, json.dumps({
        "protocol_version": 2, "request_id": "test-core",
        **(payload or {}),
    })))


def asset():
    data = b"original-photo-bytes"
    return {"local_id": "asset-1", "filename": "IMG_0001.HEIC",
            "sha1": hashlib.sha1(data).hexdigest(),
            "sha256": hashlib.sha256(data).hexdigest(),
            "size": len(data), "media_kind": "photo"}


class CorePassthroughTests(unittest.TestCase):
    def test_capabilities_reports_core_version(self):
        result = call("core_capabilities")
        self.assertTrue(result["ok"])
        self.assertEqual(result["harbor_core_version"], 1)
        self.assertEqual(result["protocol_version"], 2)
        self.assertEqual(result["request_id"], "test-core")
        self.assertIn("create_task", result["actions"])

    def test_create_and_transition_happy_path(self):
        created = call("core_create_task", {
            "task_id": "job-1", "asset": asset(),
            "idempotency_key": "acct|asset-1|rev|original:applePair:both:mux1"})
        self.assertTrue(created["ok"], created)
        task = created["task"]
        self.assertEqual(task["state"], "queued")
        preparing = call("core_transition", {"task": task, "to": "preparing"})
        self.assertTrue(preparing["ok"], preparing)
        self.assertEqual(preparing["task"]["state"], "preparing")
        self.assertEqual(preparing["task"]["attempts"], 1)
        uploading = call("core_transition", {"task": preparing["task"], "to": "uploading"})
        self.assertTrue(uploading["ok"], uploading)
        # An illegal edge is a structured error, never an exception.
        illegal = call("core_transition", {"task": uploading["task"], "to": "done"})
        self.assertFalse(illegal["ok"])
        self.assertEqual(illegal["error"], "INVALID_TRANSITION")

    def test_decide_prepare_uses_supplied_remote_key_only(self):
        self.assertTrue(call("core_decide_prepare", {
            "asset": asset(), "remote_key": "remote-key"})["exists"])
        self.assertFalse(call("core_decide_prepare", {"asset": asset()})["exists"])
        invalid = dict(asset(), sha1="not-a-digest")
        failed = call("core_decide_prepare", {"asset": invalid})
        self.assertFalse(failed["ok"])
        self.assertEqual(failed["error"], "INVALID_DIGEST")

    def test_decide_cleanup_needs_fresh_confirmed_original(self):
        created = call("core_create_task", {"task_id": "job-2", "asset": asset()})
        task = created["task"]
        fresh = {"cloud_state": "confirmed_original", "checked_at": 1750000000,
                 "policy": True}
        # checked_at is an epoch value; freshness is judged against now,
        # so a 2025 timestamp is stale by construction.
        stale = call("core_decide_cleanup", {"task": task, "evidence": fresh})
        self.assertFalse(stale["eligible"])
        self.assertEqual(stale["reason"], "CLOUD_STATE_EXPIRED")
        import time
        fresh["checked_at"] = int(time.time())
        self.assertTrue(call("core_decide_cleanup", {
            "task": task, "evidence": fresh})["eligible"])

    def test_retry_delay_backoff(self):
        self.assertEqual(call("core_retry_delay", {"attempt": 0})["delay_seconds"], 5)
        self.assertEqual(call("core_retry_delay", {"attempt": 2})["delay_seconds"], 20)
        self.assertEqual(call("core_retry_delay", {"attempt": 9})["delay_seconds"], 300)
        failed = call("core_retry_delay", {"attempt": -1})
        self.assertFalse(failed["ok"])
        self.assertEqual(failed["error"], "INVALID_RETRY_ATTEMPT")

    def test_store_save_and_load_round_trip(self):
        with tempfile.TemporaryDirectory() as home:
            path = str(Path(home) / "harbor-core-tasks.json")
            created = call("core_create_task", {"task_id": "job-3", "asset": asset()})
            saved = call("core_store_save", {"path": path, "tasks": {"job-3": created["task"]}})
            self.assertTrue(saved["saved"])
            self.assertEqual(saved["count"], 1)
            loaded = call("core_store_load", {"path": path})
            self.assertTrue(loaded["ok"])
            self.assertEqual(loaded["tasks"]["job-3"]["state"], "queued")
            missing = call("core_store_load", {"path": str(Path(home) / "nope.json")})
            self.assertFalse(missing["ok"])
            self.assertEqual(missing["error"], "FILE_ACCESS")

    def test_log_event_redacts_hashes_and_paths(self):
        event = {"event": "upload", "filename": "/private/Staging/IMG_0001.HEIC",
                 "sha1": "a" * 40, "account_id": "someone@example.com"}
        result = call("core_log_event", {"event": event})
        self.assertTrue(result["ok"])
        redacted = result["event"]
        self.assertEqual(redacted["filename"], "IMG_0001.HEIC")
        self.assertEqual(redacted["sha1"], "[redacted]")
        self.assertEqual(redacted["account_id"], "[redacted]")

    def test_unknown_core_action_is_structured(self):
        result = call("core_no_such_action")
        self.assertFalse(result["ok"])
        self.assertEqual(result["error"], "UNKNOWN_OPERATION")

    def test_missing_harbor_core_is_runtime_unavailable(self):
        import gpmc
        saved_module = sys.modules.get("gpmc.harbor_core")
        saved_attr = hasattr(gpmc, "harbor_core")
        try:
            sys.modules["gpmc.harbor_core"] = None
            if saved_attr:
                delattr(gpmc, "harbor_core")
            result = call("core_capabilities")
            self.assertFalse(result["ok"])
            self.assertEqual(result["error"], "RUNTIME_UNAVAILABLE")
        finally:
            if saved_module is not None:
                sys.modules["gpmc.harbor_core"] = saved_module
            else:
                sys.modules.pop("gpmc.harbor_core", None)
            if saved_attr:
                gpmc.harbor_core = saved_module


if __name__ == "__main__":
    unittest.main()
