# iOS 功能清单（移动统一重构 · 2026-11-13 夜间）

- 仓库：PicHarbor-iOS，分支 `unification/overnight-20261113`（自 `baseline/mobile-unification-20261112`，HEAD `90ac7e1`）。
- 基线版本：0.2.30 / build 34（`project.yml`）；行为蓝本为 `docs/BACKUP-PIPELINE.md` 0.2.26 分阶段并发备份。
- 本清单只记录现状与归属，不宣称真机验收通过。真机验收状态见 `docs/DEVELOPMENT-ACCEPTANCE.md`、`docs/VALIDATION.md`。
- 语言：简体中文、English、粵語（香港）；默认跟随系统（2026-10-19 已确认）。
- 默认值（2026-10-19 已确认）：上传画质 `original`（不计配额原画质）；Live Photo 原始照片配对（联合提交）；原始与编辑后均保留；仅 Wi-Fi；自动备份初始关闭；相簿同步关闭；严格动态检查默认关闭。已有设置不被升级覆盖。

## 已确认决定（重构不得倒退）

- **本机清理已取消（2026-10-19，`docs/REQUIREMENTS.md` 顶部修订为准）。** 自建本机清理（扫描核验、风险许可、选择列表、删除执行、5 分钟清理证据）不再是交付必需项；PicHarbor 只做备份确认 + 官方清理指引/跳转。`CleanupView` 是纯官方指引页，全仓无 `performChanges` / `deleteAssets` / `PHAssetChangeRequest` 删除调用；官方跳转为已验证 Universal Link `https://photos.google.com/link/freeupspace`（0.2.12，AASA 有据 + 用户 iPhone 实测直达），不得另造深链。遗留清理字段只作兼容读取（见“已取消”一节），不得恢复功能；删除时机由 Yuto 定。
- **清理放行语义（统一核心 `decide_cleanup`）：** 仅判定云端确认证据是否足以指引官方清理；只有云端证据新鲜（3600 秒内）且 `cloud_state=="confirmed_original"` 才 eligible，否则保留原件。确认 ≠ 清理资格；任何“已备份/已确认”状态都不得自动转化为可删除。
- **备份完成铁律：** 完成必须包含所需云端确认；无法确认时保留原件并展示明确状态；不得仅凭 HTTP 成功或字节传完判定成功；重复回调/断网/暂停/重启恢复须幂等，不得重复提交、丢失任务或虚假成功；提交不明先查远端，不清除提交屏障、不自动重传。
- **脱敏口径（取交集从严）：** 诊断默认不含完整文件名与内容哈希/云端标识/账号标识/凭据；文件名如需记录只允许 basename（限长、屏蔽邮箱与秘密），禁止完整路径冒充。适配器与日志不得记录内容哈希、完整路径、账号标识。
- **文档内部残留冲突（已被顶部 2026-10-19 修订取代，不要按旧口径实现）：** `REQUIREMENTS.md` §7 与“最新交互与清理策略补充”中的清理检查/风险许可段落；`IMPLEMENTATION.md`“已确认规则”中的完整清理标准、5 分钟证据、删除前重读，及实施阶段 5“严格核验、可配置策略及本地清理”；`DEVELOPMENT-ACCEPTANCE.md` 实施状态表“核验与本地清理”行及验收步骤 6；`CLEANUP-REVIEW-0210.md`、`PHOTO-EXPERIENCE-028.md`、`TASK-UI-CLEANUP-027.md` 为 0.2.7–0.2.10 历史版本记录。另：`UI-REVIEW.md` / `LIVE-PAIR-TESTING.md` 称 Motion Photo 为默认是旧口径（现默认原始照片配对）；“默认开发语言 zh-Hans”是打包 fallback，不是用户默认语言（用户默认跟随系统）。
- **桌面端排除在移动统一范围外**，仅作协议参考（scope2/catalog2、Live Photo 按一个项目确认、双向确认）。

## 图例

- 稳定：已实现且有回归覆盖（仍需真机验收，不等于已验收）。
- 实验：已实现但明确未完成完整验收，必须单独标注，不得继承“已支持”结论。
- 已取消：代码/文档残留，功能已取消，只作兼容读取或指引。

## 1. 备份主流程（稳定；行为蓝本 BACKUP-PIPELINE 0.2.26）

