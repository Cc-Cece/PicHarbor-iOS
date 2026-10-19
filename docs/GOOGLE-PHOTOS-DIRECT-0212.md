# 0.2.12 · 直达 Google 相册释放空间

版本 0.2.12 / 构建 14。主按钮使用 `https://photos.google.com/link/freeupspace`，该路径已在 Google 的生产 iOS 应用关联配置中找到，并由用户在 iPhone 实测直达目标页。证据见 [链接研究](ANDROID-FREEUPSPACE-LINK-RESEARCH.md)。

- 使用系统 Universal Link，仅请求应用打开，不退回网页。系统无法打开时提示，并展开备用说明；打开回调不代表已完成清理。
- “其他打开方式”默认折叠：优先介绍主屏幕或 App 资源库长按 Google 相册图标 → 释放空间，其次介绍头像 → Google 相册设定 → 应用程序与装置 → 释放空间。
- 移除设置及指引中的临时链接测试页、六个失败路径、记录及分享代码。历史测试数据不再读取。
- Google 相册决定清理范围并执行删除，可能包含其他已备份项目。PicHarbor 不执行 PhotoKit 删除，也不因打开链接改变任务状态。
- 保留账号、历史记录、备份设置及上传确认行为，使用原 Sideloadly 配置覆盖安装。

验证：本地 58 项 Python 检查及多语言覆盖检查通过。原生测试改为校验真实链接；界面回归覆盖默认折叠、展开/收起、未安装时备用说明，以及无旧清理/测试入口。上一版仍访问旧清理设置的过期界面测试已更新。云端构建与完整回归结果待补充。

真机验收：从 PicHarbor 点击主按钮，应直接到 Google 相册释放空间页；分别测试 Google 相册冷启动及已在后台状态，并确认默认折叠和手动展开。模拟器不替代真实跨应用跳转验证。

## 构建记录

- 源码：`bfb4412`；[设备构建](https://github.com/Cc-Cece/PicHarbor-iOS/actions/runs/39243423443)通过；[完整模拟器回归](https://github.com/Cc-Cece/PicHarbor-iOS/actions/runs/39243380304)正在执行。
- 本机 IPA：`dist/PicHarbor-0.2.12-google-photos-direct.ipa`，下载大小 12,436,967 字节，解压大小 42,739,085 字节。
- SHA-256：`b1d8db612a6e51997df9f15dfff85e7088e443e9c9c43acd7f9e602703383bd0`。
- 包检查通过：0.2.12 / 14、iOS 17+、`com.cccece.picharbor`，嵌入运行环境及上游快照完整；主程序含真实链接、不含临时测试页类型或资产删除 selector。
