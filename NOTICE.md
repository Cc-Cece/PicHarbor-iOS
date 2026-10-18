# 来源与许可证

- SwiftUI 项目骨架来自 hoangnd107/ios-swiftui-app-template，原 MIT 许可保留于 `Vendor/TEMPLATE-LICENSE-MIT.txt`。
- gpmc 与 blackboxprotobuf 从只读的 PicHarbor 安卓项目工作树复制。上游线索为 https://github.com/xob0t/gpmc 。实际文件由 `Vendor/source-manifest.json` 中 SHA-256 固定，不声称为未经修改的上游提交。
- 安卓项目来源基线保留于 `Vendor/android-engine-baseline.json`；其中的旧来源提交不代表当前快照的完整内容。安卓目录没有可读取的 Git 仓库，本次不虚构其提交。
- 本项目采用来源项目的 GPL-3.0 许可证，全文见 `LICENSE` 与 `Vendor/SOURCE-LICENSE-GPL-3.0.txt`。保留复制文件中的版权声明；分发二进制时同时提供对应源码和构建说明。
- blackboxprotobuf 保留 NCC Group 的 MIT 声明；Python 依赖的发行元数据与许可证随包保留。
- Python iOS 运行环境来自 BeeWare Python-Apple-support 的固定发布，下载地址及校验值见 `tools/runtime-lock.json`。运行环境附带的许可文本随运行环境保留。
- iOS 适配为 `Python/harbor_ios.py` 和 `Sources/`；`Vendor/gpmc/mobile.py` 是安卓扩展，未用作 iOS 业务入口。Vendor 文件保持复制时内容不变。

本应用并非 Google 官方客户端，不承诺服务端配额或免费原画质结果。哈希匹配不等于安全清理资格；A/B 版本没有本地或云端删除入口。
