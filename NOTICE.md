# 来源与许可证

## 2026-11-12 起的统一来源

gpmc 现由独立 `Cc-Cece/gpmc` 仓库统一维护，实际版本以根目录 `gpmc.lock.json` 的内容哈希为准；`Vendor/source-manifest.json` 同时用于核验发行包。包内 `gpmc/NOTICE.md` 与 `_licenses/` 保留原 MIT、导入的 PicHarbor GPL-3.0 及 Live Photo 参考许可。

`Python/harbor_protocol.py`、`harbor_live.py`、`harbor_deadline.py` 现在仅为统一模块的兼容导入。旧安卓 `Vendor/gpmc/mobile.py` 已移除。以下来源快照说明是历史记录，不再表示当前 gpmc 的维护方式。

## 历史来源记录

- SwiftUI 项目骨架来自 hoangnd107/ios-swiftui-app-template，原 MIT 许可保留于 `Vendor/TEMPLATE-LICENSE-MIT.txt`。
- gpmc 与 blackboxprotobuf 从只读的 PicHarbor 安卓项目工作树复制。上游线索为 https://github.com/xob0t/gpmc 。实际文件由 `Vendor/source-manifest.json` 中 SHA-256 固定，不声称为未经修改的上游提交。
- 安卓项目来源基线保留于 `Vendor/android-engine-baseline.json`；其中的旧来源提交不代表当前快照的完整内容。安卓目录没有可读取的 Git 仓库，本次不虚构其提交。
- 本项目采用来源项目的 GPL-3.0 许可证，全文见 `LICENSE` 与 `Vendor/SOURCE-LICENSE-GPL-3.0.txt`。保留复制文件中的版权声明；分发二进制时同时提供对应源码和构建说明。
- blackboxprotobuf 保留 NCC Group 的 MIT 声明；Python 依赖的发行元数据与许可证随包保留。
- Python iOS 运行环境来自 BeeWare Python-Apple-support 的固定发布，下载地址及校验值见 `tools/runtime-lock.json`。运行环境附带的许可文本随运行环境保留。
- iOS 适配为 `Python/harbor_ios.py` 和 `Sources/`；`Vendor/gpmc/mobile.py` 是安卓扩展，未用作 iOS 业务入口。Vendor 文件保持复制时内容不变。
- 原始 Live Photo 配对适配 `Python/harbor_live.py` 参考 xob0t/gotohp（`97a5dc0`）与 g8row/PhotosBackup（`3c88269`）的 MIT 实现和协议研究，包含前者的 result-item mask。来源与完整许可证见 `Vendor/LIVE-PAIR-REFERENCE-LICENSE-MIT.txt`；研究快照记录见 `docs/LIVE-PHOTO-PROTOCOL-RESEARCH.md`。未引入 gunshot 的 GPL 集成代码或替换固定 gpmc 快照。

本应用并非 Google 官方客户端，不承诺服务端配额或免费原画质结果。哈希匹配不等于安全清理资格；A/B 版本没有本地或云端删除入口。
