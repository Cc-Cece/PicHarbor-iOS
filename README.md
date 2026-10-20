# PicHarbor iOS · 原生备份开发版

SwiftUI 原生界面 + 内嵌 Python + gpmc，面向 iOS 17+ iPhone。开发者可在 Windows 编辑代码，由 GitHub Actions 的 macOS/Xcode 构建无签名 IPA，使用者自行重签安装。

当前正在实施完整原生应用。**云端编译、模拟器测试、真机免费自签、Google 实际认证与上传分别验收，不能互相替代。** A/B 历史状态见 [验收记录](docs/VALIDATION.md)，新版本状态见 [实施与验收台账](docs/IMPLEMENTATION.md)。

开发版产物、自动测试证据与剩余事项见 [开发版验收说明](docs/DEVELOPMENT-ACCEPTANCE.md)。0.2.12 使用真机验证的链接直达 Google 相册释放空间，两种备用路径默认折叠，临时链接测试页已移除，见[本轮说明](docs/GOOGLE-PHOTOS-DIRECT-0212.md)。原始配对的[测试步骤](docs/LIVE-PAIR-TESTING.md)继续适用。完整格式和规模矩阵仍待验收，不将整个计划标为完成。

当前版本 0.2.23：备份进行中显示[当前上传速度与预计时间](docs/TRANSFER-METRICS.md)，保留正在处理任务优先排序、大队列恢复保护和性能优化，见[修复与验收](docs/LARGE-QUEUE-RECOVERY.md)。保留应用内代理的全部节点测速、手动／自动选路、订阅管理和任务独立策略，见[使用说明](docs/IN-APP-PROXY.md)。目标安装包：`dist/PicHarbor-0.2.23.ipa`。包含简体中文、English、粵語（香港），使用原 Sideloadly 配置覆盖安装；大队列真机验证仍待完成。

保留[分享及重复备份检查](docs/SHARING-DEDUP-0214.md)、[界面及归档功能](docs/INTERFACE-ARCHIVE-0213.md)。

默认采用标准确认：原始配对仍要求照片和视频分别查询后指向同一个云端项目；高级设置可额外启用严格动态确认，蓝色等待仅用于已通过配对、仍在严格确认的任务。旧任务可明确选择应用当前确认策略，无需重传。本机清理由官方 Google 相册执行，PicHarbor 不再扫描或删除照片。

2026-10-19：旧 A/B 版本已通过云端检查和用户真机验证，三种上传模式符合预期。完整实施已获批准，新版增加原生图库、任务持久化、后台文件传输、Motion Photo 封装与四入口界面；这些新增能力需要独立验收。

UI 已获得用户认可，网页原型仅本机预览，不部署或同步源码。需求见 [需求基线](docs/REQUIREMENTS.md)，封装参考见 [MotionPhoto2 记录](docs/MOTIONPHOTO2-REFERENCE.md)。

## 功能

- 检查 Python、TLS、SQLite、协议编解码与 gpmc 导入。
- Google EmbeddedSetup 网页登录与已有 gpmc 凭据导入；凭据保存在本机 Keychain，不写入 Python 数据库、诊断或云端构建环境。
- 应用内代理仅用于 PicHarbor：Clash Meta 订阅、相机扫码、相册选码、本地文件导入、配置切换与手动更新；保留全局及任务独立连接策略。后台连接可能暂停，返回后继续。
- PhotoKit 直接浏览照片、视频、Live Photo、用户相簿，处理完整与有限授权。
- SQLite 持久化账号设置、资产索引、资源版本、任务和核验证据；支持批量、暂停、继续、重试与账号隔离。
- 后台 URLSession 文件上传，原生读取/哈希/封装；Python 负责协议准备、提交与独立确认。
- 默认不计配额原画质、原始照片配对、原始与编辑后版本均保留；保留已有设置。确认范围后可启用自动备份，可选单向相簿同步。
- 直达官方 Google 相册释放设备空间，备用操作指引默认折叠；原生资产删除执行已移除，历史设置和记录兼容读取。
- 导出不含账号、照片名称、哈希、云端 ID、签名地址或凭据的诊断报告。

**尚未完整交付：** 原始资源联合提交及先原图后关联视频已接入并获得初步真机反馈；完整格式、同机识别、官方取回和配额矩阵仍待记录，服务器拒绝或关联不明会明确显示。Motion Photo 的一个 HEIC 样本已获云端动态及官方取回反馈，完整样本矩阵仍待验收。官方本机清理已获用户单个原始配对 Live Photo 实测，不扩展为所有格式保证。真实直达链接已通过用户 iPhone 测试，本轮应用内入口仍需安装后验收。应用没有云端删除与恢复功能。后台执行由系统安排，不保证即时。

## Windows 开发与云端构建

1. 修改 Swift、Python 或工程配置并推送到本仓库 main。
2. Actions 的 **iOS Build (Unsigned IPA)** 会准备固定版本的 Python iOS 运行环境，安装纯 Python 依赖，运行离线测试并构建 IPA。
3. 打包检查确认 Python.framework、TLS/SQLite 等扩展、证书包、源码哈希与 framework 标记存在后，上传 IPA artifact。
4. **Unit Tests (Simulator)** 可手动运行，测试真实嵌入的 iOS Python；PR 也会触发。
5. 构建完成不自动发布版本。确认需要分发时再推送版本标签，或手动运行 Release 工作流。

Xcode 工程由 `project.yml` 生成。Python 标准库与扩展按官方 framework 形式打包，不在用户设备上下载 Python 或执行 pip 安装。

## 安装与真机验收

从 Actions 下载 IPA，先选择 Sideloadly 或 AltStore Classic 的一种进行免费 Apple 账号重签，确保其签署所有嵌套 framework。个人签名通常 7 天有效，需按工具提示信任开发者、开启开发者模式（如需要）并续签。

安装新版后，连接 Google、允许相册访问、确认备份范围和偏好，再使用专用测试相簿验证普通照片、视频、Live Photo、暂停重启及清理。新增验收步骤见 [实施台账](docs/IMPLEMENTATION.md)，旧版证据见 [真机验收表](docs/VALIDATION.md)。

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
