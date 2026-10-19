"""Offline protocol contracts for native background upload and cleanup boundaries."""
import hashlib
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch, MagicMock

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "Python"), str(ROOT / "Vendor")]
import harbor_ios
from harbor_ios import Service, Failure
from harbor_protocol import Protocol
from test_adapter import FakeApi
from blackboxprotobuf import encode_message


class ProtocolTests(unittest.TestCase):
    def test_paired_movie_cleanup_uses_movie_hash_and_never_still_access_proof(self):
        from harbor_live import LiveProtocol
        with patch.object(LiveProtocol, "motion_key", return_value="same") as lookup, patch.object(self.service.protocol, "original_access") as access:
            result = self.service.dispatch("check_cleanup", {**self.value, "paired_video": True})
            self.assertEqual(result["reason"], "LIVE_COMPONENT_UNVERIFIED")
            access.assert_not_called()
            self.assertTrue(self.service.dispatch("check_cleanup", {**self.value, "paired_video": True, "cloud_state": False, "original_access": False})["eligible"])
            self.assertEqual(lookup.call_count, 2)
        with patch.object(LiveProtocol, "motion_key", return_value=""):
            self.assertEqual(self.service.dispatch("check_cleanup", {**self.value, "paired_video": True, "cloud_state": False, "original_access": False})["reason"], "REMOTE_MISSING")
        with self.assertRaises(Failure):
            self.service.dispatch("check_cleanup", {**self.value, "paired_video": "false"})
    def test_cleanup_refreshes_expired_evidence_only_when_requested(self):
        p = self.service.protocol
        self.service.api.lookups = ["saved", "saved"]
        with patch("harbor_protocol.time.monotonic", return_value=100):
            self.assertEqual(self.service.dispatch("check_cleanup", self.value)["reason"], "CLOUD_STATE_EXPIRED")
        def refresh():
            p.snapshot = {"saved": {"trash": 0, "status": 100, "original": True, "size": self.value["size"]}}
            p.snapshot_at = time.monotonic()
        with patch.object(p, "synchronize", side_effect=refresh) as sync, patch.object(p, "original_access", return_value=True):
            self.assertTrue(self.service.dispatch("check_cleanup", {**self.value, "refresh_if_stale": True})["eligible"])
            sync.assert_called_once()

    def test_confirmation_refresh_uses_delta_and_keeps_unchanged_items(self):
        calls = []
        def state(token):
            calls.append(token)
            if not token:
                return {"1": {"6": "first", "2": [{"1": "plain", "2": {"11": 100}},
                                                     {"1": "live", "2": {"11": 100}}]}}
            return {"1": {"6": "second", "2": {"1": "live", "2": {"11": 100},
                        "5": {"5": {"2": {"4": {"1": 3}}}}}}}
        self.service.api.get_library_state = state
        p = self.service.protocol
        p.synchronize()
        self.assertFalse(p.snapshot["live"]["motion"])
        p.synchronize()
        self.assertEqual(calls, ["", "first"])
        self.assertIn("plain", p.snapshot)
        self.assertTrue(p.snapshot["live"]["motion"])
        self.assertEqual(p.sync_token, "second")

    def test_failed_delta_discards_partial_evidence_and_next_refresh_is_full(self):
        p = self.service.protocol
        p.snapshot = {"old": {"motion": True}}
        p.sync_token = "old-token"
        self.service.api.get_library_state = lambda _: {"1": {"1": "page", "6": "partial"}}
        self.service.api.get_library_page = MagicMock(side_effect=RuntimeError("invalid token"))
        with self.assertRaises(RuntimeError):
            p.synchronize()
        self.assertEqual(p.snapshot, {})
        self.assertEqual(p.sync_token, "")
        self.assertEqual(p.snapshot_at, 0)
        self.service.api.get_library_state = MagicMock(return_value={"1": {"6": "fresh"}})
        p.synchronize()
        self.service.api.get_library_state.assert_called_once_with("")

    def test_delta_pagination_applies_deletions_without_publishing_stale_items(self):
        p = self.service.protocol
        p.snapshot = {"keep": {}, "removed": {}}
        p.sync_token = "before"
        self.service.api.get_library_state = MagicMock(return_value={"1": {"6": "next", "1": "resume", "9": {"1": {"1": 1, "2": {"1": "removed"}}}}})
        self.service.api.get_library_page = MagicMock(return_value={"1": {"6": "final", "2": {"1": "added", "2": {"11": 100}}}})
        p.synchronize()
        self.service.api.get_library_state.assert_called_once_with("before")
        self.service.api.get_library_page.assert_called_once_with("resume", "before")
        self.assertEqual(set(p.snapshot), {"keep", "added"})
        self.assertEqual(p.sync_token, "final")

    def test_confirmation_cache_is_shared_and_expires_after_fifteen_seconds(self):
        p = self.service.protocol
        p.snapshot = {"live": {"motion": True, "status": 100, "trash": 0}}
        p.snapshot_at = 100
        with patch("harbor_protocol.time.monotonic", return_value=114), patch.object(p, "synchronize") as sync:
            self.assertTrue(self.service.dispatch("motion_status", {"account": self.service.account, "keys": ["live", "live"]})["recognized"])
            sync.assert_not_called()
        with patch("harbor_protocol.time.monotonic", return_value=115), patch.object(p, "synchronize") as sync:
            self.service.dispatch("motion_status", {"account": self.service.account, "keys": ["live"]})
            sync.assert_called_once()

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.service = Service(self.temp.name, api_factory=FakeApi)
        self.service.connect({"credential": "androidId=abc&Email=alice%40example.com&Token=private"})
        self.service.api.user_agent = "test"
        self.service.api.language = "en_US"
        data = b"source"
        self.value = {"account": self.service.account, "sha1": hashlib.sha1(data).hexdigest(),
                      "sha256": hashlib.sha256(data).hexdigest(), "size": len(data)}

    def tearDown(self):
        self.service.db.close()
        self.temp.cleanup()

    def test_prepare_does_not_transfer_or_persist_tokens(self):
        result = self.service.dispatch("prepare_upload", self.value)
        self.assertFalse(result["exists"])
        self.assertTrue(result["url"].startswith("https://photos.googleapis.com/"))
        self.assertIn("Authorization", result["headers"])
        self.assertEqual(self.service.api.uploads, 0)
        self.assertEqual(self.service.records(), [])
        self.assertNotIn(b"private-upload-token", (Path(self.temp.name) / "observations.sqlite").read_bytes())

    def test_duplicate_has_no_transport_credentials(self):
        self.service.api.lookups = ["existing"]
        result = self.service.dispatch("prepare_upload", self.value)
        self.assertEqual(result, {"exists": True, "remote_key": "existing"})

    def test_explicit_rebackup_can_force_new_quality(self):
        self.service.api.lookups = ["existing"]
        self.assertFalse(self.service.dispatch("prepare_upload", {**self.value, "force": True})["exists"])

    def test_prepare_rejects_account_and_malformed_digest(self):
        with self.assertRaisesRegex(Failure, "ACCOUNT_CHANGED"):
            self.service.dispatch("prepare_upload", {**self.value, "account": "other"})
        with self.assertRaisesRegex(Failure, "INVALID_DIGEST"):
            self.service.dispatch("prepare_upload", {**self.value, "sha1": "bad"})

    def test_commit_reads_only_bounded_staging_response_and_defaults_original(self):
        path = self.service.staging / "response.bin"
        path.write_bytes(encode_message({"1": 7}, {"1": {"type": "int"}}))
        calls = []
        self.service.api.commit_upload = lambda *a, **k: calls.append(k) or "submitted"
        result = self.service.dispatch("commit_resource", {**self.value, "response_path": str(path), "name": "photo.jpg"})
        self.assertEqual(result["remote_key"], "submitted")
        self.assertEqual(calls[0]["model"], "Pixel XL")
        self.assertNotIn("confirmed", result)
        outside = Path(self.temp.name) / "private"
        outside.write_bytes(b"x")
        with self.assertRaisesRegex(Failure, "UPLOAD_RESPONSE_PATH"):
            self.service.dispatch("commit_resource", {**self.value, "response_path": str(outside), "name": "x"})

    def test_missing_empty_and_invalid_upload_responses_never_call_cloud_commit(self):
        path = self.service.staging / "response.bin"
        calls = []
        self.service.api.commit_upload = lambda *a, **k: calls.append(True) or "submitted"
        for content, code in [(None, "UPLOAD_RESPONSE_MISSING"), (b"", "UPLOAD_RESPONSE_EMPTY"), (b"\xff", "UPLOAD_RESPONSE_INVALID")]:
            if content is not None:
                path.write_bytes(content)
            with self.assertRaisesRegex(Failure, code):
                self.service.dispatch("commit_resource", {**self.value, "response_path": str(path), "name": "x"})
        self.assertEqual(calls, [])

    def test_all_quality_models(self):
        path = self.service.staging / "response.bin"
        path.write_bytes(encode_message({"1": 7}, {"1": {"type": "int"}}))
        for mode, model in [("original", "Pixel XL"), ("quota", "Pixel 8"), ("saver", "Pixel 2")]:
            calls = []
            self.service.api.commit_upload = lambda *a, **k: calls.append(k) or "submitted"
            self.service.dispatch("commit_resource", {**self.value, "response_path": str(path), "name": "photo", "quality": mode})
            self.assertEqual(calls[0]["model"], model)

    def test_confirmation_is_independent_and_missing_not_success(self):
        self.service.api.lookups = [None, "visible"]
        self.assertFalse(self.service.dispatch("confirm_resource", self.value)["confirmed"])
        self.assertTrue(self.service.dispatch("confirm_resource", self.value)["confirmed"])

    def test_apple_pair_is_explicitly_experimental_and_rejects_incomplete_input(self):
        capability = self.service.dispatch("capabilities", {})
        self.assertTrue(capability["apple_pair"])
        self.assertTrue(capability["apple_pair_experimental"])
        self.assertEqual(capability["apple_pair_routes"], ["joint", "reconcile"])
        with self.assertRaisesRegex(Failure, "INVALID_PAIR_RESOURCES"):
            self.service.dispatch("pair_apple", self.value)
        self.assertEqual(self.service.api.uploads, 0)

    def test_cleanup_requires_fresh_complete_state(self):
        self.service.api.lookups = ["cloud"]
        self.assertFalse(self.service.dispatch("check_cleanup", self.value)["eligible"])

    def test_cleanup_rejects_processing_trash_and_unknown_quality(self):
        protocol = self.service.protocol
        protocol.snapshot_at = time.monotonic()
        valid = {"trash": 0, "status": 100, "original": True, "size": self.value["size"]}
        for changes in ({"trash": 1}, {"status": 99}, {"original": None}, {"size": 1}):
            protocol.snapshot = {"cloud": {**valid, **changes}}
            self.service.api.lookups = ["cloud"]
            self.assertFalse(self.service.dispatch("check_cleanup", self.value)["eligible"])

    def test_explicit_reduced_policy_still_requires_content_match(self):
        self.service.api.lookups = [None, "cloud"]
        value = {**self.value, "cloud_state": False, "original_access": False}
        self.assertFalse(self.service.dispatch("check_cleanup", value)["eligible"])
        self.assertTrue(self.service.dispatch("check_cleanup", value)["eligible"])

    def test_cleanup_rejects_non_boolean_policy(self):
        self.service.api.lookups = ["cloud"]
        with self.assertRaisesRegex(Failure, "INVALID_CHECK_POLICY"):
            self.service.dispatch("check_cleanup", {**self.value, "cloud_state": "false"})

    def test_original_url_allowlist(self):
        for url in ["http://lh3.googleusercontent.com/a", "https://google.com.attacker.test/a", "https://user@google.com/a", "https://google.com:444/a", "file:///a"]:
            self.assertFalse(Protocol.allowed_url(url), url)
        self.assertTrue(Protocol.allowed_url("https://lh3.googleusercontent.com/a?secret"))

    def test_failed_cloud_refresh_invalidates_old_snapshot(self):
        protocol = self.service.protocol
        protocol.snapshot = {"old": {}}
        protocol.snapshot_at = time.monotonic()
        self.service.api.get_library_state = lambda _: (_ for _ in ()).throw(RuntimeError("fail"))
        with self.assertRaises(RuntimeError):
            protocol.synchronize()
        self.assertEqual(protocol.snapshot_at, 0)
        self.assertEqual(protocol.snapshot, {})

    def test_versioned_envelope_and_sanitized_error(self):
        with patch.object(harbor_ios, "_service", self.service):
            import json
            result = json.loads(harbor_ios.dispatch("capabilities", '{"request_id":"r","protocol_version":99}'))
            self.assertFalse(result["ok"])
            self.assertEqual(result["request_id"], "r")
            self.assertEqual(result["failure"]["code"], "PROTOCOL_VERSION")

    def test_motion_requires_dynamic_metadata_for_every_version(self):
        protocol = self.service.protocol
        protocol.snapshot_at = time.monotonic()
        protocol.snapshot = {"original": {"motion": True, "status": 100, "trash": 0},
                             "edited": {"motion": False, "status": 100, "trash": 0}}
        result = self.service.dispatch("motion_status", {"account": self.service.account, "keys": ["original", "edited"]})
        self.assertFalse(result["recognized"])
        protocol.snapshot["edited"]["motion"] = True
        self.assertTrue(self.service.dispatch("motion_status", {"account": self.service.account, "keys": ["original", "edited"]})["recognized"])

    def test_complete_paged_snapshot_preserves_quality_trash_and_motion_presence(self):
        self.service.api.get_library_state = lambda _: {"1": {"1": "next", "6": "token", "2": {
            "1": "plain", "2": {"10": 6, "11": 100, "16": b"", "35": {"3": 2}}}}}
        self.service.api.get_library_page_init = lambda _: {"1": {"6": "final", "2": {
            "1": "motion", "2": {"10": 12, "11": 100, "16": {"3": 123}, "35": {"3": 2}},
            "5": {"5": {"2": {"4": {"1": 3}}}}}}}
        self.service.protocol.synchronize()
        self.assertTrue(self.service.protocol.snapshot["plain"]["original"])
        self.assertEqual(self.service.protocol.snapshot["plain"]["trash"], 0)
        self.assertEqual(self.service.protocol.snapshot["motion"]["trash"], 123)
        self.assertTrue(self.service.protocol.snapshot["motion"]["motion"])
        self.assertGreater(self.service.protocol.snapshot_at, 0)

    def test_motion_optional_trash_marker_does_not_block_confirmation_or_weaken_cleanup(self):
        self.service.api.get_library_state = lambda _: {"1": {"6": "final", "2": {
            "1": "motion", "2": {"10": 6, "11": "100", "35": {"3": 2}},
            "5": {"5": {"2": {"4": {"1": 3}}}}}}}
        self.service.protocol.synchronize()
        result = self.service.dispatch("motion_status", {"account": self.service.account, "keys": ["motion"]})
        self.assertTrue(result["recognized"])
        self.service.api.lookups = ["motion"]
        self.assertFalse(self.service.dispatch("check_cleanup", self.value)["eligible"], "Cleanup still requires explicit non-trash evidence")

    def test_motion_diagnostics_distinguish_missing_processing_static_and_trashed(self):
        protocol = self.service.protocol
        protocol.snapshot_at = time.monotonic()
        good = {"motion": True, "status": 100, "trash": 0}
        for item, reason in [(None, "NOT_INDEXED"), ({**good, "status": 99}, "PROCESSING"),
                             ({**good, "motion": False}, "NOT_DYNAMIC"),
                             ({**good, "trash": 1}, "TRASHED"),
                             ({**good, "trash": None}, "TRASH_UNKNOWN")]:
            protocol.snapshot = {} if item is None else {"motion": item}
            result = self.service.dispatch("motion_status", {"account": self.service.account, "keys": ["motion"]})
            self.assertFalse(result["recognized"])
            self.assertEqual(result["reason"], "REMOTE_MOTION_" + reason)

    def test_commit_invalidates_cached_cloud_snapshot(self):
        path = self.service.staging / "response.bin"
        path.write_bytes(encode_message({"1": 7}, {"1": {"type": "int"}}))
        self.service.api.commit_upload = lambda *a, **k: "submitted"
        self.service.protocol.snapshot_at = time.monotonic()
        self.service.dispatch("commit_resource", {**self.value, "response_path": str(path), "name": "motion.heic"})
        self.assertEqual(self.service.protocol.snapshot_at, 0)

    def test_cyclic_pagination_never_publishes_partial_snapshot(self):
        response = {"1": {"1": "repeat", "6": "token"}}
        self.service.api.get_library_state = lambda _: response
        self.service.api.get_library_page_init = lambda _: response
        with self.assertRaisesRegex(Failure, "SYNC_CYCLE"):
            self.service.protocol.synchronize()
        self.assertEqual(self.service.protocol.snapshot_at, 0)

    def test_original_access_range_fallback_reads_headers_not_body(self):
        head, ranged = MagicMock(), MagicMock()
        head.status_code, head.headers = 405, {}
        ranged.status_code, ranged.headers = 206, {"Content-Range": "bytes 0-0/6", "Content-Length": "1"}
        head.__enter__.return_value = head
        ranged.__enter__.return_value = ranged
        session = MagicMock(); session.__enter__.return_value = session
        session.request.side_effect = [head, ranged]
        self.service.api._new_session = lambda: session
        self.service.api.get_download_urls = lambda _: {"1": {"5": {"2": {"6": "https://lh3.googleusercontent.com/original"}}}}
        self.assertTrue(self.service.protocol.original_access("key", 6))
        self.assertEqual(session.request.call_args.kwargs["headers"]["Range"], "bytes=0-0")
        ranged.iter_content.assert_not_called()

    def test_original_access_never_follows_external_redirect(self):
        response = MagicMock(); response.status_code = 302
        response.headers = {"Location": "https://attacker.test/signed"}
        response.__enter__.return_value = response
        session = MagicMock(); session.__enter__.return_value = session
        session.request.return_value = response
        self.service.api._new_session = lambda: session
        self.service.api.get_download_urls = lambda _: {"1": {"5": {"2": {"6": "https://lh3.googleusercontent.com/original"}}}}
        self.assertFalse(self.service.protocol.original_access("key", 6))
        self.assertEqual(session.request.call_count, 1)


if __name__ == "__main__":
    unittest.main()
