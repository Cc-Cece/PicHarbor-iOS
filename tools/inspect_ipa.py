"""Reject incomplete Python bundles before publishing an unsigned IPA."""
import hashlib
import json
import plistlib
from pathlib import Path
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def inspect(path):
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        app = next(name for name in names if name.startswith("Payload/") and name.endswith(".app/Info.plist")).rsplit("/", 1)[0] + "/"
        info = plistlib.loads(archive.read(app + "Info.plist"))
        if "processing" not in info.get("UIBackgroundModes", []):
            raise RuntimeError("Missing background processing mode")
        if "com.cccece.picharbor.processing" not in info.get("BGTaskSchedulerPermittedIdentifiers", []):
            raise RuntimeError("Missing permitted processing task identifier")
        for required in ("Frameworks/Python.framework/Python", "app/harbor_ios.py", "app/harbor_protocol.py", "app/certifi/cacert.pem",
                         "python/lib/python3.13/encodings/__init__.py", "Notices/NOTICE.md"):
            if app + required not in names:
                raise RuntimeError(f"Missing {required}")
        for module in ("_ssl", "_sqlite3", "_hashlib", "_socket"):
            framework = f"Frameworks/{module}.framework/{module}"
            if app + framework not in names:
                raise RuntimeError(f"Missing native module {module}")
            markers = [name for name in names if name.startswith(app + "python/lib/python3.13/lib-dynload/" + module + ".") and name.endswith(".fwork")]
            if not markers or archive.read(markers[0]).decode().strip() != framework:
                raise RuntimeError(f"Invalid framework marker for {module}")
        if any(name.endswith((".so", ".pyd")) for name in names):
            raise RuntimeError("Unprocessed/native-host Python extension in IPA")
        manifest = json.loads((ROOT / "Vendor/source-manifest.json").read_text())
        for entry in manifest["files"]:
            if hashlib.sha256(archive.read(app + "app/" + entry["path"])).hexdigest() != entry["sha256"]:
                raise RuntimeError(f"Vendor mismatch in IPA: {entry['path']}")
        size = sum(info.file_size for info in archive.infolist())
        print(json.dumps({"ipa": Path(path).name, "download_bytes": Path(path).stat().st_size,
                          "uncompressed_bytes": size, "note": "Packaging verified; signing and device operation still require acceptance."}))


if __name__ == "__main__":
    for path in sys.argv[1:]:
        inspect(path)
