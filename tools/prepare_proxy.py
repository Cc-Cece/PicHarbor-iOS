"""Fetch the pinned public Apple SDK, verifying the published SHA-256."""
from pathlib import Path
import hashlib
import os
import plistlib
import shutil
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
TAG = 'v1.19.32-clash.3'
BASE = 'https://github.com/ProjectClash/Clash/releases/download/' + TAG + '/'
FILES = {
 'Clash.xcframework.zip': 'fbee3cf05b24de4e1b35d0f87f3510832a05ab04d7e3226494126527acadb756',
 'SOURCES.json': 'ce6227d4376683fc94663d8501ad3851a428ae407e103524fb86a0a96a389223',
 'THIRD_PARTY_LICENSES.zip': '60bf640a1e7e841f3521536142ce11e8c1028f560ad773f3a18b123a77fbdb2b',
}

def prepare():
    cache = ROOT / '.runtime-cache'; cache.mkdir(exist_ok=True)
    runtime = ROOT / 'Runtime'; runtime.mkdir(exist_ok=True)
    notices = runtime / 'ProxyNotices'; notices.mkdir(exist_ok=True)
    for name, digest in FILES.items():
        path = cache / ('clash3-' + name)
        if not path.exists() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            temporary = path.with_suffix(path.suffix + '.part')
            with urllib.request.urlopen(BASE + name, timeout=90) as source, temporary.open('wb') as target:
                shutil.copyfileobj(source, target)
            if hashlib.sha256(temporary.read_bytes()).hexdigest() != digest:
                raise RuntimeError('Proxy SDK hash mismatch: ' + name)
            temporary.replace(path)
        if name != 'Clash.xcframework.zip': shutil.copyfile(path, notices / name)
    with zipfile.ZipFile(cache / 'clash3-Clash.xcframework.zip') as archive:
        for entry in archive.infolist():
            parts = Path(entry.filename).parts
            if '..' in parts or entry.filename.startswith('/'):
                raise RuntimeError('Invalid SDK archive path')
            # Keep only iPhone device/simulator slices and framework metadata.
            if 'Clash.xcframework' not in parts: continue
            start = parts.index('Clash.xcframework'); relative = Path(*parts[start:])
            if len(relative.parts) > 1 and relative.parts[1] not in ('Info.plist', 'ios-arm64', 'ios-arm64_x86_64-simulator'): continue
            destination = runtime / relative
            if (entry.external_attr >> 16) & 0o170000 == 0o120000:
                if os.name != 'nt' and not destination.is_symlink():
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    if destination.exists(): destination.unlink()
                    os.symlink(archive.read(entry).decode(), destination)
                continue
            if entry.is_dir(): destination.mkdir(parents=True, exist_ok=True)
            else:
                destination.parent.mkdir(parents=True, exist_ok=True)
                with archive.open(entry) as source, destination.open('wb') as target: shutil.copyfileobj(source, target)
    info = runtime / 'Clash.xcframework/Info.plist'
    metadata = plistlib.loads(info.read_bytes())
    metadata['AvailableLibraries'] = [item for item in metadata['AvailableLibraries'] if item['LibraryIdentifier'] in ('ios-arm64', 'ios-arm64_x86_64-simulator')]
    info.write_bytes(plistlib.dumps(metadata))
    print('Pinned Clash Apple SDK verified:', TAG)

if __name__ == '__main__': prepare()
