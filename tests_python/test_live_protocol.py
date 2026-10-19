"""Offline wire contracts for original Live Photo linking, not device acceptance."""
from copy import deepcopy
import hashlib
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import MagicMock

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "Python"), str(ROOT / "Vendor")]
from blackboxprotobuf import decode_message, encode_message
from harbor_ios import Service, Failure
from harbor_live import LiveProtocol, blob, integer, RESULT_MASK
from test_adapter import FakeApi


BYTES = {"type": "bytes"}
INT = {"type": "int"}


def message(fields):
    return {"type": "message", "message_typedef": fields}


COMMIT_SCHEMA = {"1": message({"1": BYTES, "2": {"type": "string"}, "3": BYTES,
    "5": message({"1": INT}), "6": message({"1": INT}), "7": INT, "10": INT,
    "9": message({"2": INT, "3": BYTES}), "24": message({"1": BYTES, "2": BYTES})}),
    "2": message({"3": {"type": "string"}, "4": {"type": "string"}, "5": INT}), "5": BYTES}


class LiveProtocolTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.service = Service(self.temp.name, api_factory=FakeApi)
        self.service.connect({"credential": "androidId=abc&Email=alice%40example.com&Token=private"})
        self.api = self.service.api
        self.api.timeout, self.api.android_api_version = 60, 28
        self.api.user_agent, self.api.language = "test", "en_US"
        self.adapter = LiveProtocol(self.service.protocol)
        self.photo = self.resource("photo.heic", b"photo")
        self.video = self.resource("video.mov", b"video")
        self.value = {"account": self.service.account, "photo": self.photo, "video": self.video,
                      "route": "joint", "quality": "original", "created_at": 123, "modified_at": 456}
        self.session = MagicMock()
        self.session.__enter__.return_value = self.session
        self.api._new_session = lambda: self.session
        self.response = MagicMock(status_code=200)
        self.response.content = blob(1, blob(3, blob(1, b"linked")))
        self.session.post.return_value = self.response

    def resource(self, name, content):
        receipt = integer(1, 2) + blob(2, content + b"-opaque-token")
        path = self.service.staging / (name + ".receipt")
        path.write_bytes(receipt)
        return {"name": name, "response_path": str(path), "sha1": hashlib.sha1(content).hexdigest(),
                "sha256": hashlib.sha256(content).hexdigest(), "size": len(content)}

    def tearDown(self):
        self.service.db.close(); self.temp.cleanup()

    def body(self):
        return decode_message(self.session.post.call_args.kwargs["data"], COMMIT_SCHEMA)[0]

    def test_joint_commit_preserves_both_opaque_responses_and_still_hash(self):
        self.assertEqual(self.service.dispatch("pair_apple", self.value)["remote_key"], "linked")
        wire = self.body()
        self.assertEqual(wire["1"]["1"], Path(self.photo["response_path"]).read_bytes())
        self.assertEqual(wire["1"]["24"]["1"], Path(self.video["response_path"]).read_bytes())
        self.assertEqual(wire["1"]["3"], bytes.fromhex(self.photo["sha1"]))
        self.assertEqual(wire["1"]["24"]["2"], bytes.fromhex(self.video["sha1"]))
        self.assertNotIn("9", wire["1"])
        self.assertEqual(wire["5"], RESULT_MASK)
        self.assertEqual(self.api.uploads, 0)

    def test_reconcile_is_video_led_and_names_original_still_not_motion_wrapper(self):
        self.service.dispatch("pair_apple", {**self.value, "route": "reconcile"})
        wire = self.body()["1"]
        self.assertEqual(wire["1"], Path(self.video["response_path"]).read_bytes())
        self.assertEqual(wire["3"], bytes.fromhex(self.video["sha1"]))
        self.assertEqual(wire["9"], {"2": 1, "3": bytes.fromhex(self.photo["sha1"])})
        self.assertNotIn("24", wire)

    def test_still_first_commit_preserves_opaque_token_and_does_not_commit_video(self):
        calls = []
        self.api.commit_upload = lambda decoded, *a, **k: calls.append((decoded, k)) or "still-key"
        result = self.service.dispatch("commit_pair_photo", {**self.photo, "account": self.service.account, "quality": "quota"})
        self.assertEqual(result["remote_key"], "still-key")
        self.assertEqual(calls[0][0], {"1": 2, "2": b"photo-opaque-token"})
        self.assertEqual(calls[0][1]["model"], "Pixel 8")
        self.session.post.assert_not_called()

    def test_receipt_rejects_duplicate_or_wrong_version_envelopes(self):
        path = Path(self.photo["response_path"])
        for data in [integer(1, 7) + blob(2, b"token"), integer(1, 2) + integer(1, 2) + blob(2, b"token"),
                     integer(1, 2) + blob(2, b"token") + blob(2, b"token")]:
            path.write_bytes(data)
            with self.assertRaisesRegex(Failure, "UPLOAD_RESPONSE_INVALID"):
                self.service.dispatch("pair_apple", self.value)
        self.session.post.assert_not_called()

    def test_all_quality_profiles_keep_distinct_model_and_policy(self):
        for mode, model, policy in [("original", "Pixel XL", 3), ("quota", "Pixel 8", 3), ("saver", "Pixel 2", 1)]:
            self.service.dispatch("pair_apple", {**self.value, "quality": mode})
            wire = self.body()
            self.assertEqual(wire["2"]["3"], model)
            self.assertEqual(wire["1"]["7"], policy)
            self.assertEqual(wire["1"]["10"], 1)

    def test_missing_empty_invalid_and_outside_receipts_never_submit(self):
        for kind, code in [("missing", "UPLOAD_RESPONSE_MISSING"), ("empty", "UPLOAD_RESPONSE_EMPTY"),
                           ("invalid", "UPLOAD_RESPONSE_INVALID"), ("outside", "UPLOAD_RESPONSE_PATH")]:
            photo = deepcopy(self.photo)
            path = self.service.staging / (kind + ".bin")
            if kind == "empty": path.write_bytes(b"")
            if kind == "invalid": path.write_bytes(integer(1, 7))
            if kind == "outside": path = Path(self.temp.name) / "outside"
            photo["response_path"] = str(path)
            with self.assertRaisesRegex(Failure, code):
                self.service.dispatch("pair_apple", {**self.value, "photo": photo})
        self.session.post.assert_not_called()

    def test_account_and_digest_validation_precede_network(self):
        with self.assertRaisesRegex(Failure, "ACCOUNT_CHANGED"):
            self.service.dispatch("pair_apple", {**self.value, "account": "other"})
        with self.assertRaisesRegex(Failure, "INVALID_DIGEST"):
            self.service.dispatch("pair_apple", {**self.value, "video": {**self.video, "sha1": "bad"}})
        self.session.post.assert_not_called()

    def test_component_preparation_does_not_use_standalone_video_dedup_or_commit(self):
        self.api.lookups = []
        result = self.service.dispatch("prepare_pair_component", {**self.video, "account": self.service.account})
        self.assertFalse(result["exists"])
        self.assertEqual(self.api.commits, 0); self.assertEqual(self.api.uploads, 0)

    def test_motion_lookup_declares_phodeo_and_omits_commit_only_headers(self):
        self.response.content = blob(1, blob(2, blob(2, blob(1, b"linked"))))
        self.assertEqual(self.adapter.motion_key(bytes.fromhex(self.video["sha1"])), "linked")
        body = decode_message(self.session.post.call_args.kwargs["data"], {"1": message({"1": message({"1": BYTES, "5": INT}), "2": message({})})})[0]
        self.assertEqual(body["1"]["1"]["5"], 2)
        self.assertNotIn("x-goog-ext-173412678-bin", self.session.post.call_args.kwargs["headers"])

    def test_pair_confirmation_requires_same_identity_not_two_successful_files(self):
        self.api.lookups = ["still", "still", "still"]
        for movie, expected in [(b"separate-video", False), (b"still", True), (b"", False)]:
            self.response.content = blob(1, blob(2, blob(2, blob(1, movie))))
            result = self.service.dispatch("confirm_pair", self.value)
            self.assertEqual(result["confirmed"], expected)
            self.assertEqual(result["remote_key"], "still" if expected else "")
        self.assertTrue(all("5084965799730810217" in call.args[0] for call in self.session.post.call_args_list))

    def test_explicit_rejection_is_distinct_from_ambiguous_success_response(self):
        self.response.status_code = 400
        with self.assertRaisesRegex(Failure, "PAIR_COMMIT_REJECTED"):
            self.service.dispatch("pair_apple", self.value)
        self.response.status_code = 200; self.response.content = b""
        with self.assertRaisesRegex(Failure, "COMMIT_UNCONFIRMED"):
            self.service.dispatch("pair_apple", self.value)


if __name__ == "__main__":
    unittest.main()