| 功能 | 实现位置 | 状态 | 平台依赖 |
|---|---|---|---|
| 任务编排与泵（pipeline 阶段选择、名额、缓存背压） | `Sources/Core/HarborModel.swift`（`pump()`、`process()`、`processRouted()`）、`Sources/Core/BackupPipeline.swift`（`PipelineScheduler`、`PipelineProfiles`、`PipelineBufferBudget`） | 稳定 | —（纯 Swift；设备档位读取见下） |
| 分阶段并发：准备 1–3、上传检查 1–4、文件上传 1–12、保存与配对 1–4、云端确认 1–4、缓存 128–8192 MB；自动档按机型/内存/温度/电量调节（高档 2/3/6/2/2、768 MB） | `Sources/Core/BackupPipeline.swift`、`Sources/Core/PipelineDeviceMonitor.swift`、`Sources/Features/PipelineAdvancedView.swift`（高级配置 UI） | 稳定 | 设备型号/内存/温度/电源（`PipelineDeviceMonitor`） |
| 任务持久化与恢复（SQLite 唯一写入者；重启从耐久检查点推导阶段；暂停/取消意图不被覆盖） | `Sources/Core/BackupStore.swift`（actor，`backup-v2.sqlite`）、`HarborModel.boot()` 恢复循环、`Sources/Core/QueueScaling.swift`（`QueueRecovery`） | 稳定 | SQLite（系统） |
| 任务模型与状态（queued/preparing/transferring/committing/confirming/paired/completed/paused/waiting/failed/attention/cancelled） | `Sources/Core/BackupModels.swift`（`BackupJob`、`JobState`、`MediaResource`、`LivePairRecord`） | 稳定 | — |
| 普通照片/视频上传：PhotoKit 导出 → 哈希 → 查重 → 后台传输 → 提交 → 云端确认 | `HarborModel.processRouted()` 普通分支；`Sources/Core/PhotoLibrary.swift`（`ResourceExporter`）、`Sources/Core/BackgroundTransfer.swift` | 稳定 | PhotoKit（导出/版本）、后台 URLSession（文件传输）、钥匙串（凭据） |
| 查重与去重（内容哈希+大小，不比文件名；历史已确认记录保护重复备份；强制上传标记不再绕过查重） | `HarborModel`（`prepare_upload` / `confirm_resource` 调用）、`Sources/Core/ResourceReuse.swift` | 稳定 | — |
| 任务保护与恢复（重试 3 次；查询 60 秒/提交 90 秒；无进展 120 秒；文件处理 120 分钟；云端等待累计 60 分钟；暂存缺失按 SHA 复用或重导出） | `Sources/Core/BackupResilience.swift`（`BackupExecutionPolicy`、`BackupRecoveryBudget`、`BackupExecutionLease`、`StagingRecovery`） | 稳定 | — |
| 大队列（≥500 项先暂停自动发现；分批加入；一次遍历调度；活动页每次显示 100 项） | `Sources/Core/QueueScaling.swift`、`HarborModel.enqueue()` / `continueQueueRecovery()` | 稳定 | — |
| 网络偏好（仅 Wi-Fi 开关应用于当前账号未完成任务；手动暂停保持暂停；传输按需重建） | `HarborModel.applyNetworkSettings()`、`Sources/Core/BackgroundTransfer.swift`（`NetworkStatus`） | 稳定 | 系统网络状态 |
| 相簿单向同步（默认关闭；只创建/复用映射相册并添加成员；媒体与相簿步骤分别持久化） | `HarborModel.synchronizeAlbums()`、`Sources/Core/BackupModels.swift`（`AlbumMapping`） | 稳定 | PhotoKit 相簿 |
| 上传模式三档（`original` / `quota` / `saver`），默认 `original` | `Sources/Core/BackupModels.swift`（`UploadQuality`）、`Sources/Core/Engine.swift` | 稳定 | — |
| 统一核心适配（夜间重构新增；普通照片走共享状态机，旧路径为 fallback） | `Sources/Core/HarborCoreAdapter.swift`（新增）、`Python/harbor_ios.py`（`core_*` 透传分支）、`HarborModel` 接入点（见文件内注释 `deprecated-by-unification`） | 实验（`harbor_core.py` 已同步至 `Vendor/gpmc`，22 个锁定文件离线校验通过；Swift 本机无 Xcode 未编译验证，须 CI 构建验证） | 嵌入式 Python（PythonBridge） |

