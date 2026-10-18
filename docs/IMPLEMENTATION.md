# 完整应用实施与验收台账

基线：2026-10-19 用户批准完整实施计划。旧 A/B 验收记录继续有效，但不扩展为新功能已通过真机测试。

0.2 开发版的 IPA、自动检查链接和剩余验收清单见 `DEVELOPMENT-ACCEPTANCE.md`。当前是阶段交付，不代表六阶段全部完成。

## 已确认规则

- 独立原生 iPhone 应用，iOS 17+；SwiftUI、原生任务与媒体处理、内嵌 Python/gpmc 协议适配。
- 只做备份与本地清理，不开发恢复界面；官方 Google Photos 客户端负责取回。
- 默认 original（不计配额原画质）、Motion Photo、原始与编辑后均保留、仅 Wi-Fi；首次确认范围后启用自动备份。
- 两个版本内容不同分别显示，完全相同去重；Live Photo 不能混用版本。切换策略只影响新任务，旧内容手动重新备份，不删除旧云端项目。
- 可选单向相簿同步默认关闭。媒体与相簿步骤分别持久化，不因相簿失败重新传媒体。
- 默认完整清理采用安卓标准：内容匹配、最新云端状态、原件访问及大小；不默认完整下载云端原件。高级用户可分别关闭后两项，需确认且持续显示降低的强度。
- 核验证据绑定账号、资源、版本、策略，五分钟失效；删除前重新读取检查；用户确认和系统确认均保留。
- 原型只在本机维护。GitHub Actions 原生构建继续使用 Cc-Cece/PicHarbor-iOS，Sideloadly 自签。

## 架构约束

Swift `BackupStore` actor 是 backup-v2.sqlite 唯一写入者。Python observations.sqlite 仅承载兼容历史观察记录，不写新任务。Keychain 按账号存储凭据，数据库不存可复用认证或上传签名 URL。

桥接 v2 使用 protocol_version、request_id 与结构化 failure。prepare_upload 返回内存传输计划，后台 URLSession 负责文件上传；响应落入受保护 Staging 文件，原生持久化后再调用 commit_resource、confirm_resource。传输凭据由系统 URLSession 管理，不放入业务数据库或诊断。

任务保留设置快照；状态覆盖排队、准备、传输、提交、确认、完成、暂停、等待、失败、需处理、取消。提交不明先查远端，启动协调系统任务和磁盘回执，不清空仍在使用的文件。

gpmc Vendor 文件保持固定快照。本轮适配在 Python/harbor_protocol.py 和原生代码，不覆盖 Android、MotionPhoto2 或上游文件。

## 实施阶段

1. 基线与两种 Live Photo 协议/封装验证。
2. 原生持久化、账号迁移、后台传输和恢复。
3. PhotoKit 图库、资源版本、增量发现、备份和相簿。
4. 认可 UI 的完整原生实现与异常状态。
5. 严格核验、可配置策略及本地清理。
6. 大图库、大文件、后台和升级验收；最终打包交付。

## 尚未证明，不能标为完成

Live Photo 的具体协议线索和逐项验收表见 `LIVE-PHOTO-VALIDATION.md`。

- 苹果原始资源在 Google Photos 的真实云端关联协议。当前 capability apple_pair=false，任务明确报 PAIR_PROTOCOL_UNVERIFIED；不会发送猜测 RPC 或分别上传两个独立文件冒充支持。
- 两种方式的官方 Google Photos iOS 客户端保存回相册后，动态、声音、关键帧、HDR、编辑版本正确性。
- Live Photo 清理资格：没有完整配对/取回证据前，一律保留原件。
- 真机后台、权限变化、iCloud、安装升级及规模测试，需安装新 IPA 后逐项记录。
- 旧云端网页撤销仍未证实完成，与本轮原生构建无关。

## 真机样本与步骤

使用可删除的专用测试相簿，包含 JPEG、HEIC、视频（H.264/HEVC）、普通 Live、带声音 Live、重新选择关键帧、裁剪/旋转/调色视频和照片、HDR Live、iCloud-only 原件，以及原始与当前版本相同的项目。

每种 Live 方式分别记录：iPhone/iOS、Google Photos 版本、上传画质、资产版本、云端是否单个动态项目、声音/关键帧/方向/时间/HDR、通过官方客户端保存回相册后是否仍为 Live。未完成的格子写“待验收”，不能只以 hash 查询成功替代。

后台测试：传输中锁屏/切后台、断网恢复、系统终止后重开、设备重启、授权过期、磁盘不足；确认不丢任务、不错误完成、不重复提交。规模基线为万级图库与超过 4 GiB 视频；64 位长度单元测试不等于真实大文件验收。

清理测试：先用普通照片验证云端回收站、处理中、大小不符、访问失败、资源变化、策略变化、确认取消与系统拒绝；均不得误删。删除成功由系统与图库变化共同核对，权限减少不能视为成功。

## 上游更新流程

记录候选提交 → 与固定快照及 Android 差异对照 → 更新来源哈希 → 运行离线协议测试、原生测试 → 三画质和重复/失败场景真机回归 → 才更新内置版本。不得在客户端运行时自动下载或替换可执行 Python 代码。

## 技术参考

- https://developer.android.com/media/platform/motion-photo-format
- https://developer.apple.com/documentation/foundation/downloading-files-in-the-background
- https://developer.apple.com/videos/play/wwdc2022/10132/
- https://github.com/xob0t/gpmc

MotionPhoto2 本地来源与移植限制见 MOTIONPHOTO2-REFERENCE.md。本轮未复制其代码，不依赖桌面 ExifTool。
