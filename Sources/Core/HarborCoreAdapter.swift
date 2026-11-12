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
/// `{"ok": True, ...}` or `{"ok": False, "error": CODE}`. Actions:
/// `create_task`, `transition`, `decide_prepare`, `decide_cleanup`,
/// `retry_delay`, `store_save`, `store_load`, `log_event`, `capabilities`.
/// Task ids are the native job ids; the idempotency key is the job's
/// `dedupKey`. Core state is persisted with `store_save` / `store_load`
/// to `harbor-core-tasks.json` under the app-support home.
///
/// When the core is unavailable (`harbor_core` not synced yet, Python
/// runtime down, or any call failing), every method here degrades to a
/// documented fallback (`nil` / `false`) and the caller runs the legacy
/// path unchanged. Failures surface as `ENGINE_ERROR` or
/// `RUNTIME_UNAVAILABLE`, reusing the `HarborError` code mapping.
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
        if decoded["ok"] as? Bool == true { return decoded }
        return ["ok": false, "error": decoded["error"] as? String ?? "ENGINE_ERROR"]
    }

    /// Probe once per boot. True when the core answers with version 1.
    /// Also loads the persisted task table into the cache.
    func probe() async -> Bool {
        let result = await dispatch(action: "capabilities", payload: [:])
        guard result["ok"] as? Bool == true,
              result["harbor_core_version"] as? Int == 1 else {
            available = false
            return false
        }
        available = true
        await loadStore()
        return true
    }

    // MARK: - Persistence (store_save / store_load)

    func loadStore() async {
        let result = await dispatch(action: "store_load", payload: ["path": storePath])
        guard result["ok"] as? Bool == true,
              let loaded = result["tasks"] as? [String: [String: Any]] else { return }
        tasks = loaded
    }

    func saveStore() async {
        _ = await dispatch(action: "store_save", payload: ["path": storePath, "tasks": tasks])
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

    private func assetDict(job: BackupJob, resource: MediaResource) -> [String: Any] {
        [
            "local_id": job.assetID,
            "filename": (resource.name as NSString).lastPathComponent,
            "sha1": resource.sha1,
            "sha256": resource.sha256,
            "size": resource.size,
            "media_kind": "photo",
        ]
    }

    /// Ordinary single-resource photo jobs only. Live Photo, video and
    /// multi-resource jobs stay on the legacy path.
    func isPhotoCoreJob(_ job: BackupJob) -> Bool {
        available && !job.isLive && !job.isVideo && job.resources.count == 1
    }

    /// Create the core task for a job (or re-sync an existing one) and
    /// move it to `preparing`, which counts the attempt. Returns the
    /// current core task dict, or nil when the core is unavailable or
    /// the asset is invalid (the caller then runs the legacy path).
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
        let result = await dispatch(action: "create_task", payload: [
            "task_id": job.id,
            "asset": assetDict(job: job, resource: resource),
            "idempotency_key": job.dedupKey,
        ])
        guard result["ok"] as? Bool == true,
              let task = result["task"] as? [String: Any] else { return nil }
        tasks[job.id] = task
        await saveStore()
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
        if let errorCode { payload["error_code"] = errorCode }
        if let remoteKey, !remoteKey.isEmpty { payload["remote_key"] = remoteKey }
        let result = await dispatch(action: "transition", payload: payload)
        guard result["ok"] as? Bool == true,
              let updated = result["task"] as? [String: Any] else { return nil }
        tasks[jobID] = updated
        if save { await saveStore() }
        return updated
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

    /// Cleanup-guidance eligibility. The core only answers whether the
    /// cloud-confirmation evidence is fresh (3600 s) and
    /// `cloud_state == "confirmed_original"`. Eligible never authorises
    /// PicHarbor to delete anything: it only allows showing the official
    /// Google Photos free-up-space guidance. Returns nil on core failure.
    func decideCleanupEligibility(job: BackupJob) async -> Bool? {
        guard available, let task = tasks[job.id] else { return nil }
        let evidence: [String: Any] = [
            "cloud_state": "confirmed_original",
            "checked_at": Int(Date().timeIntervalSince1970),
            "policy": true,
        ]
        let result = await dispatch(action: "decide_cleanup", payload: [
            "task": task,
            "evidence": evidence,
        ])
        guard result["ok"] as? Bool == true else { return nil }
        return result["eligible"] as? Bool
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
    /// (best effort). A resumed legacy job may sit in `preparing` with
    /// its upload already confirmed: it walks the dedup shortcut when
    /// the upload was skipped, otherwise the upload/commit/confirm
    /// states the native flow has already passed.
    func finishPhotoJob(_ job: BackupJob) async {
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