## 2. PhotoKit 图库与增量（稳定）

| 功能 | 实现位置 | 状态 | 平台依赖 |
|---|---|---|---|
| 应用内图库浏览（完整/有限授权分别表达；相簿；缩略图缓存；备份读原件） | `Sources/Features/LibraryView.swift`、`Sources/Core/PhotoLibrary.swift`（`PhotoLibrary`，`PHPhotoLibraryChangeObserver`） | 稳定 | PhotoKit |
| 增量发现（运行期观察变更；重开补齐；变更历史失效时重核对；元数据变化只产生待检查候选） | `PhotoLibrary`、`HarborModel.automaticScan()` / `indexLibrary()` | 稳定 | PhotoKit 变更历史 |
| 资源版本与稳定性（导出前三观一致才放行；版本快照锁定；持续变化有界等待，不耗网络重试预算） | `Sources/Core/BackupModels.swift`（`SourceStabilityProbe`）、`HarborModel.stableSource()` | 稳定 | PhotoKit |
| 备份范围确认与自动备份（首次确认范围后开启；默认仅 Wi-Fi；全部内容或选定相簿） | `HarborModel.enqueue()`、`Sources/Features/HarborRootView.swift`（`BackupDashboard`） | 稳定 | PhotoKit |
| 相片备份状态筛选（全部/已备份/未备份；已备份=当前账号同一资产当前版本有已完成记录） | `Sources/Core/BackupModels.swift`（`LibraryBackupFilter`、`CompletedAssetIndex`）、`LibraryView` | 稳定 | PhotoKit |
| 照片详情/信息/分享（缩略图可点进详情；文件名两行中间截断可展开复制；分享为照片+配对视频两个文件） | `Sources/Features/AssetInformationView.swift`、`JobDetailView.swift`、`AssetThumbnail.swift` | 稳定 | PhotoKit、系统分享 |

## 3. Live Photo（实验——两种方式均为交付目标，均未完成完整验收）

| 功能 | 实现位置 | 状态 | 平台依赖 |
|---|---|---|---|
| 动态照片封装 Motion Photo（照片+视频封装一个文件；XMP/`mpvd` box/QuickTime 关键帧；1 MiB 块读写） | `Sources/Core/MotionPhoto.swift`（`MotionPhoto.package`） | 实验：仅一个 HEIC 样本获用户反馈云端动态及官方客户端往返通过；声音/关键帧/HDR/编辑版本未逐项验收 | PhotoKit（配对资源） |
| 原始照片配对·联合提交（照片与视频分别上传后一次关联提交；双哈希须指向同一云端项目） | `HarborModel.processApplePairs()`（route `joint`）、`Python/harbor_ios.py` → gpmc `pair_apple` / `confirm_pair` | 实验：`apple_pair=true` + `apple_pair_experimental=true` 表示可执行实验路径，不表示官方往返验收通过 | PhotoKit 配对视频资源、嵌入式 Python/gpmc |
| 原始照片配对·分步上传（先原图后关联视频） | `HarborModel.processApplePairs()`（route `reconcile`）、`commit_pair_photo` / `prepare_pair_component` | 实验：同上 | 同上 |
| Live Photo 逻辑资产管理（一个逻辑资产管资源/进度/结果；不混用版本；失败保留原件，不静默降级为静态照片） | `Sources/Core/BackupModels.swift`（`LivePairRecord`、`hasConfirmedPairs`）、`HarborModel` | 稳定（规则）/实验（云端关联本身） | PhotoKit |
| 确认语义：配对确认→蓝色 `paired`“即将完成 · 配对已确认”（不计入已备份）；最终动态标记/回收站状态/可选相簿同步通过→绿色 `completed`；确认缓存 15 秒；退避 5/10/20/30 秒封顶 30 秒；严格动态检查默认关闭 | `HarborModel`（`beginConfirmation` / `waitForConfirmation`）、`Sources/Core/BackupModels.swift`、`Sources/Core/BackupResilience.swift` | 稳定（语义已确认） | — |
| Live Photo 清理资格 | 已取消（见“已取消”一节）。默认保留未完成完整验证的 Live Photo；无完整配对/取回证据前一律保留原件 | 已取消 | — |

## 4. 账号与认证（稳定）

