# Live Photo 协议验证记录

状态：开发验证。2026-10-19 用户反馈一个 HEIC Motion Photo 样本通过 Google Photos 动态显示及官方客户端保存回 iPhone 后的动态播放；逻辑任务仍停在云端确认，正在修复。证据只覆盖此次样本，不覆盖完整矩阵或苹果原始配对。

## Motion Photo 已实现的部分

- 从 PhotoKit 取得同一版本的照片和 pairedVideo；原始与当前版本分开处理，不用文件名猜配对。
- 从 QuickTime timed metadata 的 `com.apple.quicktime.still-image-time` 读取关键帧；找不到时明确失败，不静默取视频中点。
- ImageIO 复制图像编码并合并 Motion Photo XMP；JPEG 附加视频，HEIC 使用 mpvd box；以 1 MiB 块读写文件。
- 保留照片/视频源哈希和封装产物哈希；按逻辑资产确认所有版本。
- 云端哈希存在仅说明文件存在；还需完整图库快照中的动态标记、处理完成和非回收站状态，才将 Motion Photo 任务标为已备份。
- 自动测试已覆盖 JPEG、HEIC 容器和真实 QuickTime timed metadata。它们不是 Google Photos 接受该资源的证据。

## 苹果原始资源配对：尚无已验证的上传协议

检查范围：固定 `Vendor/gpmc/api.py`、`message_types.py`、媒体解析模型，MotionPhoto2 本地参考及上游公开文档。

当前 gpmc 的上传流程为 get_upload_token → upload_file → commit_upload。已有 commit_upload 的已知参数描述一个上传结果、文件名、内容哈希、时间和画质/设备信息，未提供可直接使用的苹果照片与视频关联操作。媒体解析模型的 is_micro_video 能识别动态标记，但不能据此推出上传配对协议。

MotionPhoto2 实现的是文件容器封装，也不能作为“苹果原始资源云端关联”的协议证据。因此当前能力声明 `apple_pair=false`，设置允许选择该开发目标，但相关任务报 `PAIR_PROTOCOL_UNVERIFIED`。不会分别上传两个普通文件并宣称完整，也不会暗中改用 Motion Photo。

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
