import Foundation

enum ActivitySource: String, CaseIterable, Identifiable {
    case all, manual, automatic
    var id: String { rawValue }
    var title: String { self == .all ? L10n.text("全部来源") : self == .manual ? L10n.text("手动") : L10n.text("自动") }
    func matches(_ job: BackupJob) -> Bool { self == .all || job.origin?.rawValue == rawValue }
}
enum ActivityStatus: String, CaseIterable, Identifiable {
    case all, unfinished, completed
    var id: String { rawValue }
    var title: String { self == .all ? L10n.text("全部") : self == .unfinished ? L10n.text("未完成") : L10n.text("已完成") }
    func matches(_ job: BackupJob) -> Bool {
        self == .all || (self == .completed ? job.state == .completed : job.unfinished && job.state != .cancelled)
    }
}
struct ActivityBatch: Identifiable {
    var id: String
    var allJobs: [BackupJob]
    var matching: [BackupJob]
    var isBatch: Bool { allJobs.count > 1 }
    var created: Date { allJobs.last?.created ?? .distantPast }
    var title: String { (allJobs.first?.origin?.title ?? L10n.text("历史备份")) + L10n.text("批次") }
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
        if skippedExisting { return [L10n.text("准备照片"), L10n.text("检查是否已备份"), L10n.text("确认保存"), L10n.text("完成")] }
        return [isVideo ? L10n.text("准备视频") : L10n.text("准备照片"), L10n.text("检查是否已备份"), isVideo ? L10n.text("上传视频") : L10n.text("上传照片"), L10n.text("确认保存")] + (isLive && settings.requiresStrictConfirmation ? [L10n.text("等待云端处理")] : []) + [L10n.text("完成")]
    }
    var isVideo: Bool { !isLive && (mediaKind == "video" || (sources.isEmpty ? resources : sources).contains { $0.role.hasSuffix(".video") }) }
    var flowIndex: Int {
        if state == .completed { return flowSteps.count - 1 }
        if resources.isEmpty { return 0 }
        if standardConfirmationPassed { return isLive && settings.requiresStrictConfirmation ? 4 : 3 }
        if state == .committing { return 3 }
        if state == .transferring || resources.contains(where: { $0.transportID != nil }) { return 2 }
        if error == "PREVIOUS_BACKUP_NOT_VISIBLE" { return 1 }
        if failureStage == "pair_lookup" { return livePairs?.contains(where: { $0.queryOnly }) == true ? 3 : 1 }
        if failureStage == "prepare_upload" { return 1 }
        if failureStage == "pair_transfer" { return 2 }
        if resources.contains(where: { !$0.confirmed && !$0.submitted && $0.responsePath == nil && $0.remoteKey.isEmpty }) { return 1 }
        return 3
    }
    var displayStatus: String {
        if skippedExisting { return L10n.text("已存在，跳过") }
        if [.paused, .waiting, .failed, .attention, .cancelled, .completed, .queued].contains(state) { return state.title }
        return flowSteps[flowIndex]
    }
    var friendlyMessage: String {
        if skippedExisting { return L10n.text("所需内容已在云端找到并通过检查，已跳过上传。") }
        if state == .completed && reusedSome { return L10n.text("已完成备份，部分内容复用了已有云端资源。") }
        if error.isEmpty {
            if state == .cancelled { return L10n.text("任务已取消，本机及云端照片保留。") }
            if state == .paired { return L10n.text("照片和视频已保存，正在等待云端完成动态处理。") }
            if state == .paused { return L10n.text("任务已暂停，继续后会从已有进度推进。") }
            return state == .completed ? L10n.text("已按本任务的检查策略完成备份。") : L10n.text("可以离开此页面，进度会持续保存。")
        }
        if error == "REMOTE_MOTION_TRASHED" { return L10n.text("云端项目已在回收站，请先到谷歌相册恢复。") }
        if error.hasPrefix("REMOTE_MOTION_") { return L10n.text("照片和视频已保存，正在等待云端完成动态处理。") }
        if error == "PAIR_CONFIRMATION_PENDING" || error == "REMOTE_NOT_VISIBLE" { return L10n.text("资源已发送，正在确认云端保存结果。") }
        return HarborError(error).localizedDescription
            .replacingOccurrences(of: "（\(error)）", with: "")
            .replacingOccurrences(of: "(\(error))", with: "")
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

enum LiveCleanupPolicy {
    static var waitingMessage: String { L10n.text("等待 Live Photo 完整验证") }
    static func permits(_ job: BackupJob, settings: BackupSettings) -> Bool {
        !job.isLive || (settings.allowsUnverifiedLiveCleanup && job.standardConfirmationPassed)
    }
}

enum CleanupCandidates {
    static func policyMatches(_ captured: BackupSettings, current: BackupSettings) -> Bool {
        captured.cleanupPolicy == current.cleanupPolicy && captured.wifiOnly == current.wifiOnly
    }
    static func select(_ jobs: [BackupJob], account: String) -> [BackupJob] {
        var seen = Set<String>()
        return jobs.filter { $0.account == account && $0.activityHidden != true && $0.state == .completed }
            .sorted { $0.created > $1.created }.filter { seen.insert($0.assetID).inserted }
    }
    static func remainingSelection(_ selected: Set<String>, eligible: [String]) -> Set<String> {
        selected.intersection(Set(eligible))
    }
}

/// Selection belongs to this screen session; ignored assets stay ignored after a recheck.
struct CleanupSelection {
    var selected = Set<String>()
    private(set) var ignoredAssets = Set<String>()

    mutating func reconcile(eligible: [String], jobs: [BackupJob]) {
        let allowed = Set(eligible)
        selected.formIntersection(allowed)
        for job in jobs where allowed.contains(job.id) && !ignoredAssets.contains(job.assetID) {
            selected.insert(job.id)
        }
    }
    mutating func toggle(_ job: BackupJob) {
        if selected.remove(job.id) != nil { ignoredAssets.insert(job.assetID) }
        else { ignoredAssets.remove(job.assetID); selected.insert(job.id) }
    }
    mutating func selectAll(eligible: [String], jobs: [BackupJob]) {
        for job in jobs where eligible.contains(job.id) { ignoredAssets.remove(job.assetID) }
        reconcile(eligible: eligible, jobs: jobs)
    }
    mutating func deselectAll(jobs: [BackupJob]) {
        for job in jobs where selected.contains(job.id) { ignoredAssets.insert(job.assetID) }
        selected.removeAll()
    }
}

enum CleanupOutcome: String, CaseIterable, Identifiable {
    case all, eligible, deferred, failed, removed
    var id: String { rawValue }
    var title: String {
        switch self { case .all: return L10n.text("全部"); case .eligible: return L10n.text("可清理"); case .deferred: return L10n.text("暂不能"); case .failed: return L10n.text("失败"); case .removed: return L10n.text("已处理") }
    }
    static func failure(_ error: Error) -> CleanupOutcome {
        guard let code = (error as? HarborError)?.code else { return .failed }
        return ["LIVE_CLEANUP_UNVERIFIED", "LIVE_COMPONENT_UNVERIFIED", "CLEANUP_UNVERIFIED", "SOURCE_CHANGED", "REMOTE_MISSING", "CLOUD_ORIGINAL_UNCONFIRMED", "ORIGINAL_UNAVAILABLE"].contains(code) ? .deferred : .failed
    }
}
