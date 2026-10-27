import Foundation

/// Bounded scheduler: a single pass, retaining at most the available lane slots.
/// Kept independent of PhotoKit so large queues can be tested without user media.
struct QueueCandidate {
    let id: String
    let created: Date
    let confirmation: Bool
}

enum QueueMutation { case replace, pause, remove }

enum QueueScaling {
    static let chunkSize = 100
    static let recoveryThreshold = 500
    static let maximumUploads = 12

    static func reconcile(_ proposed: BackupJob, current: BackupJob?, intent: QueueMutation) -> BackupJob {
        guard let current else { return proposed }
        var value = proposed
        switch intent {
        case .replace:
            // A callback may have saved a newer checkpoint during a prior chunk.
            guard (current.generation ?? 0) <= (proposed.generation ?? 0) else { return current }
        case .pause:
            guard current.unfinished, current.state != .cancelled else { return current }
            value = current; value.state = .paused
        case .remove:
            guard current.unfinished else { return current }
            value = current; value.removeFromActivity()
        }
        value.updated = Date()
        value.generation = max(value.generation ?? 0, (current.generation ?? 0) + 1)
        return value
    }

    static func select(_ candidates: some Sequence<QueueCandidate>, uploads: Int, confirmations: Int) -> [String] {
        guard uploads > 0 || confirmations > 0 else { return [] }
        var upload: [QueueCandidate] = [], confirmation: [QueueCandidate] = []
        for candidate in candidates {
            let capacity = candidate.confirmation ? confirmations : uploads
            guard capacity > 0 else { continue }
            if candidate.confirmation { insert(candidate, into: &confirmation, capacity: capacity) }
            else { insert(candidate, into: &upload, capacity: capacity) }
        }
        return (upload + confirmation).map(\.id)
    }

    private static func insert(_ candidate: QueueCandidate, into values: inout [QueueCandidate], capacity: Int) {
        let index = values.firstIndex { $0.created > candidate.created || ($0.created == candidate.created && $0.id > candidate.id) } ?? values.count
        guard index < capacity else { return }
        values.insert(candidate, at: index)
        if values.count > capacity { values.removeLast() }
    }
}

/// Admission uses sets rather than scanning the persisted queue for each asset.
struct QueueAdmissionIndex {
    private var known = Set<String>(), active = Set<String>(), preparing = Set<String>()
    mutating func remember(_ job: BackupJob, account: String, origin: BackupOrigin) {
        if job.state != .cancelled || (origin == .automatic && job.activityHidden == true) { known.insert(job.discoveryKey(origin: origin)) }
        if job.state.active || job.state == .queued || job.state == .paused { active.insert(job.dedupKey) }
        if job.account == account && job.canRefreshSource && [.queued, .preparing, .waiting, .paused].contains(job.state) {
            preparing.insert(job.assetID + "|" + job.settings.mediaPolicy)
        }
    }
    mutating func accept(_ job: BackupJob, origin: BackupOrigin, force: Bool = false, recreate: Bool = false) -> Bool {
        let preparation = job.assetID + "|" + job.settings.mediaPolicy
        guard !preparing.contains(preparation),
              !(origin == .automatic && !force && !recreate && known.contains(job.discoveryKey(origin: origin))),
              !active.contains(job.dedupKey) else { return false }
        known.insert(job.discoveryKey(origin: origin)); active.insert(job.dedupKey); preparing.insert(preparation)
        return true
    }
}

/// Per-account recovery holds only scheduling/discovery; it never removes jobs.
/// A marker is scoped to expensive queue operations, not to the upload session.
struct QueueRecovery {
    private let defaults: UserDefaults
    private let key = "backup.queueRecovery.v1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    private var records: [String: String] { defaults.dictionary(forKey: key) as? [String: String] ?? [:] }
    func requiresReview(account: String, unfinished: Int) -> Bool {
        guard !account.isEmpty else { return false }
        return records[account] == "interrupted" || (unfinished >= QueueScaling.recoveryThreshold && records[account] == nil)
    }
    func begin(account: String) { set("interrupted", account: account) }
    func finish(account: String) { set("ready", account: account) }
    private func set(_ state: String, account: String) {
        guard !account.isEmpty else { return }
        var values = records; values[account] = state; defaults.set(values, forKey: key)
    }
}
