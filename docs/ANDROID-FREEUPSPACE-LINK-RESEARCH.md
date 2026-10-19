# 从安卓快捷操作定位 Google 相册 iOS 释放空间链接

日期：2026-10-19。本轮研究不修改 PicHarbor 应用代码，不触发照片上传、删除或云端清理。

## 已确认结论

**`https://photos.google.com/link/freeupspace` 能在用户当前 iPhone 上直接打开 Google 相册“释放空间”页。** 用户按照备忘录或消息中点击链接的测试要求，反馈“直接进入 Google 相册释放空间页”；未要求执行清理。

这条链接具备三层依据：设备中安装的安卓程序声明及代码、Google 公开的 iOS Universal Links 配置、用户 iPhone 实测。不是此前猜测的 `googlephotos://freeupspace` 等 scheme 路径。

## 安卓取证

- ADB 连接的设备为 Android 14；当前安装的 Google 相册版本为 `7.95.0.989626323`。这是该设备安装包的实测，不声称为未经修改的上游原版或所有版本行为。
- 使用 `dumpsys shortcut -p com.google.android.apps.photos` 读取目标包快捷操作。首个位置参数查询未按预期过滤，该结果未保存为研究产物；后续采用包过滤，只保留目标包所需字段。
- “释放空间”快捷操作标识为 `manifest_auto_free_up_space`，启动 `com.google.android.apps.photos.settings.SettingsActivityV2`，附带 `auto_free_up_space=true` 及设备账号选择字段 `account_id`。不保存或复用账号字段的实际值。
- 该 Settings Activity 声明 `exported=false`，快捷操作本身使用 Android Intent，并未携带 URL。因此不能将 Activity 名称或参数直接当成 iOS 链接。
- 只读提取安装包，使用 Android SDK 的 `aapt2` 与 `dexdump` 检查清单和相关字节码。`HomeDeepLinkActivity` 声明 `exported=true`，接受 `http/https`、主机 `photos.google.com` 及路径 `/link/freeupspace`。
- `classes2.dex` 中的 `aheh` 类有对应 URI matcher 和页面启动处理；同时发现 `PhotosCheckItemsEligibleForFreeUpSpace` RPC 名称，但未调用该接口，也不据此恢复自建清理功能。

安装包 SHA-256：`见本机 build/research-android-shortcuts/evidence.json`。安装包和反汇编材料仅保存在被忽略的 `build/research-android-shortcuts/`，不提交或分发第三方 APK。

## iOS 官方关联配置

读取 [Google 公开 AASA 文件](https://photos.google.com/.well-known/apple-app-site-association)，正式版项明确包含：

```json
{"appID":"EQHXZ8M8AV.com.google.photos","paths":["/link/freeupspace"]}
```

以上为相关字段摘录，非完整配置。`/u/*/link/freeupspace` 虽在安卓清单中出现，本轮未在 iOS 正式版配置中确认，不新增此类账号变体。

推荐使用 HTTPS Universal Link。直接输入 Safari 地址栏、同域网页导航、内置浏览器或用户曾选择留在浏览器等情况，可能影响 App 接管；PicHarbor 后续可通过 `UIApplication.open` 的 `universalLinksOnly` 方式尝试，失败时保留长按图标及应用内路径指引。系统回调接受请求仍不能证明目标页，本次页面结论来自用户实测。

## 真机结果与产品方向

- 用户报告：原临时页仅 `googlephotos://` 能启动，其余 6 个猜测路径未能直达。此结论限定于用户当前设备及版本组合。
- 用户发现并认可主屏幕／App 资源库长按 Google 相册 →“释放空间”可作为简短指引；常规应用内路径作为备用。
- 本轮新增 HTTPS 链接已获用户直接到达目标页反馈；测试时具体 Google 相册版本、冷启动／后台状态及所选账号尚未逐项记录，不能扩大为所有环境保证。
- 本轮未更新 IPA、测试页或主入口。下一次实现应采用真实 HTTPS 路径、移除失败猜测，并保留长按及常规路径作为备用，不自动执行删除。

## 执行限制

自动审批审核拒绝了 `adb shell am start` 打开链接的动作，返回 `blocked by policy`。未执行安卓页面跳转，也未改用其他工具绕过该限制。安卓证据属于静态声明与程序结构；iOS 运行结果由用户自行操作验证。

不采集相册内容、凭据、照片文件名或签名地址；本机证据摘要不含设备序列号和账号值。
