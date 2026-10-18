"""Xcode post-build: package stdlib + Python code and framework-format extensions.

Follows Python-Apple-support's build/utils.sh layout, but uses no distribution
identity. Simulator frameworks receive ad-hoc signatures; device frameworks are
left for the user's sideload tool to sign, including Python.framework.
"""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]


def copy_tree(source, target):
    shutil.copytree(source, target, dirs_exist_ok=True, ignore=shutil.ignore_patterns(
        "__pycache__", "*.pyc", "libpython*.dylib", "test", "tests", "idlelib", "tkinter", "turtledemo", "ensurepip"))


def main():
    app = Path(os.environ["TARGET_BUILD_DIR"]) / os.environ["WRAPPER_NAME"]
    runtime = ROOT / "Runtime/Python.xcframework"
    simulator = os.environ["EFFECTIVE_PLATFORM_NAME"] == "-iphonesimulator"
    slice_name = "ios-arm64_x86_64-simulator" if simulator else "ios-arm64"
    archs = os.environ["ARCHS"].split()
    if len(archs) != 1:
        raise RuntimeError("Build one architecture at a time (ONLY_ACTIVE_ARCH=YES)")
    stdlib = app / "python/lib"
    code = app / "app"
    for generated in (app / "python", code):
        if generated.exists():
            shutil.rmtree(generated)
    copy_tree(runtime / "lib", stdlib)
    copy_tree(runtime / slice_name / f"lib-{archs[0]}", stdlib)
    copy_tree(ROOT / ".python-deps", code)
    copy_tree(ROOT / "Python", code)
    for package in ("gpmc", "blackboxprotobuf"):
        copy_tree(ROOT / "Vendor" / package, code / package)
    # Preserve license/provenance in the distributed application too.
    copy_tree(ROOT / "Vendor", app / "Notices/Vendor")
    shutil.copy2(ROOT / "NOTICE.md", app / "Notices/NOTICE.md")
    template = plistlib.loads((runtime / "build/iOS-dylib-Info-template.plist").read_bytes())
    for extension in sorted(stdlib.rglob("*.so")):
        base = stdlib / "python3.13/lib-dynload"
        name = str(extension.relative_to(base)).split(".", 1)[0].replace("/", ".")
        framework = app / "Frameworks" / f"{name}.framework"
        framework.mkdir(parents=True, exist_ok=True)
        info = dict(template, CFBundleExecutable=name,
                    CFBundleIdentifier=os.environ["PRODUCT_BUNDLE_IDENTIFIER"] + "." + name.replace("_", "-"))
        (framework / "Info.plist").write_bytes(plistlib.dumps(info))
        origin = extension.with_suffix(".fwork").relative_to(app)
        shutil.move(extension, framework / name)
        (app / origin).write_text(f"Frameworks/{name}.framework/{name}\n")
        (framework / f"{name}.origin").write_text(f"{origin}\n")
        if simulator:
            subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(framework)], check=True)
    print(f"Embedded Python: {sum(p.stat().st_size for p in app.rglob('*') if p.is_file())} bundle bytes")


if __name__ == "__main__":
    main()
