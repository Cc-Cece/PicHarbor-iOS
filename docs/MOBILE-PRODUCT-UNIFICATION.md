# 手机端产品统一

当前产品蓝本固定为 `90ac7e1`，保持现有四栏和主要交互；后续整合分支只作为核心接入与缺陷修复的可复用来源。
iOS 应用身份、用户数据与原生 UI 保留。Android 作为新应用在原仓库重建。

共同规范及两端完成度以中央记录为准：

- [移动端共同产品规范](https://github.com/Cc-Cece/gpmc/blob/feat/mobile-product-unification/docs/MOBILE-PRODUCT-CONTRACT.md)
- [2026-11-17 实施记录](https://github.com/Cc-Cece/gpmc/blob/feat/mobile-product-unification/docs/MOBILE-IMPLEMENTATION-2026-11-17.md)

本轮将核心快照从独立 JSON 文件兼容导入 BackupStore，增加修订检查和持续诊断日志。
日志默认常开，14 天/64 MiB；设置支持日期范围导出 JSONL 与同源文本 ZIP。
本轮开发实现已完成，最终功能源码为 `e0c495c`，共享核心内容哈希为 `0a4472b9ffd4537b`。生产代理、版本、范围、流水线与执行策略接入共享核心；原生存储核对完成证据和修订号。无签名 IPA 构建及最终产物见中央交付记录。用户要求自行测试，本轮不运行测试，不声明 iPhone 或真实云端验收通过。