| 功能 | 实现位置 | 状态 | 平台依赖 |
|---|---|---|---|
| Google 账号连接（应用内网页登录；已有 gpmc 凭据导入；凭据只存钥匙串，不入数据库/诊断） | `Sources/Core/Engine.swift`（`connect` / `login` / `logout`）、`Sources/Features/GoogleLoginView.swift`、`Sources/Features/HarborSettingsView.swift`（`ConnectionView`） | 稳定 | 钥匙串、WebKit（Google 登录页） |
| 多账号切换与隔离（任务/设置按账号；切换时暂停在途协议请求；失败切换不沿用旧账号） | `HarborModel.switchAccount()` / `connect()`、`Sources/Core/KeychainStore.swift` | 稳定 | 钥匙串 |
| 账号恢复默认设置（需确认；重置业务偏好、关闭自动备份、范围重确认；保留语言/外观/账号/任务/历史/照片） | `HarborModel.restorePreferenceDefaults()` | 稳定 | — |

## 5. 活动、任务详情与归档（稳定）

| 功能 | 实现位置 | 状态 | 平台依赖 |
|---|---|---|---|
| 活动页（来源×状态两维筛选；批次卡片/单项平铺；分组菜单：暂停/继续/重试/归档/移除未完成） | `Sources/Features/ActivityView.swift`、`Sources/Core/TaskPresentation.swift`（`ActivityBatch`、`ActivityTaskOrder`） | 稳定 | — |
| 任务详情（照片、流程、当前状态与操作；技术资源/错误记录在高级信息） | `Sources/Features/JobDetailView.swift` | 稳定 | — |
| 活动归档（自动归档天数 1–90，默认 14 天；归档记录页；取消归档） | `Sources/Features/HarborSettingsView.swift`（`ActivityArchiveSettingsView`）、`Sources/Core/ActivityArchivePreferences.swift`、`HarborModel.archive()` / `autoArchive()` | 稳定 | — |
| 任务移除（单项/批量停止并移除未完成；保留内部取消标记防复活与自动扫描重加；不删本机/云端照片） | `HarborModel.removeUnfinished()` | 稳定 | — |
| 旧版记录（A/B 兼容历史观察记录，只读展示） | `Sources/Core/Engine.swift`（`records`）、`ActivityView.LegacyBackupRecordsView` | 稳定 | Python observations.sqlite（兼容历史） |

## 6. 应用内代理（实验——验证阶段）

| 功能 | 实现位置 | 状态 | 平台依赖 |
|---|---|---|---|
| 应用内代理开关（默认关闭；只作用于 PicHarbor 连接；无系统 VPN；监听 `127.0.0.1:24500–24563`） | `Sources/Core/ProxyRouting.swift`（`ProxyManager`）、`Sources/Features/ProxyPreferencesView.swift` | 实验 | 嵌入式 Clash（`Runtime/Clash.xcframework`，ProjectClash Apple SDK） |
| Clash 配置导入（最多 20 份配置，每份最多 64 节点；订阅 HTTPS 下载；订阅/节点/凭据存钥匙串，不入诊断） | `Sources/Core/ProxyProfiles.swift`、`Sources/Features/ProxyProfilesView.swift` | 实验 | 钥匙串 |
| 订阅二维码扫描（相机扫码或相册选图；只接受 HTTP/HTTPS 订阅链接；单节点链接拒绝并提示） | `Sources/Features/SubscriptionScannerView.swift`、`Sources/Core/SubscriptionQRCode.swift` | 实验 | 相机、Vision（二维码识别）、PhotoKit（相册选图） |
| 节点选择与故障切换（手动/自动；最多 8 个备用节点；全部失败默认暂停等待；直连须明确允许） | `Sources/Core/ProxySelection.swift`、`Sources/Core/ProxyRouting.swift` | 实验 | — |
| 代理隔离（每次 Python 调用显式本机代理；关闭环境变量代理继承；继续验证 Google HTTPS 证书） | `Sources/Core/Engine.swift`（`invoke` 注入 `proxy_url`）、`Python/harbor_ios.py` | 实验 | 嵌入式 Python |

## 7. 传到这台电脑 / 电脑直连（实验——未执行真机配对验收）

