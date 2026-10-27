<div align="center">

<img src="Resources/Assets.xcassets/AppIcon.appiconset/icon.png" width="96" height="96" alt="PicHarbor Logo" />

# PicHarbor iOS

Native iOS client for Google Photos backup.

[![iOS](https://img.shields.io/badge/iOS-17.0+-000000?logo=apple&logoColor=white)](https://developer.apple.com/ios/)
[![Swift](https://img.shields.io/badge/Swift-5.0+-FA7343?logo=swift&logoColor=white)](https://swift.org)
[![Python](https://img.shields.io/badge/Python-3.13-3776AB?logo=python&logoColor=white)](https://python.org)
[![Release](https://img.shields.io/github/v/release/Cc-Cece/PicHarbor-iOS?color=007AFF&logo=github)](https://github.com/Cc-Cece/PicHarbor-iOS/releases)
[![License: GPL--3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)

<p align="center">
  <b>English</b> | <a href="README_ZH.md">简体中文</a>
</p>

</div>

---

PicHarbor is a native Google Photos backup client for iOS 17+. Built with SwiftUI and an embedded CPython runtime (`gpmc`), it combines native iOS PhotoKit and background URLSession to back up photos, videos, and Live Photos.

> [!NOTE]
> Designed for iOS 17.0+ on iPhone. Unsigned IPAs are built via GitHub Actions for self-signing and sideloading with personal developer certificates.

## Features

- **Media & PhotoKit support**: Browses and backs up photos, videos, and Live Photos via PhotoKit.
- **Background transfer pipeline**: Native `URLSession` file uploads with SQLite persistence, supporting phased concurrent uploads, pause, resume, retry, and task recovery.
- **Embedded Python runtime**: Sandboxed Python 3.13 and `gpmc` library handle Google Photos protocol operations and verification without requiring a Python installation on the device.
- **In-app proxy**: Integrated Clash Meta client supporting subscription URLs and local config imports, with dedicated routing policies.
- **Built-in SelfRefreshKit**: Supports on-device 7-day provisioning profile renewal over loopback and GitHub Releases OTA updates.
- **Localization**: Built-in Simplified Chinese, English, and Traditional Chinese (HK).

## Installation & Usage

1. Download the unsigned IPA from [Releases](https://github.com/Cc-Cece/PicHarbor-iOS/releases) or GitHub Actions artifacts.
2. Sign and install to your iPhone using [SelfRefreshSetup](https://github.com/Cc-Cece/SelfRefreshKit) (or Sideloadly / AltStore) with a free Apple ID.
3. Open the app on your iPhone, sign in to your Google account, and grant photo library access.
4. Configure backup preferences (album scope, upload policy) and start backing up.

## Development & Build

### Windows Development & CI Builds

The Xcode project is managed by `project.yml` (XcodeGen) and built via GitHub Actions:

1. Push Swift, Python, or project configuration changes to the repository.
2. The Actions **iOS Build (Unsigned IPA)** workflow sets up the Python iOS framework, bundles pure-Python dependencies, and packages the unsigned IPA.
3. Python standard libraries and extensions are embedded directly into the framework structure.

### Local Offline Testing

Run Python logic verification tests locally on Windows (requires Python 3.13):

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r Python/requirements.lock
.\.venv\Scripts\python.exe -m unittest discover -s tests_python -v
```

> [!NOTE]
> These tests use mock responses to verify state logic and error handling; they do not access live Google accounts.

## Project Structure

- `Sources/`: SwiftUI views, PhotoKit management, background upload pipeline, and CPython C API bridge
- `Python/`: iOS business logic layer (`harbor_ios.py`) and locked dependencies
- `Vendor/`: Google Photos gpmc protocol implementation and utilities
- `Runtime/`: Prebuilt Python and Clash xcframework binaries
- `Localization/`: Localization resources
