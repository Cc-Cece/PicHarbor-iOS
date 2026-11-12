"""Export or verify pinned gpmc snapshots; no runtime or build-time download.

Maintained in the canonical gpmc repository. Copies in consumers are generated.
Run in a consumer: python tools/sync_gpmc.py --source ../gpmc
Normal builds run --check and need neither a sibling checkout nor a network.
"""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import zipfile


def digest(data):
    return hashlib.sha256(data).hexdigest()


def normalized(path):
    return path.read_bytes().replace(b"\r\n", b"\n")


def package_files(folder):
    if folder.is_symlink():
        raise ValueError("Refusing a symlink package directory")
    files = {}
    for path in sorted(folder.rglob("*")):
        if "__pycache__" in path.parts or path.suffix == ".pyc":
            continue
        if path.is_symlink():
            raise ValueError(f"Refusing symlink: {path}")
        if path.is_file():
            files[path.relative_to(folder).as_posix()] = normalized(path)
    return files


def layout(root):
    if (root / "app/src/main/python").is_dir():
        return "android", [root / "app/src/main/python/gpmc"]
    if (root / "Vendor/gpmc").is_dir():
        return "ios", [root / "Vendor/gpmc"]
    if (root / "src/PicHarbor.Core/GooglePhotos").is_dir():
        base = root / "src/PicHarbor.Core/GooglePhotos"
        return "desktop", [base / "Embedded/gpmc", base / "gpmc"]
    raise ValueError("Target is not a supported PicHarbor consumer")


def tree_id(files):
    return digest(json.dumps(files, sort_keys=True, separators=(",", ":")).encode())


def check(root):
    kind, targets = layout(root)
    lock = json.loads((root / "gpmc.lock.json").read_text(encoding="utf-8"))
    expected = lock["files"]
    if lock.get("schema_version") != 1 or lock["source_tree_sha256"] != tree_id(expected):
        raise ValueError("Invalid gpmc source lock")
    for target in targets:
        actual = {name: digest(data) for name, data in package_files(target).items()}
        if actual != expected:
            changed = sorted(set(actual) ^ set(expected) | {n for n in actual.keys() & expected.keys() if actual[n] != expected[n]})
            raise ValueError(f"gpmc snapshot changed in {target}: {', '.join(changed)}; update only from canonical source")
    for name, expected_hash in lock["integration_files"].items():
        if digest(normalized(root / name)) != expected_hash:
            raise ValueError(f"Generated integration tool changed: {name}")
    if kind == "desktop":
        with zipfile.ZipFile(root / "src/PicHarbor.Core/GooglePhotos/gpmc_bundle.zip") as bundle:
            packaged = {n.removeprefix("gpmc/"): digest(bundle.read(n).replace(b"\r\n", b"\n"))
                        for n in bundle.namelist() if n.startswith("gpmc/") and not n.endswith("/")}
            if packaged != expected:
                raise ValueError("Desktop embedded ZIP has a stale/different gpmc package")
            bridge = root / "src/PicHarbor.Core/GooglePhotos/Embedded/gpmc_bridge.py"
            if bundle.read("gpmc_bridge.py").replace(b"\r\n", b"\n") != normalized(bridge):
                raise ValueError("Desktop ZIP bridge is stale")
    print(f"PASS: {kind} gpmc {lock['source_tree_sha256'][:16]}, {len(expected)} pinned files; offline verified")
    return lock


def synchronize(source, root):
    source, root = source.resolve(), root.resolve()
    kind, targets = layout(root)
    package = source / "gpmc"
    if package.resolve() in [p.resolve() for p in targets] or not (source / "pyproject.toml").is_file():
        raise ValueError("Source must be the independent canonical gpmc repository")
    files = package_files(package)
    if not {"api.py", "protocol.py", "live.py", "deadline.py", "NOTICE.md"} <= files.keys():
        raise ValueError("Incomplete canonical gpmc source")
    for target in targets:
        target.mkdir(parents=True, exist_ok=True)
        previous = package_files(target)
        # Only stale package files under the explicit consumer package are removed.
        for name in previous.keys() - files.keys():
            (target / name).unlink()
        for name, data in files.items():
            destination = target / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(data)
    scripts = {}
    for name in ("sync_gpmc.py",):
        data = normalized(source / "tools" / name)
        destination = root / "tools" / name
        destination.parent.mkdir(exist_ok=True)
        destination.write_bytes(data)
        scripts["tools/" + name] = digest(data)
    base = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    lock = {"schema_version": 1, "source": "Cc-Cece/gpmc", "source_base_commit": base,
            "note": "Content tree is authoritative; base commit may precede local integration changes. Do not edit vendored snapshots.",
            "source_tree_sha256": tree_id({n: digest(b) for n, b in files.items()}),
            "files": {n: digest(b) for n, b in files.items()}, "integration_files": scripts}
    (root / "gpmc.lock.json").write_bytes((json.dumps(lock, indent=2) + "\n").encode("utf-8"))
    if kind == "desktop":
        bundle_path = root / "src/PicHarbor.Core/GooglePhotos/gpmc_bundle.zip"
        with zipfile.ZipFile(bundle_path) as bundle:
            preserved = {n: bundle.read(n) for n in bundle.namelist() if not n.startswith("gpmc/") and not n.endswith("/")}
        preserved["gpmc_bridge.py"] = normalized(targets[0].parent / "gpmc_bridge.py")
        preserved.update({"gpmc/" + n: b for n, b in files.items()})
        with zipfile.ZipFile(bundle_path, "w", compression=zipfile.ZIP_DEFLATED) as bundle:
            for name, data in sorted(preserved.items()):
                info = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                bundle.writestr(info, data)
    # Existing platform manifests continue to pin non-gpmc dependencies.
    if kind == "ios":
        manifest_path = root / "Vendor/source-manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["source"] = "Canonical gpmc snapshot plus separately pinned blackboxprotobuf"
        manifest["note"] = "gpmc provenance/version is gpmc.lock.json; mobile.py is no longer vendored."
        manifest["files"] = [entry for entry in manifest["files"] if not entry["path"].startswith("gpmc/")]
        manifest["files"] += [{"path": "gpmc/" + name, "sha256": digest(data)} for name, data in files.items()]
        manifest_path.write_bytes((json.dumps(manifest, indent=2) + "\n").encode("utf-8"))
    if kind == "android":
        manifest_path = root / "app/src/main/assets/engine-extension.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["note"] = "Platform adapters are pinned here; gpmc is maintained centrally and pinned by gpmc.lock.json."
        names = {entry["path"] for entry in manifest["files"] if not entry["path"].startswith("gpmc/")}
        names.add("harbor_android.py")
        manifest["files"] = [{"path": name, "sha256": digest((root / "app/src/main/python" / name).read_bytes())} for name in sorted(names)]
        manifest_path.write_bytes((json.dumps(manifest, indent=2) + "\n").encode("utf-8"))
        (root / "app/src/main/assets/gpmc.lock.json").write_bytes((root / "gpmc.lock.json").read_bytes())
    check(root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, help="Explicit canonical checkout; updates the committed snapshot and lock")
    parser.add_argument("--target", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--check", action="store_true", help="Offline read-only check (default)")
    args = parser.parse_args()
    if args.source and args.check:
        parser.error("--source and --check are mutually exclusive")
    try:
        if args.source:
            synchronize(args.source, args.target)
        else:
            check(args.target)
    except (OSError, ValueError, KeyError, zipfile.BadZipFile) as error:
        print(f"gpmc verification failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
