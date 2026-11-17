import Foundation

/// Thin adapter over the shared business core (`gpmc.harbor_core`).
///
/// The adapter only does JSON encoding/decoding, calls into the embedded
/// Python runtime through `PythonBridge`, and keeps the core task dicts the
/// stateless core hands back. It makes no business decisions of its own:
/// the native backup flow (see `HarborModel`) still decides when to look
/// up, upload, commit and confirm; the core records those decisions and
/// answers dedup / cleanup-guidance questions.
///
/// Frozen interface (see `docs/MOBILE-UNIFICATION-INVENTORY.md`):
/// `harbor_core.dispatch_json(action, payload_str) -> str`, returning
/// `{"ok": True, ...}` or `{"ok": False, "error": CODE}`. Stage-1 actions:
/// `create_task`, `transition`, `decide_prepare`, `decide_cleanup`,
/// `retry_delay`, `store_save`, `store_load`, `log_event`, `capabilities`,
/// plus the module-level `migrate_legacy`.
/// Stage-2 actions (land in `harbor_core` progressively; every method
/// below treats `UNKNOWN_OPERATION` / `RUNTIME_UNAVAILABLE` as "the core
/// does not know this action yet" and returns nil so the caller runs its
/// documented local fallback — never a crash, never a fabricated answer):
/// `batch_pause`, `batch_resume`, `evaluate_scope`, `validate_proxy`,
/// `livelink_handshake`, `livelink_scope`, `migrate_legacy` (dispatchable).
/// Task ids are the native job ids; the idempotency key is the job's
/// `dedupKey`. Core state is persisted with `store_save` / `store_load`
/// to `harbor-core-tasks.json` under the app-support home.
///
/// When the core is unavailable (`harbor_core` not synced yet, Python
/// runtime down, or any call failing), every method here degrades to a
/// documented fallback (`nil` / `false`) and the caller fails the job
/// with a retryable error instead of running business decisions
/// without the core. Since stage 2 there is no legacy business path:
/// the core is the only business core. Failures surface as
/// `ENGINE_ERROR` or `RUNTIME_UNAVAILABLE`, reusing the `HarborError`
/// code mapping.
///
/// Privacy: no content hash, full path, account identifier or credential
/// is ever logged from this file. Filenames are basenames only.
@MainActor
final class HarborCoreAdapter {
    private let home: URL
    private let queue = DispatchQueue(label: "io.picharbor.harbor-core", qos: .userInitiated)

    /// Set by `probe()`. False until the core answers `capabilities`.
    private(set) var available = false

    /// Core task dicts by task id (== native job id), loaded from the
    /// store at boot and saved after every mutation.
    private var tasks: [String: [String: Any]] = [:]
    private var repository: BackupStore?
    private struct StoredTask: Codable { let id: String; let payload: Data; let revision: Int64 }

    func configureStore(_ value: BackupStore) { repository = value }

    var storePath: String { home.appendingPathComponent("harbor-core-tasks.json").path }

    init(home: URL) {
        self.home = home
    }

    // MARK: - Raw dispatch

