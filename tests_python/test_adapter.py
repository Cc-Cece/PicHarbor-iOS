"""Offline behavioral checks: cloud existence, persistence and failure boundaries."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "Python"), str(ROOT / "Vendor")]
from harbor_ios import Service, Failure, classify
import requests


class FakeApi:
    bearer_token = "never-persist-this-token"

    def __init__(self, *args, **kwargs):
        self.lookups = [None, "remote-key"]
        self.uploads = 0
        self.commits = 0
        self.mutate = None

    def find_remote_media_by_hash(self, digest):
        result = self.lookups.pop(0)
        if isinstance(result, Exception):
            raise result
        return result

    def get_upload_token(self, digest, size):
        return "private-upload-token"

    def upload_file(self, reader, token):
        self.uploads += 1
        while reader.read(2):
            pass
        if self.mutate:
            self.mutate()
        return {"1": "binary-protocol-result"}

    def commit_upload(self, *args, **kwargs):
        self.commits += 1
        return "remote-key"


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.service = Service(self.temp.name, api_factory=FakeApi)
        self.credential = "androidId=abc&Email=alice%40example.com&Token=private-master-token"
        self.service.connect({"credential": self.credential})
        self.path = self.service.staging / "original.jpg"
        self.path.write_bytes(b"original-photo-bytes")
        self.payload = {"path": str(self.path), "name": "original.jpg", "account": self.service.account}

    def tearDown(self):
        self.service.db.close()
        self.temp.cleanup()

    def test_probe_loads_tls_sqlite_and_protocol(self):
        result = self.service.dispatch("probe", {})
        self.assertTrue(result["gpmc_imported"])
        self.assertIn("OpenSSL", result["tls"])

    def test_uploaded_content_requires_independent_hash_confirmation(self):
        result = self.service.dispatch("upload", self.payload)["record"]
        self.assertEqual(result["state"], "confirmed")
        self.assertEqual(result["origin"], "uploaded")
        self.assertEqual(self.service.api.commits, 1)
        self.assertEqual(self.service.api.lookups, [])
        self.assertNotIn("eligible", result)

    def test_duplicate_does_not_upload_or_commit(self):
        self.service.api.lookups = ["existing-content"]
        result = self.service.upload(self.payload)
        self.assertEqual(result["origin"], "content_exists")
        self.assertEqual(result["state"], "confirmed")
        self.assertEqual(self.service.api.uploads, 0)
        self.assertEqual(self.service.api.commits, 0)

    def test_missing_hash_after_commit_is_pending_not_success(self):
        self.service.api.lookups = [None, None]
        result = self.service.upload(self.payload)
        self.assertEqual(result["state"], "confirmation_pending")
        self.assertEqual(result["remote_key"], "remote-key")
        self.assertEqual(result["error"], "REMOTE_NOT_VISIBLE")

    def test_network_failure_after_commit_preserves_observation_for_reverification(self):
        self.service.api.lookups = [None, requests.ConnectionError("https://secret?token=private")]
        result = self.service.upload(self.payload)
        self.assertEqual(result["state"], "confirmation_pending")
        self.assertEqual(result["error"], "NETWORK_ERROR")
        self.assertEqual(result["remote_key"], "remote-key")
        self.service.api.lookups = ["remote-key"]
        verified = self.service.dispatch("verify", {"account": self.service.account, "id": result["id"]})
        self.assertEqual(verified["record"]["state"], "confirmed")
        self.assertEqual(self.service.api.uploads, 1)

    def test_changed_original_is_never_committed(self):
        self.service.api.lookups = [None]
        self.service.api.mutate = lambda: self.path.write_bytes(b"different-content")
        result = self.service.upload(self.payload)
        self.assertEqual(result["state"], "failed")
        self.assertEqual(result["error"], "SOURCE_CHANGED")
        self.assertEqual(self.service.api.commits, 0)

    def test_only_staging_paths_are_readable(self):
        outside = Path(self.temp.name) / "private.txt"
        outside.write_text("secret")
        with self.assertRaisesRegex(Failure, "FILE_ACCESS"):
            self.service.upload({**self.payload, "path": str(outside)})

    def test_identity_mismatch_rejected_before_upload(self):
        with self.assertRaisesRegex(Failure, "ACCOUNT_CHANGED"):
            self.service.dispatch("upload", {**self.payload, "account": "other@example.com"})
        self.assertEqual(self.service.api.uploads, 0)

    def test_records_survive_restart_and_are_account_scoped(self):
        record = self.service.upload(self.payload)
        self.service.db.close()
        self.service = Service(self.temp.name, api_factory=FakeApi)
        self.service.connect({"credential": self.credential})
        self.assertEqual(self.service.records()[0]["id"], record["id"])
        self.service.connect({"credential": "androidId=abc&Email=bob%40example.com&Token=other"})
        self.assertEqual(self.service.records(), [])
        with self.assertRaisesRegex(Failure, "RECORD_MISSING"):
            self.service.dispatch("verify", {"account": self.service.account, "id": record["id"]})

    def test_in_flight_record_becomes_interrupted_after_restart(self):
        record = self.service.upload(self.payload)
        self.service.save(record, state="uploading")
        self.service.db.close()
        self.service = Service(self.temp.name, api_factory=FakeApi)
        self.service.connect({"credential": self.credential})
        self.assertEqual(self.service.records()[0]["state"], "interrupted")

    def test_failed_account_switch_clears_previous_identity(self):
        with self.assertRaises(Failure):
            self.service.connect({"credential": "androidId=abc&Email=invalid"})
        self.assertEqual(self.service.account, "")
        self.assertIsNone(self.service.api)

    def test_tokens_and_exception_text_are_not_persisted(self):
        self.service.upload(self.payload)
        blob = (Path(self.temp.name) / "observations.sqlite").read_bytes()
        for secret in (b"private-master-token", b"private-upload-token", b"never-persist-this-token"):
            self.assertNotIn(secret, blob)
        self.assertEqual(classify(RuntimeError("private-secret")), "ENGINE_ERROR")


if __name__ == "__main__":
    unittest.main()
