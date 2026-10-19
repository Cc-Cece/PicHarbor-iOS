import Foundation

enum ActivitySource: String, CaseIterable, Identifiable {
    case all, manual, automatic
    var id: String { rawValue }
    var title: String { self == .all ? "全部来源" : self == .manual ? "手动" : "自动" }
    func matches(_ job: BackupJob) -> Bool { self == .all || job.origin?.rawValue == rawValue }
}
enum ActivityStatus: String, CaseIterable, Identifiable {
    case all, unfinished, completed
    var id: String { rawValue }
    var title: String { self == .all ? "全部" : self == .unfinished ? "未完成" : "已完成" }
    func matches(_ job: BackupJob) -> Bool {
        self == .all || (self == .completed ? job.state == .completed : job.unfinished && job.state != .cancelled)
    }
}
struct ActivityBatch: Identifiable {
    var id: String
    var allJobs: [BackupJob]
    var matching: [BackupJob]
    var isBatch: Bool { allJobs.count > 1 }
    var created: Date { allJobs.map(\.created).min() ?? .distantPast }
    var title: String { (allJobs.first?.origin?.title ?? "历史备份") + "批次" }
    static func make(_ jobs: [BackupJob], source: ActivitySource, status: ActivityStatus) -> [ActivityBatch] {
        let visible = jobs.filter { $0.activityHidden != true && source.matches($0) }
        let groups = Dictionary(grouping: visible) { $0.account + "|" + ($0.batchID ?? "single:" + $0.id) }
        return groups.compactMap { key, values in
            let sorted = values.sorted { $0.created > $1.created }
            let matching = sorted.filter(status.matches)
            return matching.isEmpty ? nil : ActivityBatch(id: key, allJobs: sorted, matching: matching)
        }.sorted { $0.created == $1.created ? $0.id < $1.id : $0.created > $1.created }
    }
}

extension BackupJob {
    var flowSteps: [String] {
        ["准备照片", "上传资源", "确认保存"] + (isLive && settings.requiresStrictConfirmation ? ["严格核验"] : []) + ["完成"]
    }
    var flowIndex: Int {
        if state == .completed { return flowSteps.count - 1 }
        if resources.isEmpty { return 0 }
        if standardConfirmationPassed { return isLive && settings.requiresStrictConfirmation ? 3 : 2 }
        if resources.contains(where: { !$0.confirmed && $0.responsePath == nil && $0.remoteKey.isEmpty }) { return 1 }
        return 2
    }
    var friendlyMessage: String {
        if error.isEmpty {
            if state == .paired { return "照片与视频已配对，正在等待严格核验。" }
            if state == .paused { return "任务已暂停，继续后会从已有进度推进。" }
            return state == .completed ? "已按本任务的检查策略完成备份。" : "可以离开此页面，进度会持续保存。"
        }
        if error.hasPrefix("REMOTE_MOTION_") { return "云端仍在准备动态照片，稍后会自动检查。" }
        if error == "PAIR_CONFIRMATION_PENDING" || error == "REMOTE_NOT_VISIBLE" { return "资源已发送，正在确认云端保存结果。" }
        return HarborError(error).localizedDescription
    }
    var diagnosticText: String {
        let value: [String: Any] = ["task_reference": id, "state": state.rawValue,
            "stage": failureStage ?? "unknown", "error": error, "system_error": failureSystemCode ?? "",
            "resource_count": resources.count, "source_count": sources.count,
            "pair_confirmed": hasConfirmedPairs, "strict_requested": settings.requiresStrictConfirmation,
            "verification_level": verificationLevel ?? "legacy", "checks": confirmationChecks ?? 0,
            "last_query_seconds": lastConfirmationSeconds ?? 0]
        return String(decoding: (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])) ?? Data(), as: UTF8.self)
    }
}

enum CleanupCandidates {
    static func select(_ jobs: [BackupJob], account: String) -> [BackupJob] {
        var seen = Set<String>()
        return jobs.filter { $0.account == account && $0.activityHidden != true && $0.state == .completed }
            .sorted { $0.created > $1.created }.filter { seen.insert($0.assetID).inserted }
    }
    static func remainingSelection(_ selected: Set<String>, eligible: [String]) -> Set<String> {
        selected.intersection(Set(eligible))
    }
}

enum CleanupOutcome: String, CaseIterable, Identifiable {
    case all, eligible, deferred, failed, removed
    var id: String { rawValue }
    var title: String {
        switch self { case .all: return "全部"; case .eligible: return "可清理"; case .deferred: return "暂不能"; case .failed: return "失败"; case .removed: return "已处理" }
    }
    static func failure(_ error: Error) -> CleanupOutcome {
        guard let code = (error as? HarborError)?.code else { return .failed }
        return ["LIVE_CLEANUP_UNVERIFIED", "CLEANUP_UNVERIFIED", "SOURCE_CHANGED", "REMOTE_MISSING", "CLOUD_ORIGINAL_UNCONFIRMED", "ORIGINAL_UNAVAILABLE"].contains(code) ? .deferred : .failed
    }
}
