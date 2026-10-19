# 0.2.11 官方清理指引与临时链接测试

2026-10-19 用户已实测：iPhone 拍摄 Live Photo → PicHarbor 原始配对上传 → Google 相册官方“释放空间”准确移除该本机资产。用户据此授权将本机清理交由官方客户端，并增加临时直达链接测试页。该样本不扩展为所有资源类型均已验收。

## 产品调整

- “备份 → 释放 iPhone 空间”改为指引：头像 → Google 相册设定 → 应用程序与装置 → 释放空间。路径取自用户关闭官方备份时的实测，名称和位置可能随版本、语言变化。
- 主按钮只尝试 `googlephotos://` 打开应用；失败时提示手动打开或查看 App Store，不自动打开其他候选。
- 移除原生清理扫描、证据生成、PhotoKit 删除执行以及清理偏好页和风险对话框。原生源码不再包含资产删除调用。
- 备份双哈希同项目确认、可选严格动态处理检查、任务和账号隔离均保留。完成任务提供官方清理指引入口。
- 老账号设置中的清理字段、历史任务及证据类型保留兼容读取，不能恢复清理操作；不破坏原有记录、不重新上传。诊断明确 `local_cleanup=false`、`cleanup_provider=google_photos`。
- 权限说明同步删除本机清理描述。恢复设置名称改为“恢复备份默认设置”。

## 临时测试页

入口：**设置 → 链接测试（临时）**，也可从释放空间指引进入。该页会在方案确定后移除。

| ID | URL | 依据 |
| --- | --- | --- |
| launch | `googlephotos://` | 公开社区收录的启动 scheme，仍需本设备验证 |
| settings | `googlephotos://settings` | 路径猜测，未经验证 |
| devices | `googlephotos://settings/apps-and-devices` | 路径猜测，未经验证 |
| freeupspace | `googlephotos://freeupspace` | 路径猜测，未经验证 |
| free-up-space | `googlephotos://free-up-space` | 路径猜测，未经验证 |
| settings-freeupspace | `googlephotos://settings/freeupspace` | 路径猜测，未经验证 |
| settings-free-up-space | `googlephotos://settings/free-up-space` | 路径猜测，未经验证 |

没有找到 Google 公布的 iOS 本机释放空间直达协议。以上路径不来自 Google 官方文档、反编译或已成功运行的示例；不能声称任一候选有效。

应用声明 `LSApplicationQueriesSchemes=googlephotos`，只打开固定候选列表，不拼接账号、凭据或任意网页。`canOpenURL` 与系统打开回调只能证明系统是否接受请求，不能证明到达目标页；界面分别展示系统结果及人工页面结论。

### 真机测试步骤

1. 先选 Google 相册备份开关及测试前是否已退出后台；先试启动入口，再试其他候选。
2. 每次点击后观察实际页面；返回 PicHarbor，选择“到达释放空间页／只打开首页／打开其他页面／未能打开应用”。只打开首页应记录为首页，不能当作直达成功。
3. 分别验证不在后台、仍在后台，以及关闭官方备份时的行为；每个入口仅保存最近一次记录，重复测试后先复制结果再换条件。
4. 复制或分享汇总，并手动补充 Google 相册版本。记录含候选地址、PicHarbor 版本、iOS 版本、时间、测试条件和结果，不含账号、凭据、照片内容、文件名或签名地址，不自动发送。

测试不会自动点击 Google 相册按钮或执行删除。Google 相册的清理界面可能列出该账号识别出的其他已备份项目，范围和删除确认由官方客户端决定，不局限于 PicHarbor 当前批次。请使用释放**设备**空间入口，勿混用云端存储管理；iCloud 同步和苹果相册“最近删除”仍按系统规则工作。

## 来源与验收

- [社区 scheme 记录](https://github.com/ymargreth/ios-app-urls)：仅收录根 scheme。
- [Google 官方释放设备空间说明](https://support.google.com/photos/answer/6128843?co=GENIE.Platform%3DiOS&hl=zh-Hans)：手动流程，未提供外部直达协议。
- 本机 58 项离线检查通过；新增禁止原生资产删除、版本及 scheme 声明检查。原生测试覆盖候选唯一性、系统接受与人工结论分离、保存/清空及过期回调；界面测试覆盖指引、未安装提示和临时页导航，不将模拟器测试当作候选直达成功。
- 新版本为 0.2.11 / 构建 13；设备构建、完整回归与最终包信息见交付台账。
