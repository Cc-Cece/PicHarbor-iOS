<div align="center">

<img src="Resources/Assets.xcassets/AppIcon.appiconset/icon.png" width="96" height="96" alt="PicHarbor Logo" />

# PicHarbor iOS

用于 Google 相册备份的原生 iOS 客户端。

[![iOS](https://img.shields.io/badge/iOS-17.0+-000000?logo=apple&logoColor=white)](https://developer.apple.com/ios/)
[![Swift](https://img.shields.io/badge/Swift-5.0+-FA7343?logo=swift&logoColor=white)](https://swift.org)
[![Python](https://img.shields.io/badge/Python-3.13-3776AB?logo=python&logoColor=white)](https://python.org)
[![Release](https://img.shields.io/github/v/release/Cc-Cece/PicHarbor-iOS?color=007AFF&logo=github)](https://github.com/Cc-Cece/PicHarbor-iOS/releases)
[![License: GPL--3.0](https://img.shields.io/badge/License-GPL--3.0-blue.svg)](LICENSE)

<p align="center">
  <a href="README.md">English</a> | <b>简体中文</b>
</p>

<p align="center">
  <a href="https://github.com/Cc-Cece/PicHarbor-iOS">GitHub 仓库</a> · <a href="https://github.com/Cc-Cece/PicHarbor-iOS/releases">发布版本</a>
</p>

<p align="center">
  相关项目：<a href="https://github.com/Cc-Cece/PicHarbor">Desktop</a> · <a href="https://github.com/Cc-Cece/PicHarbor-Android">Android</a>
</p>

</div>

---

PicHarbor 是一个面向 iOS 17+ 的 Google 相册原生备份客户端。采用 SwiftUI 原生界面，内嵌沙盒 CPython 运行环境（`gpmc`），结合 iOS 原生 PhotoKit 与后台 URLSession，实现照片、视频以及实况照片的备份。

> [!NOTE]
> 适用于 iOS 17.0+ iPhone。通过 GitHub Actions 构建无签名 IPA，使用者可通过个人开发者证书自行重签安装。

## 功能

- **相册与媒体支持**：通过 PhotoKit 浏览并备份照片、视频与 Live Photo。
- **后台传输管道**：原生 `URLSession` 文件上传，配合 SQLite 本地持久化，支持分阶段并发上传、暂停、继续、失败重试与任务保护。
- **内嵌 Python 运行环境**：内置沙盒 Python 3.13 与 `gpmc` 协议库，负责 Google 相册协议交互与上传确认，无需在用户设备上安装 Python。
- **应用内代理**：集成 Clash Meta，支持订阅链接及本地配置导入，提供独立的连接策略。
- **内置 SelfRefreshKit**：支持 7 天开发者证书手机端回环刷新与 GitHub Releases OTA 自更新。
- **多语言**：内置简体中文、English、繁体中文（香港）。

## 安装与使用

1. 从 [Releases](https://github.com/Cc-Cece/PicHarbor-iOS/releases) 或 Actions 构建产物中下载未签名 IPA 安装包。
2. 使用 [SelfRefreshSetup](https://github.com/Cc-Cece/SelfRefreshKit)（或 Sideloadly、AltStore）使用免费 Apple ID 进行签名并安装至 iPhone。
3. 在 iPhone 上打开应用，登录 Google 账号并授权相册访问权限。
4. 确认备份偏好（相簿范围、上传策略）后开始备份。

## 开发与构建

### Windows 开发与云端构建

Xcode 工程由 `project.yml`（XcodeGen）管理，通过 GitHub Actions 完成构建：

1. 编辑 Swift、Python 或项目配置并推送到仓库分支。
2. Actions **iOS Build (Unsigned IPA)** 工作流自动准备 Python iOS framework 与纯 Python 依赖，执行检查并打包无签名 IPA。
3. Python 标准库与扩展按 framework 方式打包进 IPA，不依赖设备端动态安装。

### 本地离线验证

在 Windows 环境下验证 Python 逻辑与测试（要求 Python 3.13）：

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r Python/requirements.lock
.\.venv\Scripts\python.exe -m unittest discover -s tests_python -v
```

> [!NOTE]
> 上述测试使用 Mock 数据验证状态逻辑与异常分支，不访问真实 Google 账号。

## 项目结构

- `Sources/`：SwiftUI 界面、PhotoKit 资产管理、后台上传管道与 CPython C API 桥接
- `Python/`：iOS 业务适配层（`harbor_ios.py`）与依赖锁定文件
- `Vendor/`：Google 相册 gpmc 协议实现及辅助工具
- `Runtime/`：Python 与 Clash 的 xcframework 二进制依赖
- `Localization/`：多语言本地化资源
