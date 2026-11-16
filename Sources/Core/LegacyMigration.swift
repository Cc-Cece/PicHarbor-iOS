import Foundation

/// Pre-unification data migration: code-ready, never executed here.
///
/// Design (decided 2026-11-13, stage 2; publish switch and old-version
/// exit are design only — nothing below performs them):
/// - Bundle ID and signing do not change (`com.cccece.picharbor`, same
///   signing identity). There is no parallel bundle ID and no
///   co-existence install: the new version upgrades the old one in
///   place, so the app container — `backup-v2.sqlite`, the core task
///   store, the Keychain (`PicHarbor.proxy`, `PicHarbor.live-link`,
///   per-account credentials) — is preserved by the OS upgrade.
/// - The old version exits by App Store upgrade, not by a forced
///   removal or a parallel install. No migration step deletes the old
///   version's data.
/// - Rollback: `preview` writes nothing and deletes nothing. When a
///   real migration is enabled (by Yuto, after reviewing a preview),
///   it must write migrated copies under a new store kind and keep the
///   originals until the migrated copies are verified; only then, with
///   explicit approval, may the originals be removed. No irreversible
///   conversion runs unattended.
struct LegacyMigrationReport {
    var totalJobs: Int
    var migratedJobs: Int
    var unknownStates: [String]
    var accounts: [String]
    var settingsAccounts: [String]
    var summary: String {
        L10n.text("旧任务 {0} 项，可迁移 {1} 项", [String(describing: totalJobs), String(describing: migratedJobs)]) +
        (unknownStates.isEmpty ? "" : L10n.text("，未知状态 {0} 项将记为失败待人工处理", [String(describing: unknownStates.count)])) +
        L10n.text("；账号 {0} 个，设置 {1} 个。仅预览，未写入、未删除、未转换。", [String(describing: accounts.count), String(describing: settingsAccounts.count)])
    }
}

enum LegacyMigration {
    /// Read-only preview of the legacy migration. Reads current jobs
    /// (in-memory snapshot), stored per-account settings and Keychain
    /// accounts, maps the jobs through the shared core's
    /// `migrate_legacy` (local mirror while the dispatched action is
    /// unavailable), and reports the outcome. Writes nothing, deletes
    /// nothing, converts nothing.
    static func preview(store: BackupStore, jobs: [BackupJob],
                        adapter: HarborCoreAdapter) async -> LegacyMigrationReport {
        var settingsAccounts: [String] = []
        if let saved = try? await store.load(HarborModel.AccountSettings.self, kind: "settings") {
            settingsAccounts = saved.map(\.account)
        }
        let accounts = (try? KeychainStore.accounts()) ?? []
        let records = jobs.map { legacyRecord(for: $0) }
        let migrated = await adapter.migrateLegacy(records: records) ?? []
        var unknown: [String] = []
        for (record, task) in zip(records, migrated) {
            if task["error_code"] as? String == "UNKNOWN_LEGACY_STATE",
               let state = record["state"] as? String {
                unknown.append(state)
            }
        }
        return LegacyMigrationReport(
            totalJobs: records.count,
            migratedJobs: migrated.count,
            unknownStates: Array(Set(unknown)).sorted(),
            accounts: accounts,
            settingsAccounts: settingsAccounts)
    }

    /// One legacy record per job, in the shape the core's
    /// `migrate_legacy` expects. Native states map to legacy states
    /// (`completed -> confirmed`, `confirming`/`paired` ->
    /// `confirmation_pending`, `transferring`/`committing` ->
    /// `uploading`); states the core already knows pass through;
    /// anything else (notably `attention`) is left for the core to
    /// mark `failed` + `UNKNOWN_LEGACY_STATE`.
    static func legacyRecord(for job: BackupJob) -> [String: Any] {
        let legacyState: String
        switch job.state {
        case .completed: legacyState = "confirmed"
        case .confirming, .paired: legacyState = "confirmation_pending"
        case .transferring, .committing: legacyState = "uploading"
        case .queued: legacyState = "queued"
        case .preparing: legacyState = "preparing"
        case .paused: legacyState = "paused"
        case .failed: legacyState = "failed"
        case .waiting: legacyState = "waiting_network"
        case .cancelled: legacyState = "cancelled"
        case .attention: legacyState = "attention"
        }
        var asset: [String: Any] = [
            "local_id": job.assetID,
            "media_kind": HarborCoreAdapter.mediaKind(for: job),
        ]
        if let resource = job.resources.first {
            asset["filename"] = (resource.name as NSString).lastPathComponent
            asset["sha1"] = resource.sha1
            asset["sha256"] = resource.sha256
            asset["size"] = resource.size
        }
        return [
            "task_id": job.id,
            "state": legacyState,
            "asset": asset,
            "idempotency_key": job.dedupKey,
            "error_code": job.error.isEmpty ? NSNull() : job.error,
            "attempts": job.attempts,
        ]
    }
}
