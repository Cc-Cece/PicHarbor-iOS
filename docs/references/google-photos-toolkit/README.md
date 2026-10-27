# Google Photos Toolkit 参考资料与分析总结

记录日期：2026-10-19。按用户要求，仅保存脚本副本与分析，不集成功能、不执行脚本、不调用真实账号接口、不提交或编译。

## 文件来源

- 原始文件：`C:\Users\Kanbara\Downloads\akihito\google_photos_toolkit.user.js`
- 原样副本：[google_photos_toolkit.user.js](google_photos_toolkit.user.js)
- 大小：194,370 字节。
- SHA-256：`32691cd2eba6a4a161beace80d239d031921e687a99787fc6519f01fb3388302`。副本与原文件一致。
- 文件头自报名称：Google Photos Toolkit（中文版），版本 `3.3.1-zh`，作者 `xob0t`，许可声明 `MIT`。
- 文件头主页：https://github.com/yihuochejialao/Google-Photos-Toolkit
- 文件头命名空间：https://github.com/xob0t/Google-Photos-Toolkit

这些来源信息取自本地文件头，未据此断言副本与某个上游提交完全一致。以下结论来自静态代码分析，不能替代当前接口可用性、账号权限和真机测试。

## 接口体系

脚本封装 36 个业务方法，对应 32 个不同 RPC 标识。主要向以下网页内部入口发送请求：

```text
https://photos.google.com{path}data/batchexecute
```

请求包含 `f.req`、`at`，以及 `rpcids`、`f.sid`、`bl`、`source-path` 等参数，通过 `credentials: include` 使用浏览器 Cookie；参数取自当前网页的 `WIZ_global_data`。锁定文件夹相关请求还可能携带 `rapt`。脚本要求先进入相应锁定文件夹页面，不是绕过认证。

