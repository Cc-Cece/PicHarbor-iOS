# 原生开发版交付与验收

日期：2026-10-19。此版本供阶段验收，**不是完整计划已完成的声明**。

## 0.2.7 任务详情、双维筛选与清理检查

- 生产提交 `ea51a41`，版本 0.2.7，构建号 9。任务详情以照片、流程、当前状态及操作为主，技术资源、查询与错误记录移入高级信息弹窗。活动按来源/状态筛选，多项批次卡片进入批次列表，单项平铺；筛选不改变原批次结构。
- 默认标准检查：云端内容确认，原始 Live Photo 完整配对确认后完成；高级严格检查默认关闭，开启时保留蓝色到绿色的动态就绪核验。核验级别单独记录；设置不会改变内容去重键，可显式应用到待确认任务。
- 清理检查只锁定候选资产，无需全局暂停，支持停止、逐项重试及结果分类，默认不勾选。当前仍仅开放普通照片与视频，Live Photo 完整资源取回验证完成前保留原件。删除前检查证据、账号、策略及本地版本，系统授权保留。
- [最终设备构建与包检查](https://github.com/Cc-Cece/PicHarbor-iOS/actions/runs/39217154542)及本机复检通过；[最终回归](https://github.com/Cc-Cece/PicHarbor-iOS/actions/runs/39217160375)通过，共 101 项（52 Python、41 原生、8 界面），无失败。自动测试不替代真实账号、后台行为及系统删除的真机验收。
- 最终本机包 `dist/PicHarbor-0.2.7-task-ui-final.ipa`，12,372,138 字节，解压 42,567,392 字节。SHA-256：`f04026954bb98e9ddadd1b8b52d9cb389e56d76a37e2981e6fc26a3ebd61f4f1`。包标识 com.cccece.picharbor，iOS 17.0+。本机确认正式可执行文件不含 DEBUG 界面样本入口。中途生成的 task-ui-verified 包保留原文件，以 final 包交付。
- 首轮云端 Python 回归发现短启动时间下零快照时间戳误判，已修复并补测试；中途测试由最终版本取代，不计作最终通过。实现与真机清单见 [0.2.7 说明](TASK-UI-CLEANUP-027.md)。

## 0.2.6 配对蓝色状态与确认优化

- 生产代码 `84601fb`（核心 `c5a5375`），版本 0.2.6，构建号 8。原始照片与动态视频完整配对证据通过后显示蓝色对勾；最终核验通过才变绿。蓝色任务不计入已备份，不进入清理候选，Live Photo 清理仍关闭。
- 增量图库同步保留当前账号会话内的快照与令牌；分页使用输入同步上下文，失败不发布部分证据。确认缓存 15 秒，退避目标 5/10/20/30 秒；两个上传名额与一个最终确认名额分开。记录任务核验时间、次数与最近查询耗时，包含队列等待及网络响应。
- [最终设备构建及包检查](https://github.com/Cc-Cece/PicHarbor-iOS/actions/runs/39209281714)、本机再次包检查与[最终回归](https://github.com/Cc-Cece/PicHarbor-iOS/actions/runs/39209286283)通过：51 Python、34 原生、6 界面，共 91 项，零失败、零跳过。最终包与测试对应同一生产提交。
- 本机包 `dist/PicHarbor-0.2.6-confirmation-verified.ipa`，12,272,019 字节，解压 42,201,163 字节。SHA-256：`b0202b8625cdb584680930896b533de81381531f4e33072c2fb4a65583f90f98`。包标识保持 com.cccece.picharbor，最低 iOS 17.0，可按原方式覆盖升级。
- 自动测试证明状态与协议回归通过，不能代替真机确认耗时比较。初版 CI 在修正增量分页上下文后被最终版本取代；完整回归以以上最终记录为准。日志 `build/confirmation-026-tests.log`，结果与截图 `build/confirmation-026-tests/`。实现说明及复测步骤见 [确认优化](CONFIRMATION-OPTIMIZATION.md)。
- 原生 `blue-pair-status` 截图已复核，蓝色对勾与“即将完成 · 配对已确认”同时可见。

## 0.2.5 新拍照片与旧任务重试修复

- 生产代码 `9fd4f4d`（核心 `45e7aee`），版本 0.2.5，构建号 7。导出前重新获取稳定资产并安全更新无资源任务的版本，导出后再核对版本及资源清单；持续变化有界等待，不消耗网络重试预算。已导出或提交的任务版本不自动改写。
- [最终设备构建与包检查](https://github.com/Cc-Cece/PicHarbor-iOS/actions/runs/39203920952)通过，本机再次检查通过。包标识 com.cccece.picharbor，最低 iOS 17.0。
- 最终本机包：`dist/PicHarbor-0.2.5-fresh-photo-final.ipa`，12,254,136 字节，解压 42,130,068 字节。SHA-256：`e09180c1c362b44b4e56f422500659adba637e939b64237fc53ef098c655b51a`。
- [最终回归](https://github.com/Cc-Cece/PicHarbor-iOS/actions/runs/39203924480)通过：47 项 Python、30 项原生单元、6 项界面，共 83 项，零失败、零跳过。结果与最终包均对应 `9fd4f4d`。本机日志 `build/fresh-photo-final-tests.log`，测试产物 `build/fresh-photo-final-tests/`。首轮 29 项原生测试通过；该轮因追加网络重试预算修复主动取消，不作为完整回归通过记录。中途生成的 verified 包为首轮代码，以 final 包为交付。
- 用户已反馈原始联合提交最佳、旧照片两种原始方式通常一次完成；Motion Photo 双条目按特性接受。新拍照片与先照片后视频的静态显示仍需[专项复测](FRESH-PHOTO-FIXES.md)，未将两种原始方式完整样本、官方取回和配额验收标为完成。Live Photo 清理继续关闭。

## 0.2.4 原始 Live Photo 配对测试版

- 核心代码 `314b5eb`；最终包 `ba30ed4` 另补一行“云端已有完整配对无需再次提交”的显示说明。版本 0.2.4，构建号 6。新增联合提交和先原图后关联视频两种原始配对实验方式；Motion Photo 保持默认，Live 清理仍关闭。
- [最终设备构建与包检查](https://github.com/Cc-Cece/PicHarbor-iOS/actions/runs/39198495441)通过，本机再次包检查通过；[最终回归](https://github.com/Cc-Cece/PicHarbor-iOS/actions/runs/39199168885)通过：47 项 Python、24 项原生单元、6 项界面，零失败、零跳过。测试提交 df221ab 与最终包的生产代码相同，只额外调整了界面测试的系统授权弹窗定位。
- 初轮回归的两项图库界面检查失败，原因是系统弹窗在应用辅助功能树下，旧脚本只查 SpringBoard。修正脚本同时识别两种归属后，实际点击系统完整授权，并通过网格浏览与真实 PhotoKit 导出/哈希检查；没有 CLI 预授予、跳过或移除测试。新增两种配对选项的选择与重启持久化测试通过，相关截图已复核。
- 本机报告和截图：`build/live-pair-final-tests/simulator-test-results/`。自动测试不替代原始 Live Photo 真实云端关联、同机显示、取回及配额验收。
- 最终本机包 `dist/PicHarbor-0.2.4-live-pair-test-verified.ipa`，12,244,494 字节；解压 42,091,900 字节。SHA-256：`0a23a0714d22b3d717bfb1dfb6ee5c1721089ec1eee144be53d8f8728e27ae58`。包标识保持 com.cccece.picharbor，覆盖安装保留数据。中途构建的 live-pair-test.ipa 保留原文件，以最终 verified 文件为准。
- 原始组件使用后台 URLSession，原始响应字节进入联合提交或补视频关联。配对确认要求同一云端标识，结果不明则查询，明确拒绝或本地确定性响应错误才解除对应提交围栏。
- 自动发现按账号、资产及版本去重；切换方式/画质不自动重传历史图库。手动对比使用专用新样本或显式重新备份。
- [研究依据](LIVE-PHOTO-PROTOCOL-RESEARCH.md)与[具体测试步骤](LIVE-PAIR-TESTING.md)。已有旧 Motion 云端副本不会自动合并或删除。

## 0.2.3 网络策略、活动与动态确认修复版

- 生产代码 `392365f`；版本 0.2.3，构建号 5，最低 iOS 17.0。包含对旧 Live 任务已确认资源重新查询规范云端标识的升级处理。
- [设备编译与包检查](https://github.com/Cc-Cece/PicHarbor-iOS/actions/runs/39192754173)通过；本机再次包检查通过。包标识保持 `com.cccece.picharbor`。
- 最终本机包 `dist/PicHarbor-0.2.3-dev-verified.ipa`，12,200,594 字节；解压 41,930,811 字节。SHA-256：`fefe1f4684e5a259c12495b47486777c45c82b6daef44e2646f2da32558b8d73`。中途构建的 `dist/PicHarbor-0.2.3-dev.ipa` 保留原文件，以最终包为准。
- [修改说明及真机复测](TASK-FEEDBACK-FIXES.md)：网络偏好应用于已有未完成任务；活动分组与移除；动态确认缓存、规范资源标识、可选字段解析及明确原因。HEIC 往返已获用户反馈，最终确认修复效果仍待新包真机复测。
- [最终模拟器回归](https://github.com/Cc-Cece/PicHarbor-iOS/actions/runs/39192786447)通过：36 项 Python、21 项原生单元、5 项界面测试，零失败、零跳过，生产代码与最终 IPA 同为 `392365f`。覆盖网络策略切换时保留媒体/提交信息、旧记录解码、批次/来源/移除标记、活动分组菜单与真实 PhotoKit 导出。上一轮被替代的整轮报告不计作通过。
- 测试日志与截图存于本机 `build/task-feedback-final-tests/`；本轮不改变 Motion Photo 上传格式，用户反馈的 Google Photos 本机/云端双项显示、原件仍在时保存回 iPhone 新增一项仍待单独研究，不能视为已修复。
- 用相同 Sideloadly Apple 账号与应用标识覆盖安装，保留原任务。不要为本次 Live 确认复测重新上传，先在详情使用“立即重新确认云端”。

## 0.2.2 上传响应与重试修复版

- 生产代码：`56048cc`（上传修复核心为 `f0c3502`）；0.2.2，构建号 4。[设备编译与包检查](https://github.com/Cc-Cece/PicHarbor-iOS/actions/runs/39188507063)通过，本机再次包检查通过。
- 最终本机包：`dist/PicHarbor-0.2.2-dev-verified.ipa`，12,139,917 字节，解压 41,713,669 字节。
- SHA-256：`193c3f2c790b9f0d8df6f4981e1befd35cb9f4c015a0a6c5154828b2c3df519b`。
- 先前在测试进行期间提供的 `dist/PicHarbor-0.2.2-dev.ipa` 保留原文件，上传修复相同；不在用户可能使用文件时覆盖它。
- [修复、诊断证据与复测步骤](UPLOAD-RESPONSE-FIXES.md)。[最终回归](https://github.com/Cc-Cece/PicHarbor-iOS/actions/runs/39188501094)通过：33 项 Python、18 项原生单元、4 项界面测试，零失败、零跳过；测试与最终包均为 `56048cc`。
- 实际完成系统相册授权后，在应用进程调用生产 ResourceExporter，导出测试照片、保留版本去重后的资源，再次读取并比对哈希与大小。报告及截图保存在 GitHub 产物及本机 `build/upload-fix-final-tests/simulator-test-results/`。专项测试入口仅在 Debug 且显式测试启动参数启用，Release 返回原页面，不显示测试入口。
- 保持代理可访问 Google，按原 Sideloadly 配置覆盖安装。先保留暂停队列，仅选择一条旧 FILE_ACCESS 失败任务执行“重新准备此任务 → 重新读取原件并查重”，核对新任务和 Google Photos 后再继续其余任务。
- 用户已反馈普通照片、视频上传流程完成，官方 Google Photos 可见；一个 HEIC Live Photo 样本的云端动态及官方客户端下载回 iPhone 后动态播放通过。该 Live 逻辑任务仍卡在云端确认，列入 0.2.3 排查；不扩大为所有 Live 样本已验收。

## 0.2.1 账号入口修复版

- 生产代码提交：`22f5e48`；版本 0.2.1，构建号 3，最低 iOS 17.0。
- [设备编译与 IPA 包检查](https://github.com/Cc-Cece/PicHarbor-iOS/actions/runs/39178064264)：通过；下载后本机再次包检查通过。
- 本机：`dist/PicHarbor-0.2.1-dev.ipa`，12,115,404 字节；解压 41,654,376 字节。
- SHA-256：`73578bd66c3758a700b400b280dd5c017a37cdbb7141ee3c14959f775f76ef4e`。
- 修复说明见 `ACCOUNT-FLOW-FIXES.md`。[最终回归](https://github.com/Cc-Cece/PicHarbor-iOS/actions/runs/39178066588)通过：32 项 Python、16 项原生单元、3 项界面测试，均为零失败，与安装包使用同一生产代码提交。
- 界面实测连续两次打开账号入口和 Google 网页、取消返回、无效凭据留在当前页面且没有额外弹窗、无账号设置在终止重启后保存，以及既有 PhotoKit/详情/四入口/默认画质/深色/核验流程。已人工复核账号页面、错误页面及真实 Google 登录表单截图。
- 最终报告和截图：GitHub 测试产物及本机 `build/account-fix-final-tests/simulator-test-results/`。没有使用真实账号；能打开表单不代表完成真实 Google 认证。
- 真机复测顺序：覆盖升级 → 设置/账号/添加 Google 账号 → 打开 Google 页面 → 取消、重新打开 → 本机登录/凭据导入；确认失败留在页面并显示原因，再检查账号切换与原有备份。
- 不需要先卸载旧应用。继续用相同 Sideloadly Apple 账号与应用标识设置覆盖安装。

## 0.2.0 初始可安装产物（历史）

- 生产代码提交：`b1249e9`。
- [设备编译与 IPA 包检查](https://github.com/Cc-Cece/PicHarbor-iOS/actions/runs/39157338820)：通过。
- 本机：`dist/PicHarbor-0.2.0-dev.ipa`。
- 文件大小：12,093,277 字节；解压包总计 41,551,200 字节。
- SHA-256：`0fb68a58037028e7bd0afc83483ca160781c42b376538fc2b28dc45ffd3b6b7b`。
- 包检查包含 Python/TLS/SQLite 扩展、协议适配模块、供应商源码哈希、后台模式及 BGTaskScheduler 标识。

## 自动检查证据

- 32 项 Python 离线行为测试通过，包括三画质、原始 A/B 回归、准备/提交拆分、独立确认、账号隔离、状态快照、重定向白名单及 Range 原件探测。
- [原生单元与 PhotoKit 界面回归](https://github.com/Cc-Cece/PicHarbor-iOS/actions/runs/39156753206)：14 项原生单元测试、1 项界面测试通过。
- 真实 JPEG/HEIC 封装、QuickTime timed metadata 关键帧、万级资产索引数据库、晚到写入不能覆盖暂停状态、重启时账号任务归属均通过测试。
- 实际读取并哈希超过 4 GiB 的稀疏测试文件，检查长度与峰值内存增长上限通过。**这不是大视频真实云端上传验收。**
- 界面测试使用确定性合成 PNG，操作系统相册授权后验证图库网格、照片详情、四个主入口、默认画质、核验策略和深色外观；没有真实账号或私人照片。
- 最新生产代码 `b1249e9` 的[最终回归](https://github.com/Cc-Cece/PicHarbor-iOS/actions/runs/39157525235)全部通过：32 项 Python、14 项原生单元、1 项界面测试；包括追加的预览关闭取消及并发磁盘预算改动，测试报告与截图上传成功。

## 实施状态

| 模块 | 当前代码 | 尚需验收/完成 |
| --- | --- | --- |
| 图库与原生界面 | 已实现，授权/网格/详情模拟器回归通过 | 真机有限授权、iCloud、动态字体/VoiceOver 全流程、大图库滚动性能 |
| 持久化与任务 | 普通照片/视频真实上传已获用户反馈；账号设置、资源版本、暂停重试、后台传输协调已实现 | 旧 A/B 升级、账号切换及网络策略切换 |
| 自动备份 | 已实现范围确认、增量核对与系统尽力调度 | 锁屏、系统终止、重启和后台时限真机测试 |
| Motion Photo | HEIC 样本云端动态及官方客户端往返已反馈通过 | 任务最终确认复测；声音/HDR/编辑等完整矩阵 |
| 苹果原始资源配对 | 0.2.4 联合提交及先原图后关联视频实验实现，同一云端 ID 核验 | 本应用同机识别、动态播放、官方取回、配额及完整样本矩阵仍待真机验收 |
| 相簿同步 | 已实现单向映射和独立重试 | 真实云端相册创建、复用及失败恢复 |
| 核验与本地清理 | 已实现证据失效、删除前重读、可选策略、选择及双重确认 | 专用普通测试照片的真机删除/取消/部分结果；Live Photo 清理仍禁止 |

## Windows 安装与首轮验收

1. 用 Sideloadly 安装本机 IPA，保持原来的 Apple 账号和应用标识设置，以保留升级数据。无需先删除旧应用。
2. 检查旧凭据及历史记录；若没有可用凭据，从设置连接账号。只在本机输入凭据，不发送到聊天或提交仓库。
3. 授权照片，先选择专用测试相簿。确认 original、Motion Photo、原始与编辑后均保留、仅 Wi-Fi 后，再决定是否开启自动备份。
4. 测试普通照片、视频、重复内容、编辑后的新版本、暂停/继续与重新打开应用。相簿同步单独开启测试，失败只重试相簿步骤。
5. 按 `LIVE-PHOTO-VALIDATION.md` 验证 Motion Photo。苹果原始配对目前会报需处理，不能把该错误当成成功验收。
6. 清理只用可删除的普通测试照片，检查取消与系统确认。Live Photo 在完整取回证据建立前不会参与删除。
7. 记录 iPhone/iOS、Google Photos 版本、动作与结果；需要诊断时使用应用内脱敏导出。网页原型不部署或同步。

只有两种 Live Photo 均通过约定的云端关联和官方客户端取回测试，且后台、升级与清理等剩余验收完成后，才能宣布完整应用交付。
