"""Choose an available iPhone runtime compatible with the selected Xcode SDK."""
import json
import re
import subprocess


def version(text):
    parts = [int(part) for part in re.findall(r"\d+", text)]
    return tuple((parts + [0, 0, 0])[:3])


def select(devices, sdk_version):
    sdk = version(sdk_version)
    candidates = []
    for runtime, entries in devices.items():
        match = re.search(r"\.iOS-([\d-]+)$", runtime)
        if not match:
            continue
        release = version(match.group(1))
        if release[0] != sdk[0] or release < sdk:
            continue
        for device in entries:
            if device.get("isAvailable", True) and device.get("name", "").startswith("iPhone"):
                candidates.append((release, runtime, device["udid"]))
    if not candidates:
        raise RuntimeError(f"No available iPhone runtime matching iOS SDK {sdk_version}; install a matching simulator runtime")
    _, runtime, identifier = max(candidates)
    return runtime, identifier


if __name__ == "__main__":
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"], text=True).strip()
    devices = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"], text=True))["devices"]
    runtime, identifier = select(devices, sdk)
    print(f"id={identifier}\nruntime={runtime}")