这是网页内部 RPC，不是公开的 Photos Library API，也不是 PicHarbor 现有 gpmc 移动端协议。公开 Library API 的服务入口为 `photoslibrary.googleapis.com`，见 [Google 官方参考](https://developers.google.com/photos/library/reference/rest)。

## 封装的能力

| 类别 | RPC 标识 | 能力 |
|---|---|---|
| 图库与搜索 | `lcxiM`、`EzkLib` | 按拍摄或上传时间读取、搜索、收藏及云端归档内容 |
| 哈希匹配 | `swbisb` | 批量查询哈希对应的云端项目 |
| 单项详情 | `VrseUb`、`fDcn4b` | 文件名、大小、日期、来源、相册、画质、空间占用等 |
| 批量详情 | `EWgK9e` | 批量查询文件名、大小、描述、画质与空间占用 |
| 相册 | `Z5xsfc`、`snAcKc`、`OXvT9d`、`E1Cajb`、`ycV3Nd`、`QD9nKf` | 列表、成员、创建、添加、移除、排序 |
| 共享内容 | `F2A0H`、`laUYf`、`LjmOue`、`V8RKJ`、`Es7fke`、`e9T5je` | 共享链接、共享相册、保存共享及伴侣共享内容 |
| 收藏与云端归档 | `Ftfh0`、`w7TP3c` | 设置与取消收藏、归档 |
| 回收站 | `zy0IHe`、`XwAOJf` | 查询、移入回收站、恢复 |
| 锁定文件夹 | `nMFwOc`、`StLnCe`、`Pp2Xxe` | 查询、移入、移出 |
| 下载 | `pLFTfd`、`yCLA7`、`dnv2s` | 下载地址、下载任务令牌、结果及大小查询 |
| 容量 | `EzwWhf` | 总用量、总容量、Google 相册占用 |
| 元数据修改 | `EtUHOe`、`DaSgWe`、`AQNOFd` | 位置修改或删除、日期修改、描述修改 |

“有 API 方法”不等于“主界面已经使用”。批量哈希查询、部分下载、位置及伴侣共享接口在本文件中主要是封装，未见主流程调用；API 对象被暴露到 `window.gptkApi` 供交互使用。

上层流程还实现日期、尺寸、时长、文件名、描述、画质、配额、位置等筛选，相似图片分组、从文件名提取日期并修改云端时间，以及 CSV 元数据导出。

## 对 PicHarbor 最有参考价值的部分

### 1. 批量云端查重

`getRemoteMatchesByHash()`（约第 1274 行）向 `swbisb` 发送多个哈希，解析对应云端项目及部分信息。可研究减少逐张查重的网络往返，并辅助区分查询未命中与接口异常。

尚未验证哈希编码、返回完整性和动态视频的匹配语义，不能直接当作现有 Live Photo 双哈希配对查询的替代品。

### 2. 单项 Live Photo 信息与视频下载地址

`itemInfoParse()`（约第 1048 行）解析：

- `isPartialUpload`：部分上传标记。
- `isLivePhoto`、`livePhotoDuration`：动态标记与时长。
- `downloadUrl`、`downloadOriginalUrl`：下载与原件下载地址。
- `livePhotoVideoDownloadUrl`：动态视频下载地址。

关联方法是 `getItemInfo()`（`VrseUb`，约第 1673 行）。可研究针对已知云端项目直接查询，减少为确认单项内容而扫描整个云端图库的需要。动态视频地址也是研究配对视频访问能力的线索。

出现动态标记或下载地址，不代表原始配对资源已经完整，也不能证明保存回 iPhone 后一定可恢复动态效果；下载得到的是否为原始视频、大小和编码是否一致，均需验证。

### 3. 云端实际画质和配额信息

解析器区分 `isOriginalQuality`、`takesUpSpace`、`spaceTaken`。可研究用于高级信息，区分“任务选择的上传模式”与“云端当前返回的结果”，不能将一次返回值理解为永久不计配额保证。

### 4. 相册同步细节

普通相册与共享相册采用不同操作；相册成员标识、图库 `mediaKey` 与 `dedupKey` 不能随意混用。可参考成员添加、独立重试和排序规则，不必因此扩展为完整共享相册管理器。

### 5. 并发、筛选与整理

脚本采用分批和并发池，默认单项请求并发 3、批量请求并发 3；操作批次 250、锁定文件夹批次 100、批量信息请求批次 5000。这些是脚本配置，不是已证明适合 iOS 的限额。

相似图片使用缩略图 dHash 与汉明距离，适合作为相似内容整理参考，不能作为文件完全一致、完整备份或允许删除的证据。

## 当前登录能否直接调用

结论：按脚本原样调用，目前保存的鉴权信息不够；移动端等价接口仍可优先研究。

当前 PicHarbor 登录流程为：

1. `Sources/Features/GoogleLoginView.swift` 使用临时 `WKWebsiteDataStore.nonPersistent()` 打开 `EmbeddedSetup`。
2. 取得 `oauth_token` 后停止页面并返回登录结果。
3. `Vendor/gpmc/auth.py` 将其交换成可复用的移动端认证数据。
4. 凭据按账号保存在 Keychain，gpmc 再取得 Bearer Token 调用移动端协议。

当前没有持久保存相册网页完整 Cookie、页面会话参数，也没有实现移动凭据到网页会话的转换。不能因为登录过程出现网页，就认为已有脚本所需的网页会话；也不能仅凭同属 Google 就假定令牌可以互换。[Google OAuth 说明](https://developers.google.com/identity/protocols/oauth2/)

建议优先沿用现有登录：参考脚本字段和请求结构，寻找移动端等价的批量查重、单项详情和视频下载能力。现有 `Vendor/gpmc/api.py` 已含哈希查重、图库状态、下载地址、相册、描述、收藏、云端归档和回收站等相关封装，但这不代表这些能力全部暴露在 PicHarbor 界面中。

若移动端确实缺少关键能力，再考虑独立网页查询会话：需要验证相册网页登录、账号对应、会话过期和退出清理。不能承诺无感复用现有登录，也没有证据断言所有网页 RPC 一律拒绝 Bearer Token。

## 不宜直接照搬的行为与边界

- 分页失败会停止并返回已取得的部分结果；用于备份核验时必须另有完整性标记，不能将未读取到解释为不存在。
- 批量请求异常后记录日志并跳过，不能直接当作可靠备份状态机。
- 注释写指数退避，实际等待约为 2 秒、4 秒的线性增长；读写操作的重试应分开考虑，不能无条件重放云端修改。
- 解析依赖内部数组位置和扩展字段。缺失字段应视为未知，不能自动判定“不是 Live Photo”或“没有备份”。
- 脚本的归档修改 Google 相册中的照片状态，与 PicHarbor 收起本地活动记录的归档不同。
- CSV 包含照片名称、位置、云端标识及缩略图地址等，不能直接替代应用现有脱敏诊断。
- 未发现本地媒体上传、Live Photo 上传配对、iPhone 本地释放空间或系统原生分享的实现。

建议研究顺序：`swbisb` 批量查重 → `VrseUb` 单项动态信息与视频地址 → 批量画质／配额信息。保持 gpmc 上传链路，不因此恢复自研本地清理、增加云端删除或建设完整云端图库。本记录仅供后续讨论与验证，不授权执行这些扩展功能。