| 功能 | 实现位置 | 状态 | 平台依赖 |
|---|---|---|---|
| 局域网直连传输（扫码/手动配对；TLS + 证书固定 + Bearer；接收方确认；手机主动发送须电脑 UI 确认） | `Sources/Core/LiveLinkClient.swift`、`LiveLinkProtocol.swift`、`LiveLinkSend.swift`、`LiveLinkIdentityFile.swift`、`Sources/Features/LiveLinkView.swift` | 实验 | 局域网、钥匙串（身份/证书）、后台传输不可校验自签名证书（锁屏后停止，见 `LiveLinkSend` 注释） |
| 配对范围 scope2 / catalog2（默认/全量/日期/高级范围按设备身份保存；Live Photo 按一个媒体项目确认，任一组成文件不可读则不单独发送另一部分） | `Sources/Core/LiveLinkScope.swift`、`LiveLinkScopeRules.swift` | 实验 | — |
| 已配对电脑管理（离线配对保留；刷新保持原配对身份；忘记电脑） | `LiveLinkClient`（`SavedComputer`）、`LiveLinkView` | 实验 | 钥匙串 |

## 8. 备份确认与官方清理指引（稳定；清理本身已取消）

| 功能 | 实现位置 | 状态 | 平台依赖 |
|---|---|---|---|
| 云端确认（提交后独立哈希查询确认；提交不明只查询不重传；确认失败保留原件并展示明确状态） | `HarborModel.processRouted()`（`confirm_resource`）、`Python/harbor_ios.py` → gpmc 协议 | 稳定 | 嵌入式 Python/gpmc |
| 释放空间指引（只提示已完成备份的任务前往 Google 相册；直达 Universal Link，失败时给备用打开方式与 App Store 入口；不改变任务状态） | `Sources/Features/CleanupView.swift`、`Sources/Core/GooglePhotosLinks.swift`（`GooglePhotosLauncher`）、`Sources/Features/JobDetailView.swift`（仅 `completed` 任务显示入口） | 稳定 | Universal Link（`https://photos.google.com/link/freeupspace`，`.universalLinksOnly`） |
| 诊断（脱敏：不含凭据、签名地址、内容哈希、云端标识、完整文件名；`local_cleanup=false`、`cleanup_provider=google_photos`） | `HarborModel.diagnostics`、`Engine.diagnostics` | 稳定 | — |

## 9. Python 桥与 gpmc（稳定边界；快照锁定）

| 功能 | 实现位置 | 状态 | 平台依赖 |
|---|---|---|---|
| 嵌入式 CPython 3.13 启动与调用（主线程初始化；GIL；请求预算与取消；进度事件节流） | `Sources/Bridge/PythonBridge.h/.m`、`Sources/Bridge/BridgingHeader.h`、`Sources/Core/Engine.swift`（`invoke`） | 稳定 | CPython（`Runtime/Python.xcframework`）、TLS/SQLite 扩展 |
| gpmc 固定快照（中央库唯一维护；`gpmc.lock.json` 内容锁定；构建离线校验；不得直接改各端副本） | `Vendor/gpmc/`、`gpmc.lock.json`、`Vendor/source-manifest.json`、`tools/sync_gpmc.py` | 稳定 | — |
| 协议适配（分阶段协议：`prepare_upload` / `commit_resource` / `confirm_resource` / `pair_apple` / `confirm_pair` / `motion_status` / 相簿；请求预算；账号/代理隔离；最多 8 个空闲上下文） | `Python/harbor_ios.py`（`Service`、`IOSApi`）、`Python/harbor_protocol.py`（兼容导入 → `gpmc.protocol`）、`Python/harbor_deadline.py` | 稳定 | 嵌入式 Python |
| 统一核心透传（`core_*` → `harbor_core.dispatch_json`；`harbor_core` 缺失时返回 `RUNTIME_UNAVAILABLE`，不伪造成功） | `Python/harbor_ios.py`（`dispatch` 内 `core_*` 分支）、`Sources/Core/HarborCoreAdapter.swift` | 稳定（`harbor_core.py` 已同步；9 项 `tests_python/test_core_adapter.py` 本地通过） | 嵌入式 Python |

## 10. 设置、界面与本地化（稳定）

