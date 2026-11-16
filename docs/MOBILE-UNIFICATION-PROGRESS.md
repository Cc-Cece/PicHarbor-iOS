# 移动端统一任务记录（iOS）

总体方向见 [任务书](../PicHarbor-Android/docs/MOBILE-UNIFICATION-CHARTER.md)（Android 仓库同名文件）。
完整交接见本地 `~/workspace/picharbor/HANDOVER-2026-11-13.md`。

## UNIFICATION-OVERNIGHT-2026-11-13：夜间重构（2026-11-13 凌晨）

日期：2026-11-13。分支 `unification/overnight-20261113`（本地 `0f2c656`，远程 `fbd7592`，内容一致）。

- 功能清单：新建 `docs/MOBILE-UNIFICATION-INVENTORY.md`（功能 × 实现位置 × 稳定/实验/已取消 × 平台依赖）。
- 共享核心：新建 `Sources/Core/HarborCoreAdapter.swift`（薄适配器，经 `PythonBridge.call("core_<action>",…)`），`Python/harbor_ios.py` 增加 `core_*` 透传；普通单资源照片走核心（create_task → decide_prepare → uploading → submitting → confirming → done，仅云端确认后才 done）；旧路径保留，标 `deprecated-by-unification`；视频 / Live Photo / 多资源任务未接入核心。
- 3 个失败测试：二维码识别改 Revision1（中等置信）、活动菜单加无障碍标签（低置信、根因未证实）、归档设置整行聚焦（较高置信）。均未改测试语义，全部需 CI 验证。
- 清理：iOS 只做备份确认 + 官方清理指引/跳转（已验证 Universal Link `https://photos.google.com/link/freeupspace`），不自建删除；改 2 处过期文案（已同步 4 种语言）。
- 同步：`tools/sync_gpmc.py --check` 通过，锁定 `1ac9c2efc7c1b967`，22 文件。
- 本地验证：`pytest tests_python/` 84 项通过（含新增 `test_core_adapter.py` 9 项）。Swift 未本地编译（本机无 Xcode），必须经 CI 验证。
- 未完成：CI 构建与全量模拟器测试；批量 pause/resume 未镜像到核心；遗留清理类型未删（等 Yuto 定）；视频 / Live Photo 未接入核心。

## UNIFICATION-STAGE2-2026-11-13：第二阶段（2026-11-13 凌晨，本地未推）

分支 `unification/overnight-20261113`（本地提交，见 `git log`）。只做代码，不跑测试、不编译、不跑 CI、不触发 GitHub、不申请权限。

