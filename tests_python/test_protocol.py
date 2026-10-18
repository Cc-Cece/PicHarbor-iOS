"""Offline protocol contracts for native background upload and cleanup boundaries."""
import hashlib
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "Python"), str(ROOT / "Vendor")]
import harbor_ios
from harbor_ios import Service, Failure
from harbor_protocol import Protocol
from test_adapter import FakeApi
from blackboxprotobuf import encode_message


class ProtocolTests(unittest.TestCase):
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
        with self.assertRaisesRegex(Failure, "FILE_ACCESS"):
            self.service.dispatch("commit_resource", {**self.value, "response_path": str(outside), "name": "x"})

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

    def test_apple_pair_is_never_faked(self):
        self.assertFalse(self.service.dispatch("capabilities", {})["apple_pair"])
        with self.assertRaisesRegex(Failure, "PAIR_PROTOCOL_UNVERIFIED"):
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


if __name__ == "__main__":
    unittest.main()
