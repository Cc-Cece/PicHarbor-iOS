# Live Photo 协议验证记录

状态：开发验证。2026-10-19 用户反馈一个 HEIC Motion Photo 样本通过 Google Photos 动态显示及官方客户端保存回 iPhone 后的动态播放；逻辑任务仍停在云端确认，正在修复。证据只覆盖此次样本，不覆盖完整矩阵或苹果原始配对。

## Motion Photo 已实现的部分

- 从 PhotoKit 取得同一版本的照片和 pairedVideo；原始与当前版本分开处理，不用文件名猜配对。
- 从 QuickTime timed metadata 的 `com.apple.quicktime.still-image-time` 读取关键帧；找不到时明确失败，不静默取视频中点。
- ImageIO 复制图像编码并合并 Motion Photo XMP；JPEG 附加视频，HEIC 使用 mpvd box；以 1 MiB 块读写文件。
- 保留照片/视频源哈希和封装产物哈希；按逻辑资产确认所有版本。
- 云端哈希存在仅说明文件存在；还需完整图库快照中的动态标记、处理完成和非回收站状态，才将 Motion Photo 任务标为已备份。
- 自动测试已覆盖 JPEG、HEIC 容器和真实 QuickTime timed metadata。它们不是 Google Photos 接受该资源的证据。

## 苹果原始资源配对：0.2.4 实验实现，待本应用真机验收

后续研究已找到 gotohp 和 PhotosBackup 的实现。本应用新增联合提交（field 24）及先原图后关联视频（field 9）两种可选方式；有原图时联合模式自动使用补视频路径。两个原始资源哈希须查询到同一远端标识，之后仍需动态状态确认。实验能力不等于真机验收通过，Live Photo 清理仍关闭。源码快照见 LIVE-PHOTO-PROTOCOL-RESEARCH.md，测试步骤见 LIVE-PAIR-TESTING.md。

检查范围：固定 `Vendor/gpmc/api.py`、`message_types.py`、媒体解析模型，MotionPhoto2 本地参考及上游公开文档。

固定 gpmc 的普通 commit_upload 未提供苹果配对参数，0.2.4 在独立的 Python/harbor_live.py 增加适配，不直接修改 Vendor 快照。

MotionPhoto2 仍只作为容器封装参考。0.2.3 及之前的 apple_pair=false 和 PAIR_PROTOCOL_UNVERIFIED 为历史行为；0.2.4 声明 apple_pair=true、apple_pair_experimental=true，表示可执行实验路径，不表示官方往返验收已通过。

要继续实现这一目标，需要可验证的官方 iOS 上传关联请求/响应结构或能够复现同等关联的协议实现，并证明原始资源在云端确为同一个 Live Photo。仅凭字段猜测发送 RPC 不作为实现方案。协议证据必须脱敏，不收集登录令牌、签名下载地址或用户私人照片。

## 真机验收矩阵

HEIC 样本的云端动态及官方客户端往返已获得用户反馈。声音、HDR、关键帧等细项未逐项报告，下面保留待验收项；原始配对方式还须先完成协议实现。

| 样本 | Motion Photo | 苹果原始配对 |
| --- | --- | --- |
| 普通 HEIC + MOV，带声音 | HEIC 云端动态及官方客户端往返已反馈通过；声音/关键帧细项待验收 | 协议未验证 |
| JPEG + MOV | 待验收 | 协议未验证 |
| 修改关键照片 | 待验收 | 协议未验证 |
| 裁剪、旋转、调色后的对应版本 | 待验收 | 协议未验证 |
| HDR / 方向 / 拍摄时间 | 待验收 | 协议未验证 |
| 原始、编辑后都保留且正确去重 | 待验收 | 协议未验证 |

每个样本检查：云端是否为一个动态项目；播放、声音与关键帧；通过官方 Google Photos iOS 客户端保存回系统相册后，是否仍为可播放 Live Photo。记录 iPhone/iOS、客户端版本、上传画质、资源版本及结果。

未取得上述证据之前，两种方式均不授予 Live Photo 本地清理资格。应用不新增恢复 UI；“官方客户端可取回”仍是最终交付标准。

## 来源

- https://developer.android.com/media/platform/motion-photo-format
- https://github.com/xob0t/gpmc
- 本地 MotionPhoto2 来源、提交及许可证见 `MOTIONPHOTO2-REFERENCE.md`。