    /// One core call. Never throws: failures come back as
    /// `["ok": false, "error": CODE]`.
    func dispatch(action: String, payload: [String: Any]) async -> [String: Any] {
        var envelope = payload
        envelope["protocol_version"] = 2
        envelope["request_id"] = UUID().uuidString
        guard let data = try? JSONSerialization.data(withJSONObject: envelope),
              let input = String(data: data, encoding: .utf8) else {
            return ["ok": false, "error": "ENGINE_ERROR"]
        }
        // Never block the main actor on Python: the bridge releases the
        // GIL for I/O, but local core calls still run on this thread.
        let output: String = await withCheckedContinuation { continuation in
            queue.async {
                let result = PythonBridge.call("core_\(action)", payload: input, event: { _ in })
                continuation.resume(returning: result)
            }
        }
        guard let data = output.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ["ok": false, "error": "ENGINE_ERROR"]
        }
        MobileDiagnostics.shared.record("core.operation", task: (payload["task"] as? [String: Any])?["task_id"] as? String ?? "", fields: ["stage": action, "error_code": decoded["error"] as? String ?? ""])
        if decoded["ok"] as? Bool == true { return decoded }
        return ["ok": false, "error": decoded["error"] as? String ?? "ENGINE_ERROR"]
    }

    /// Probe once per boot. True when the core answers with version 1.
    /// Also loads the persisted task table into the cache.
    func probe() async -> Bool {
        let result = await dispatch(action: "capabilities", payload: [:])
        guard result["ok"] as? Bool == true,
              result["harbor_core_version"] as? Int == 1,
              result["protocol_version"] as? Int == 2,
              let actions = result["actions"] as? [String],
              Set(["create_task", "transition", "evaluate_scope", "batch_pause", "batch_resume"]).isSubset(of: Set(actions)) else {
            available = false
            return false
        }
        available = true
        await loadStore()
        return available
    }

    /// True when a core reply means "this action is not available in the
    /// synced core" (action not yet added, or the core module not synced).
    /// Callers treat this as "run the documented local fallback"; any
    /// other core error is a real answer, not an unavailability.
    static func isCoreUnavailable(_ result: [String: Any]) -> Bool {
        guard result["ok"] as? Bool != true else { return false }
        return ["UNKNOWN_OPERATION", "RUNTIME_UNAVAILABLE"].contains(result["error"] as? String ?? "")
    }

    // MARK: - Persistence (store_save / store_load)

    func loadStore() async {
        guard let repository else { available = false; return }
        do {
            let values = try await repository.load(StoredTask.self, kind: "core-task")
            if !values.isEmpty {
                tasks = try Dictionary(uniqueKeysWithValues: values.map { value in
                    guard let task = try JSONSerialization.jsonObject(with: value.payload) as? [String: Any] else { throw HarborError("DATABASE_ERROR") }
                    return (value.id, task)
                })
                return
            }
        } catch { available = false; return }
        // One-time compatible import. Subsequent writes use the native database.
        let result = await dispatch(action: "store_load", payload: ["path": storePath])
        guard result["ok"] as? Bool == true,
              let loaded = result["tasks"] as? [String: [String: Any]] else { return }
        tasks = loaded
        await saveStore()
    }

    func saveStore() async {
        guard let repository else { available = false; return }
        do {
            for (id, task) in tasks {
                let revision = (task["revision"] as? NSNumber)?.int64Value ?? 0
                let value = StoredTask(id: id, payload: try JSONSerialization.data(withJSONObject: task), revision: revision)
                try await repository.save(value, kind: "core-task", id: id, revision: revision)
            }
        } catch { available = false }
    }

    /// Restart recovery: in-flight tasks from a previous process become
    /// `interrupted` and may be retried. Returns the task ids that are
    /// interrupted afterwards (including ones already interrupted).
    /// A missing store file (first boot) is not an error.
    func restore() async -> [String] {
        guard available else { return [] }
        await loadStore()
        var interrupted: [String] = []
        // Snapshot first: transition() mutates the table, and mutating a
        // dictionary while iterating it traps at runtime.
        for (id, task) in Array(tasks) {
            switch task["state"] as? String ?? "" {
            case "uploading", "submitting", "confirming":
                if await transition(jobID: id, to: "interrupted", save: false) != nil {
                    interrupted.append(id)
                }
            case "interrupted":
                interrupted.append(id)
            default:
                break
            }
        }
        await saveStore()
        return interrupted
    }

    // MARK: - Tasks

    func task(for jobID: String) -> [String: Any]? { tasks[jobID] }

    /// One media item, any kind. The core task is per job (one media
    /// item): a video carries `media_kind=video` plus `duration_seconds`
    /// and `size`; a Live Photo carries `media_kind=live_photo` and is
    /// represented by its photo resource — photo and paired video are
    /// decided and confirmed together, never as two media items.
    /// `duration_seconds` is informational; the core keeps the fields it
    /// validates and drops the rest.
    private func assetDict(job: BackupJob, resource: MediaResource) -> [String: Any] {
        var asset: [String: Any] = [
            "local_id": job.assetID,
            "filename": (resource.name as NSString).lastPathComponent,
            "sha1": resource.sha1,
            "sha256": resource.sha256,
            "size": resource.size,
            "media_kind": Self.mediaKind(for: job),
        ]
        if let duration = resource.durationSeconds { asset["duration_seconds"] = duration }
        return asset
    }

    /// Core media kind for a job. Motion Photo packages are one live
    /// media item (`motion_photo`); Apple-paired Live Photos are
    /// `live_photo`; video is `video`; everything else is `photo`.
    /// The core accepts exactly these four kinds.
    /// Pure computation on the passed-in job, no adapter state, so it
    /// is `nonisolated`: callers outside the main actor (e.g. the
    /// sync `legacyRecord(for:)`) can use it without hopping.
    nonisolated static func mediaKind(for job: BackupJob) -> String {
        if job.isLive {
            return job.settings.live == .motion ? "motion_photo" : "live_photo"
        }
        if job.mediaKind == "video" || job.isVideo { return "video" }
        return "photo"
    }

    /// Any job with exported resources runs on the shared core: ordinary
    /// photos, videos and Live Photo / multi-resource jobs alike. The
    /// stage-1 photo-only gate (`isPhotoCoreJob`) is gone with the legacy
    /// fallback — there is one active business path, the core.
    func isCoreJob(_ job: BackupJob) -> Bool {
        available && !job.resources.isEmpty
    }

    /// Representative resource for a job's single core task: the first
    /// unconfirmed resource, else the first resource.
    private func representativeResource(for job: BackupJob) -> MediaResource? {
        job.resources.first(where: { !$0.confirmed }) ?? job.resources.first
    }

    /// Create the core task for a job (or re-sync an existing one) from
    /// its representative resource. Used by the Live Photo path, where
    /// the per-resource loop does not call `ensureTask(job:resource:)`.
    func ensureTask(job: BackupJob) async -> [String: Any]? {
        guard let resource = representativeResource(for: job) else { return nil }
        return await ensureTask(job: job, resource: resource)
    }

    /// Create the core task for a job (or re-sync an existing one) and
    /// move it to `preparing`, which counts the attempt. Returns the
    /// current core task dict, or nil when the core is unavailable or
    /// the asset is invalid. The caller treats nil as a hard failure
    /// (`ENGINE_ERROR`): since stage 2 there is no legacy path that
    /// runs business decisions without the core.
    func ensureTask(job: BackupJob, resource: MediaResource) async -> [String: Any]? {
        guard available else { return nil }
        if let cached = tasks[job.id] {
            switch cached["state"] as? String ?? "" {
            case "paused", "failed", "interrupted", "waiting_network":
                // A retry starts from queued; queued -> preparing counts it.
                guard await transition(jobID: job.id, to: "queued", save: false) != nil else { return nil }
                return await transition(jobID: job.id, to: "preparing")
            case "queued":
                return await transition(jobID: job.id, to: "preparing")
            default:
                return cached
            }
        }
        var createPayload: [String: Any] = [
            "task_id": job.id,
            "asset": assetDict(job: job, resource: resource),
            "idempotency_key": job.dedupKey,
        ]
        // Batch creation is tracked per job; the batch id rides along so
        // the core can group the batch when it learns to. Unknown
        // payload keys are ignored by the core.
        if let batchID = job.batchID { createPayload["batch_id"] = batchID }
        let result = await dispatch(action: "create_task", payload: createPayload)
        guard result["ok"] as? Bool == true,
              let task = result["task"] as? [String: Any] else { return nil }
        tasks[job.id] = task
        await saveStore()
        guard available else { return nil }
        return await transition(jobID: job.id, to: "preparing")
    }

    /// One state transition. Returns the updated task dict, or nil on an
    /// illegal edge / missing task / core failure. A nil result is always
    /// safe for the caller to ignore (best effort): the native flow keeps
    /// its own state and the core simply stays behind.
    func transition(jobID: String, to state: String, errorCode: String? = nil,
                    remoteKey: String? = nil, save: Bool = true) async -> [String: Any]? {
        guard available, let task = tasks[jobID] else { return nil }
        var payload: [String: Any] = ["task": task, "to": state]
        if state == "done" { payload["cloud_confirmed"] = true }
        if let errorCode { payload["error_code"] = errorCode }
        if let remoteKey, !remoteKey.isEmpty { payload["remote_key"] = remoteKey }
        let result = await dispatch(action: "transition", payload: payload)
        guard result["ok"] as? Bool == true,
              let updated = result["task"] as? [String: Any] else { return nil }
        guard (tasks[jobID]?["revision"] as? Int ?? 0) == (task["revision"] as? Int ?? 0) else { return nil }
        tasks[jobID] = updated
        if save { await saveStore() }
        return available ? updated : nil
    }

    // MARK: - Decisions

    /// Dedup decision for an asset. The caller supplies `remoteKey` from
    /// a prior hash lookup (`prepare_upload`); the core performs no
    /// network here. Returns true when the remote already holds the
    /// asset, false when it must be uploaded, nil on core failure.
    func decidePrepare(job: BackupJob, resource: MediaResource, remoteKey: String?) async -> Bool? {
        guard available else { return nil }
        var payload: [String: Any] = ["asset": assetDict(job: job, resource: resource)]
        if let remoteKey { payload["remote_key"] = remoteKey }
        let result = await dispatch(action: "decide_prepare", payload: payload)
        guard result["ok"] as? Bool == true else { return nil }
        return result["exists"] as? Bool
    }

    /// Cleanup-guidance eligibility, from per-item evidence only. The
    /// evidence items come from reconcile / cloud-confirmation results
    /// (`cleanupEvidenceItems(for:)`): one entry per cloud-confirmed
    /// media item, with the confirmation time. With no evidence the
    /// result is nil and the caller shows only page-level guidance —
    /// never per-item release, never fabricated evidence. Eligible never
    /// authorises PicHarbor to delete anything: it only allows showing
    /// the official Google Photos free-up-space guidance.
    /// The payload also carries the stage-1 fields (`cloud_state`,
    /// `checked_at`, `policy`) so the current core can answer before the
    /// items-aware core lands; the extended core judges the items.
    func decideCleanupEligibility(job: BackupJob) async -> Bool? {
        guard available, let task = tasks[job.id],
              let items = Self.cleanupEvidenceItems(for: job),
              let checkedAt = items.first?["confirmed_at"] as? Int else { return nil }
        let evidence: [String: Any] = [
            "cloud_state": "confirmed_original",
            "checked_at": checkedAt,
            "policy": true,
            "items": items,
        ]
        let result = await dispatch(action: "decide_cleanup", payload: [
            "task": task,
            "evidence": evidence,
        ])
        guard result["ok"] as? Bool == true else { return nil }
        return result["eligible"] as? Bool
    }

    /// Per-item cleanup evidence for a job, or nil when there is none.
    /// An item counts only when the whole media item is cloud-confirmed
    /// (`standardConfirmationPassed`) and a real confirmation time
    /// exists (`lastConfirmationAt`, else `completedAt`). Nothing here
    /// is estimated: without a confirmation result there is no item.
    static func cleanupEvidenceItems(for job: BackupJob) -> [[String: Any]]? {
        guard job.standardConfirmationPassed,
              let confirmedAt = job.lastConfirmationAt ?? job.completedAt else { return nil }
        return [[
            "task_id": job.id,
            "cloud_confirmed": true,
            "confirmed_at": Int(confirmedAt.timeIntervalSince1970),
        ]]
    }

    /// Core backoff for a 0-based failed-attempt count (5 s, doubling,
    /// capped at 300 s). The native 0.2.27 task-protection budgets stay
    /// authoritative for scheduling; this is exposed for callers that
    /// need the core's delay. Returns nil on core failure.
    func retryDelay(attempt: Int) async -> TimeInterval? {
        guard available else { return nil }
        let result = await dispatch(action: "retry_delay", payload: ["attempt": attempt])
        guard result["ok"] as? Bool == true else { return nil }
        if let seconds = result["delay_seconds"] as? Double { return seconds }
        if let seconds = result["delay_seconds"] as? Int { return TimeInterval(seconds) }
        return nil
    }

    /// Redacted copy of an event for safe logging, per the core's
    /// redaction rules (basenames only, no hashes, no secrets).
    /// Returns nil on core failure.
    func logEvent(_ event: [String: Any]) async -> [String: Any]? {
        guard available else { return nil }
        let result = await dispatch(action: "log_event", payload: ["event": event])
        guard result["ok"] as? Bool == true else { return nil }
        return result["event"] as? [String: Any]
    }

    // MARK: - Stage-2 core actions
    //
    // Each method returns nil when the synced core does not know the
    // action yet (UNKNOWN_OPERATION / RUNTIME_UNAVAILABLE); the caller
    // then runs its documented local fallback. A non-nil result is the
    // core's answer and is authoritative.

    /// Mirror a batch pause into the core state machine. Returns the
    /// per-task core states, or nil when the core does not know
    /// `batch_pause` yet (caller falls back to per-task transitions).
    /// The core takes `tasks` as a `{task_id: task}` map and returns
    /// `results` as a list of per-task entries; a single failure never
    /// interrupts the batch. Updated task dicts are written back into
    /// the cache (and the store) so later transitions start from the
    /// true state instead of a stale one.
    func batchPause(taskIDs: Set<String>) async -> [String: String]? {
        await batchTransition(action: "batch_pause", taskIDs: taskIDs)
    }

    /// Mirror a batch resume into the core state machine. Same shape
    /// as `batchPause`. Note the core only resumes from `paused` /
    /// `interrupted` — `failed` / `attention` jobs fail per task and
    /// are re-synced by `ensureTask` on their next run instead.
    func batchResume(taskIDs: Set<String>) async -> [String: String]? {
        await batchTransition(action: "batch_resume", taskIDs: taskIDs)
    }

    private func batchTransition(action: String, taskIDs: Set<String>) async -> [String: String]? {
        guard available, !taskIDs.isEmpty else { return nil }
        let known = Dictionary(uniqueKeysWithValues: taskIDs.compactMap { id in
            tasks[id].map { (id, $0) }
        })
        let result = await dispatch(action: action, payload: [
            "task_ids": Array(taskIDs).sorted(),
            "tasks": known,
        ])
        guard !Self.isCoreUnavailable(result), result["ok"] as? Bool == true,
              let entries = result["results"] as? [[String: Any]] else { return nil }
        var states: [String: String] = [:]
        for entry in entries {
            guard let id = entry["task_id"] as? String else { continue }
            if let updated = entry["task"] as? [String: Any] {
                tasks[id] = updated
                states[id] = updated["state"] as? String ?? ""
            } else {
                states[id] = tasks[id]?["state"] as? String ?? ""
            }
        }
        await saveStore()
        return states
    }

    /// Backup scope as a core `evaluate_scope` scope dict. Mode is
    /// `all` with no album restriction, else `advanced` with the
    /// selected albums. `version` is 2 (scope2): a core that does not
    /// know this scope version must error, and the caller must then
    /// exclude the asset — never fall back to the full library.
    static func scopeDictionary(for settings: BackupSettings) -> [String: Any] {
        [
            "version": 2,
            "mode": settings.selectedAlbums.isEmpty ? "all" : "advanced",
            "albums": settings.selectedAlbums,
            "dateEnabled": false,
            "from": NSNull(),
            "to": NSNull(),
            "photos": true,
            "videos": true,
            "ignoreSmallImages": false,
            "minImageKb": 100,
            "filterCache": false,
        ]
    }

    /// Ask the core whether one asset is inside the backup scope.
    /// Returns true (include) / false (exclude), or nil when the core
    /// does not know `evaluate_scope` yet (caller keeps the local
    /// scope result). A core scope error is a real answer: it returns
    /// false, so an unknown scope version never falls back to the
    /// full library. `asset` carries `local_id`, `media_kind` and,
    /// when known, `created_at` (epoch seconds) and `duration_seconds`.
    func evaluateScope(scope: [String: Any], asset: [String: Any]) async -> Bool? {
        guard available else { return nil }
        let result = await dispatch(action: "evaluate_scope", payload: ["scope": scope, "asset": asset])
        if Self.isCoreUnavailable(result) { return nil }
        guard result["ok"] as? Bool == true else { return false }
        if let included = result["included"] as? Bool { return included }
        if let allowed = result["allowed"] as? Bool { return allowed }
        if let inScope = result["in_scope"] as? Bool { return inScope }
        return false
    }

    /// Validate the proxy configuration with the core. Only explicit
    /// proxy parameters travel: enabled flag, the local loopback
    /// endpoint the traffic goes through (`127.0.0.1` + the primary
    /// node's loopback port), scheme, node names, fallback and
    /// selection policy — plus `verify_tls: true`, because TLS
    /// verification must stay on. No node configuration, no credential
    /// and no secret ever enters the core or the log — credentials stay
    /// in the Keychain (`ProxySecretStore`). TLS validation itself
    /// stays native (URLSession pinning) and is untouched by this call.
    /// Returns true (valid) / false (invalid — caller must not route),
    /// or nil when the core does not know `validate_proxy` yet, or when
    /// there is no primary loopback port to validate against.
    func validateProxy(preferences: ProxyPreferences, primaryPort: Int?) async -> Bool? {
        guard available, let primaryPort else { return nil }
        var proxy: [String: Any] = [
            "enabled": preferences.enabled,
            "host": "127.0.0.1",
            "port": primaryPort,
            "scheme": "http",
            "verify_tls": true,
            "primary": preferences.primary,
            "backups": preferences.backups,
            "fallback": preferences.fallback.rawValue,
            "selection": (preferences.selection ?? .manual).rawValue,
            "exhaustion": (preferences.exhaustion ?? .wait).rawValue,
        ]
        if !preferences.enabled { proxy = ["enabled": false] }
        let result = await dispatch(action: "validate_proxy", payload: proxy)
        if Self.isCoreUnavailable(result) { return nil }
        if let valid = result["valid"] as? Bool { return valid }
        return result["ok"] as? Bool == true
    }

    /// LiveLink handshake: confirm the paired computer speaks the
    /// scope2/catalog2 capabilities this client announces in hello.
    /// Returns true (compatible) / false (incompatible — caller must
    /// refuse the session), or nil when the core does not know
    /// `livelink_handshake` yet (caller keeps the local hello flow).
    func livelinkHandshake() async -> Bool? {
        guard available else { return nil }
        let result = await dispatch(action: "livelink_handshake", payload: [
            "capabilities": ["scope2", "catalog2"],
        ])
        if Self.isCoreUnavailable(result) { return nil }
        if let compatible = result["compatible"] as? Bool { return compatible }
        return result["ok"] as? Bool == true
    }

    /// LiveLink scope check for one asset under a computer-requested
    /// scope. Returns `(inScope, requiresConfirmation, scopeValid)`,
    /// or nil when the core does not know `livelink_scope` yet.
    /// `scopeValid` is false when the core rejects the scope itself
    /// (`INVALID_SCOPE` — unknown scope version, unknown mode); the
    /// caller must then refuse the scope, never fall back to the full
    /// library. `inScope` is per asset; a successful check always
    /// carries `requires_confirmation: true`, which the caller honors
    /// with the existing offer/accept gate — never a transfer on a
    /// scope check alone.
    func livelinkScope(scope: [String: Any], asset: [String: Any]) async -> (inScope: Bool, requiresConfirmation: Bool, scopeValid: Bool)? {
        guard available else { return nil }
        let result = await dispatch(action: "livelink_scope", payload: ["scope": scope, "asset": asset])
        if Self.isCoreUnavailable(result) { return nil }
        guard result["ok"] as? Bool == true else { return (false, false, false) }
        let inScope = (result["in_scope"] as? Bool) ?? true
        let requiresConfirmation = (result["requires_confirmation"] as? Bool) ?? true
        return (inScope, requiresConfirmation, true)
    }

    /// Migrate pre-unification task records through the core. Returns
    /// the migrated task dicts, or nil on a core error. When the core
    /// does not know `migrate_legacy` yet (it is a module function in
    /// the stage-1 core, not yet a dispatched action), the identical
    /// mapping is applied locally: `confirmed -> done`,
    /// `confirmation_pending -> waiting_confirmation`,
    /// `uploading` / `interrupted -> interrupted`, current states kept
    /// as-is, unknown states -> `failed` + `UNKNOWN_LEGACY_STATE`.
    /// Migration is preview-only at the call sites: nothing here
    /// writes or deletes stored data.
    func migrateLegacy(records: [[String: Any]]) async -> [[String: Any]]? {
        guard available else { return Self.migrateLegacyLocally(records: records) }
        let result = await dispatch(action: "migrate_legacy", payload: ["records": records])
        if Self.isCoreUnavailable(result) { return Self.migrateLegacyLocally(records: records) }
        guard result["ok"] as? Bool == true,
              let tasks = result["tasks"] as? [[String: Any]] else { return nil }
        return tasks
    }

    /// Local mirror of the core `migrate_legacy` mapping, used only
    /// while the dispatched action is unavailable. Kept identical to
    /// `gpmc.harbor_core.migrate_legacy` by construction; if the two
    /// ever disagree, the core wins once the action lands.
    static func migrateLegacyLocally(records: [[String: Any]]) -> [[String: Any]]? {
        let legacyStates: [String: String] = [
            "confirmed": "done",
            "confirmation_pending": "waiting_confirmation",
            "uploading": "interrupted",
            "interrupted": "interrupted",
        ]
        let currentStates: Set<String> = ["queued", "preparing", "dedup_hit", "uploading", "submitting",
                                          "confirming", "done", "paused", "failed", "waiting_network",
                                          "waiting_confirmation", "cancelled", "interrupted"]
        var migrated: [[String: Any]] = []
        for record in records {
            guard let taskID = record["task_id"] as? String, !taskID.isEmpty else { return nil }
            var task = record
            let state = record["state"] as? String ?? ""
            if let mapped = legacyStates[state] {
                task["state"] = mapped
            } else if currentStates.contains(state) {
                task["state"] = state
            } else {
                task["state"] = "failed"
                task["error_code"] = "UNKNOWN_LEGACY_STATE"
            }
            if task["asset"] == nil { task["asset"] = [:] as [String: Any] }
            if task["attempts"] == nil { task["attempts"] = 0 }
            if task["idempotency_key"] == nil { task["idempotency_key"] = record["idempotency_key"] as? String }
            if task["remote_key"] == nil { task["remote_key"] = record["remote_key"] as? String }
            if task["cloud_confirmed"] == nil { task["cloud_confirmed"] = task["state"] as? String == "done" }
            migrated.append(task)
        }
        return migrated
    }

    // MARK: - Native state mirrors

    /// Native job state -> core state. `attention` has no core
    /// equivalent and maps to `failed` with the native error code kept.
    static func coreState(for job: BackupJob) -> String {
        switch job.state {
        case .queued: return "queued"
        case .preparing: return "preparing"
        case .transferring: return "uploading"
        case .committing: return "submitting"
        case .confirming, .paired: return "confirming"
        case .completed: return "done"
        case .paused: return "paused"
        case .failed: return "failed"
        case .cancelled: return "cancelled"
        case .waiting:
            if job.error == "WAITING_NETWORK" { return "waiting_network" }
            if ["REMOTE_NOT_VISIBLE", "PAIR_CONFIRMATION_PENDING"].contains(job.error)
                || job.error.hasPrefix("REMOTE_MOTION_") { return "waiting_confirmation" }
            return "waiting_network"
        case .attention: return "failed"
        }
    }

    /// Best-effort mirror of the native state into the core. Illegal
    /// edges are ignored: the native flow is authoritative.
    func mirrorNativeState(_ job: BackupJob) async {
        guard available, tasks[job.id] != nil else { return }
        _ = await transition(jobID: job.id, to: Self.coreState(for: job),
                             errorCode: job.error.isEmpty ? nil : job.error)
    }

    /// Resume re-sync: a paused/failed/interrupted/waiting core task
    /// returns to `queued`; the next pipeline run walks it forward.
    func resumeCoreJob(_ job: BackupJob) async {
        guard available, let task = tasks[job.id] else { return }
        switch task["state"] as? String ?? "" {
        case "paused", "failed", "interrupted", "waiting_network":
            _ = await transition(jobID: job.id, to: "queued")
        default:
            break
        }
    }

    /// Record the native completion decision in the core. The native
    /// standard-confirmation check stays authoritative; this only walks
    /// the core task to its terminal `done` state along legal edges
    /// (best effort). A resumed job may sit in `preparing` with its
    /// upload already confirmed: it walks the dedup shortcut when the
    /// upload was skipped, otherwise the upload/commit/confirm states
    /// the native flow has already passed. Applies to every media kind:
    /// photo, video and Live Photo share one core task per job.
    func finishJob(_ job: BackupJob) async {
        guard available, let current = tasks[job.id] else { return }
        let state = current["state"] as? String ?? ""
        guard state != "done" else { return }
        let key = job.resources.first?.remoteKey
        let remoteKey = (key?.isEmpty == false) ? key : nil
        if await transition(jobID: job.id, to: "done", remoteKey: remoteKey) != nil { return }
        let path: [String]
        switch state {
        case "preparing":
            path = (job.skippedExisting || job.resources.allSatisfy { $0.reused == true })
                ? ["dedup_hit", "done"] : ["uploading", "submitting", "confirming", "done"]
        case "uploading":
            path = ["submitting", "confirming", "done"]
        case "submitting":
            path = ["confirming", "done"]
        case "dedup_hit", "confirming", "waiting_confirmation":
            path = ["done"]
        default:
            path = []
        }
        for step in path {
            let isLast = step == "done"
            guard await transition(jobID: job.id, to: step,
                                   remoteKey: isLast ? remoteKey : nil) != nil else { break }
        }
    }
}
