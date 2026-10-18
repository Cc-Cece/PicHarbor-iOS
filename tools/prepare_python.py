"""Run on the macOS builder before XcodeGen. Never downloads at app runtime."""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


def main():
    lock = json.loads((ROOT / "tools/runtime-lock.json").read_text())
    cache = ROOT / ".runtime-cache"
    cache.mkdir(exist_ok=True)
    archive = cache / lock["url"].rsplit("/", 1)[1]
    if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != lock["sha256"]:
        partial = archive.with_suffix(".download")
        urllib.request.urlretrieve(lock["url"], partial)
        if hashlib.sha256(partial.read_bytes()).hexdigest() != lock["sha256"]:
            raise RuntimeError("Runtime SHA-256 mismatch")
        partial.replace(archive)
    runtime = ROOT / "Runtime"
    runtime.mkdir(exist_ok=True)
    with tarfile.open(archive) as source:
        source.extractall(runtime, filter="data")
    packages = ROOT / ".python-deps"
    if packages.exists():
        shutil.rmtree(packages)
    subprocess.run([sys.executable, "-m", "pip", "install", "--disable-pip-version-check", "--only-binary=:all:",
                    "--platform", "any", "--no-compile", "--target", str(packages),
                    "-r", str(ROOT / "Python/requirements.lock")], check=True)
    # Verify the vendor snapshot before producing any release artifact.
    manifest = json.loads((ROOT / "Vendor/source-manifest.json").read_text())
    for entry in manifest["files"]:
        actual = hashlib.sha256((ROOT / "Vendor" / entry["path"]).read_bytes()).hexdigest()
        if actual != entry["sha256"]:
            raise RuntimeError(f"Vendor snapshot changed: {entry['path']}")
    print("Pinned Python runtime verified; pure Python dependencies prepared.")


if __name__ == "__main__":
    main()