| 功能 | 实现位置 | 状态 | 平台依赖 |
|---|---|---|---|
| 设置页（备份偏好、网络、活动记录、界面语言/外观、账号、诊断、关于） | `Sources/Features/HarborSettingsView.swift`、`Sources/Features/PipelineAdvancedView.swift` | 稳定 | — |
| 四标签导航（照片/备份/活动/设置）与队列提示（加入队列提示 10 秒后隐藏） | `Sources/Features/HarborRootView.swift` | 稳定 | — |
| 本地化（zh-Hans / en / zh-Hant-HK / yue-Hant-HK；480+ 条；香港用词与粤语提示为 overrides，非仅简繁转换；错误码与协议标识不翻译） | `Resources/*.lproj/Localizable.strings`、`Resources/MessageKeys.json`、`Localization/english.tsv`、`Localization/hong-kong-overrides.tsv`、`tools/build_localizations.py`、`Sources/Core/Localization.swift` | 稳定 | — |
| 自我更新包（SelfRefreshKit，独立 Swift 包） | `Packages/SelfRefreshKit/` | 稳定（独立组件；不在本次重构范围） | 钥匙串 |
| 后台调度（系统尽力调度；前台可靠推进；不承诺即时唤醒） | `Sources/Core/BackgroundTransfer.swift`（`HarborAppDelegate`）、`Resources/Background.plist` | 稳定 | 后台 URLSession、BGTaskScheduler |

## 11. 已取消（只作兼容读取或指引，不得恢复功能；删除时机由 Yuto 定）

| 残留 | 位置 | 处理 |
|---|---|---|
| 自建本机清理 UI（清理核验页、扫描、选择列表、删除执行、风险对话框） | 已移除。现 `Sources/Features/CleanupView.swift` 为纯官方指引页 | 保留指引页；不重建清理 UI |
| 清理证据模型（账号/版本/策略绑定、5 分钟有效期规则） | `Sources/Core/BackupModels.swift`（`CleanupEvidence`、`cleanupPolicy`）、`Sources/Core/TaskPresentation.swift`（`LiveCleanupPolicy`、`CleanupCandidates`、`CleanupSelection`、`CleanupOutcome`）、`Sources/Core/Engine.swift`（`LIVE_CLEANUP_UNVERIFIED` / `LIVE_COMPONENT_UNVERIFIED` 文案） | 只作旧任务/旧设置兼容读取与单元测试对象；无任何调用链能走到删除（全仓无删除调用）。`LIVE_COMPONENT_UNVERIFIED` 文案已于本次重构改为指向官方释放空间（原“空间清理核验”入口已不存在）。`BackupSettings` 的 `allowUnverifiedLiveCleanup` / `cloudState` / `originalAccess` 字段保留解码，不再生效 |
| gpmc `check_cleanup` 协议操作（按哈希查云端 key、校验快照新鲜度与云端状态，返回 eligible/reason） | `Vendor/gpmc/protocol.py`（`Protocol.actions` 含 `check_cleanup`） | 本身不删除任何东西，只是证据查询；新版不得用它授权/触发删除，不接入清理决策 |
| 清理类诊断事件与旧文档口径 | `HarborModel.diagnostics` 已明确 `local_cleanup=false`；旧文档见“文档内部残留冲突” | 诊断沿用此口径；旧文档口径不实现 |

## 12. 已知未完成（不标为完成）

- 3 项测试失败待 CI 验证（2026-11-12 记录；见夜间汇报）：`SubscriptionQRCodeTests.testPhotoQRCodeIsRecognizedLocally`、`HarborFlowTests.testActivityGroupingOptions`、`HarborFlowTests.testArchiveSettingsValidateInputAndArchiveEntryOpens`。
- Live Photo 两种方式的完整验收（云端正确关联、同机显示、官方客户端取回、配额、完整样本矩阵）均待真机验收；Motion Photo 声音/关键帧/HDR/编辑版本未逐项验收。
- 真机后台、权限变化、iCloud 原件、安装升级、大图库（万级）与超 4 GiB 视频、锁屏/系统终止/重启恢复待逐项记录。
- 电脑直连未执行真机配对验收（真实局域网扫码、双向确认、部分照片授权、iCloud 原件、锁屏/断网、实况回放）。
- 统一核心接入已同步（`Vendor/gpmc/harbor_core.py`，`gpmc.lock.json` 更新，离线校验通过）；Swift 侧本机无 Xcode，未编译验证，须 CI 构建验证。视频 / Live Photo 仍走旧路径，未接入核心。