- 视频：视频任务与普通照片同一流程走核心（`create_task → preparing → lookup → decide_prepare → uploading → submitting → confirming → done`），asset 带 `media_kind=video`、`duration_seconds`、`size`（`MediaResource.durationSeconds`，导出时取自 PHAsset）；原生传输与后台 URLSession 适配不变。
- Live Photo / 多资源：照片+视频配对与 Motion Photo 多版本按一个媒体项目走核心（`media_kind=live_photo`，一任务一 core task）；`asset.resources` 逐资源 `decide_prepare`；默认原始照片配对（联合提交），已有设置不被升级覆盖（未动设置默认值逻辑）；联合提交（`pair_apple`）与分步上传（`reconcile` 先原图后关联视频）两条路线都接核心状态机；未完成完整验证的 Live Photo 默认保留原件，不擅自清理。
- 批量任务：批量创建（`enqueue`，batch id 随 `create_task` 进核心）、批量暂停/恢复（`batch_pause` / `batch_resume`，入参 `{task_ids, tasks}`，返回 per-task 结果）、批量取消（`removeUnfinished` + `cancel` 镜像 `cancelled`）接核心；“下次进入时重同步”的缺口已删，暂停/恢复在操作当时镜像。
- 相册范围：备份范围走核心 `evaluate_scope`（入参 `{scope, asset}`，scope 含 mode/albums/dateEnabled/from/to/photos/videos/ignoreSmallImages/minImageKb/filterCache + version 2）；未知版本 scope 报错时排除该资产，不退回全量；无限制范围跳过逐项调用。LiveLink 范围走 `livelink_scope`。
- 资源复用：已上传资源复用/去重走核心 `decide_prepare`（`remote_key` 命中即 `content_exists` 跳过上传）；`ResourceReuse.evidence` 是唯一本地推导处，决策由核心过滤（`confirmedReuseKeys`），其余重复推导已删。
- 代理：代理配置/选择/路由走核心 `validate_proxy`（显式代理参数：enabled/primary/backups/fallback/selection/exhaustion，默认关）；凭据走 Keychain，不进核心、不进日志；TLS 校验保留在原生层。
- 电脑直连 LiveLink：配对、目录/预览、传输确认走核心状态机（`livelink_handshake` 校验 scope2/catalog2 能力，`livelink_scope` 范围校验，返回 `requires_confirmation:true` 时由 offer/accept 门强制接收方确认）；任何传输均需接收方确认；Live Photo 按一个媒体项目确认（一个 offer、照片+视频同传）。
- `decide_cleanup` 逐项证据：证据源改为 reconcile / 云端确认结果（每次 `confirm_resource` / `confirm_pair` 成功记录 `lastConfirmationAt`，`cleanupEvidenceItems` 取 `items=[{task_id, cloud_confirmed, confirmed_at}]` 调核心）；无证据时只做页级指引、不放行逐项；绝不伪造证据。清理入口继续只指向 Google 相册官方释放空间，不自建删除。
- 数据迁移代码：旧数据、设置、凭据、未完成任务的兼容/迁移代码写完（`LegacyMigration.preview`，调核心 `migrate_legacy`，本地映射作回退），只读预览，不执行任何不可逆转换、不删旧数据，迁移只在代码层面就绪、可回滚；`HarborModel.migrationPreview()` 未接入 `boot()`。
- 删旧业务核心路径：所有标 `deprecated-by-unification` 的旧路径已删（`HarborModel.processRouted` 统一上传路径，核心任务为强制项；核心不可用时任务以可重试的 `ENGINE_ERROR` 失败，不再静默走无核心决策）；`isPhotoCoreJob` / `finishPhotoJob` 已由通用版取代；旧测试同步删除/改写（`Tests/BackupCoreTests.swift`）。
- 交接 §8 待定项已决定并实施：iOS 遗留清理类型（`CleanupEvidence`、`allowUnverifiedLiveCleanup`、`cloudState`、`originalAccess`、`cleanupPolicy`、`LiveCleanupPolicy`、`CleanupCandidates`、`CleanupSelection`、`CleanupOutcome`）全部删除，只留兼容读取（旧记录仍可解码，JSONDecoder 忽略已删键）；包名/Bundle ID 共存按“不改 Bundle ID、不改签名”实现迁移路径（见 `LegacyMigration` 顶部设计注释），发布切换与旧版退出只写设计注释、不执行。
- 文档残留清理：`docs/REQUIREMENTS.md` §7 与 2026-10-19 补充、`docs/IMPLEMENTATION.md` 已确认规则/阶段 5/清理测试、`docs/DEVELOPMENT-ACCEPTANCE.md` 实施状态表/步骤 6/结尾及 0.2.7–0.2.10 历史行已批量改成与 2026-10-19 修订一致（只保留备份确认与官方清理指引，不自建扫描/删除）。
- gpmc 快照同步：已同步核心第二阶段扩展（`tools/sync_gpmc.py --check` 通过，新锁定 `913285b19d1b7859`，22 文件，`source_base_commit: a2a0086`，与 Android 锁定一致）；对照已落地核心契约修正 6 处调用不符（scope version 1→2、batch tasks 为 dict、validate_proxy 须带 host/port/scheme + verify_tls、livelink_scope 须传 asset、evaluate_scope 的 asset 须带 albums、Motion 包发 motion_photo）。
- 未验证：Swift 未本地编译（本机无 Xcode），Python 测试未本地执行（任务要求不跑测试），全部须 CI 验证。
