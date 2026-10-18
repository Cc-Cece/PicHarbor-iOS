# PicHarbor iOS · A/B 验证版

SwiftUI 原生界面 + 内嵌 Python + gpmc，面向 iOS 17+ iPhone。开发者可在 Windows 编辑代码，由 GitHub Actions 的 macOS/Xcode 构建无签名 IPA，使用者自行重签安装。

当前范围是运行环境与前台单张照片闭环。**云端编译、模拟器测试、真机免费自签、Google 实际认证与上传分别验收，不能互相替代。** 状态见 [验收记录](docs/VALIDATION.md)。

2026-10-19：云端构建、打包检查、12 项离线测试和 2 项 iOS 模拟器测试通过；用户确认 Windows + Sideloadly 的首轮真机验证全部通过，三种上传模式符合预期。A、B 阶段已验收，后续批量任务、后台能力与安全清理尚不在当前范围内。

## 功能

- 检查 Python、TLS、SQLite、协议编解码与 gpmc 导入。
- Google EmbeddedSetup 网页登录与已有 gpmc 凭据导入；凭据保存在本机 Keychain，不写入 Python 数据库、诊断或云端构建环境。
- 通过 PhotoKit 导出一张普通照片的原始资源，前台计算哈希、查重、上传与提交。
- 提交后再次按内容哈希查询云端，未确认时保存为待确认，可单独重新核验。
- 当前账号最近 100 条记录持久化；重启后保留，账号隔离。中断的传输标记为中断，重新选择同一照片可查重重试。
- 导出不含账号、照片名称、哈希、云端 ID 或凭据的诊断报告，以及包体文件字节数。

首轮不支持视频、Live Photo、自动扫描、可靠后台传输或任何本地/云端删除。云端哈希存在不代表原件质量、复合资产完整性或安全清理资格。上传期间请保持前台。

## Windows 开发与云端构建

1. 修改 Swift、Python 或工程配置并推送到本仓库 main。
2. Actions 的 **iOS Build (Unsigned IPA)** 会准备固定版本的 Python iOS 运行环境，安装纯 Python 依赖，运行离线测试并构建 IPA。
3. 打包检查确认 Python.framework、TLS/SQLite 等扩展、证书包、源码哈希与 framework 标记存在后，上传 IPA artifact。
4. **Unit Tests (Simulator)** 可手动运行，测试真实嵌入的 iOS Python；PR 也会触发。
5. 构建完成不自动发布版本。确认需要分发时再推送版本标签，或手动运行 Release 工作流。

Xcode 工程由 `project.yml` 生成。Python 标准库与扩展按官方 framework 形式打包，不在用户设备上下载 Python 或执行 pip 安装。

## 安装与真机验收

从 Actions 下载 IPA，先选择 Sideloadly 或 AltStore Classic 的一种进行免费 Apple 账号重签，确保其签署所有嵌套 framework。个人签名通常 7 天有效，需按工具提示信任开发者、开启开发者模式（如需要）并续签。

进入应用后依次完成 A 环境检查、Google 登录、普通照片上传、再次选择同一照片验证查重、退出重开验证记录保留。详细步骤与失败报告要求见 [真机验收表](docs/VALIDATION.md)。

Google 可能拒绝嵌入式网页登录或要求额外设备验证。已有凭据导入仅为协议验证备用入口，不证明 iOS 网页登录已经通过；不会规避服务端验证。不要将任何凭据提交到仓库或发送到聊天。

## 本地离线验证

使用 Python 3.13：

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r Python/requirements.lock
.\.venv\Scripts\python.exe -m unittest discover -s tests_python -v
```

上述测试使用模拟网络响应，验证状态逻辑与失败边界，不访问真实 Google 账号。Windows 上通过不代表 iOS 运行环境通过。

## 来源与更新

- `Vendor/`：从安卓参考项目复制的固定快照，包含已有修改；并非声称为纯上游。文件清单与 SHA-256 见 `Vendor/source-manifest.json`。
- `Python/harbor_ios.py`：iOS 业务适配，不修改 Vendor 源码。
- `Sources/Bridge/`：CPython C API 桥接，主线程初始化、串行后台调用。
- `tools/runtime-lock.json`：固定 Python 3.13 iOS 运行环境及下载 SHA-256。
- `Python/requirements.lock`：固定依赖；发布时保留发行元数据与许可。

更新 gpmc 时先审查与安卓扩展的差异，更新固定快照和哈希，再运行离线、模拟器及真机回归，最后重新打包。上游更新不自动保证现有接口和认证兼容。

## 成本与许可证

公开仓库使用标准 GitHub 托管 runner 的运行费用可免费，产物与缓存应合理保留；私有仓库受账户额度限制。不要求购买 Mac 或付费 Apple 开发者账号。

本项目遵循来源项目的 [GPL-3.0](LICENSE)；模板原 MIT 许可与第三方声明保留于 [NOTICE.md](NOTICE.md) 和 Vendor。分发 IPA 时应同时提供对应源码与构建说明。本应用不是 Google 官方客户端，不承诺上传配额结果。
