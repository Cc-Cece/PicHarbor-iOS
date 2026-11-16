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
enum ActivityTaskOrder {
    static func priority(_ job: BackupJob, now: Date) -> Int {
        switch job.state {
        case .preparing, .transferring, .committing: return 0
        case .confirming, .paired: return (job.retryAt ?? .distantPast) <= now ? 0 : 2
        case .queued, .waiting: return (job.retryAt ?? .distantPast) <= now ? 1 : 2
        case .paused, .failed, .attention: return 3
        case .completed: return 4
        case .cancelled: return 5
        }
    }
    static func precedes(_ lhs: BackupJob, _ rhs: BackupJob, now: Date) -> Bool {
        let left = priority(lhs, now: now), right = priority(rhs, now: now)
        if left != right { return left < right }
        if lhs.created != rhs.created { return left < 4 ? lhs.created < rhs.created : lhs.created > rhs.created }
        return lhs.id < rhs.id
    }
}

struct ActivityBatch: Identifiable {
    var id: String
    var allJobs: [BackupJob]
    var matching: [BackupJob]
    var isBatch: Bool { allJobs.count > 1 }
    var created: Date { allJobs.last?.created ?? .distantPast }
    var title: String { (allJobs.first?.origin?.title ?? L10n.text("历史备份")) + L10n.text("批次") }
    static func make(_ jobs: [BackupJob], source: ActivitySource, status: ActivityStatus, queueOrder: Bool = true, now: Date = Date()) -> [ActivityBatch] {
        let visible = jobs.filter { $0.activityHidden != true && source.matches($0) }
        let groups = Dictionary(grouping: visible) { $0.account + "|" + ($0.batchID ?? "single:" + $0.id) }
        return groups.compactMap { key, values in
            let sorted = values.sorted { $0.created > $1.created }
            let filtered = sorted.filter(status.matches)
            let matching = queueOrder ? filtered.sorted { ActivityTaskOrder.precedes($0, $1, now: now) } : filtered
            return matching.isEmpty ? nil : ActivityBatch(id: key, allJobs: sorted, matching: matching)
        }.sorted {
            if queueOrder, let left = $0.matching.first, let right = $1.matching.first {
                let lp = ActivityTaskOrder.priority(left, now: now), rp = ActivityTaskOrder.priority(right, now: now)
                if lp != rp { return lp < rp }
                if lp < 4 { return ActivityTaskOrder.precedes(left, right, now: now) }
            }
            return $0.created == $1.created ? $0.id < $1.id : $0.created > $1.created
        }
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
        if let pipelineStage {
            switch pipelineStage {
            case .preparation: return 0
            case .lookup: return 1
            case .upload: return 2
            case .commit: return 3
            case .confirmation: return standardConfirmationPassed && isLive && settings.requiresStrictConfirmation ? 4 : 3
            }
        }
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
            "pipeline_stage": pipelineStage?.rawValue ?? "legacy", "pipeline_seconds": pipelineSeconds ?? [:],
            "automatic_failures": recovery?.failures ?? 0, "last_attempt_error": lastAttemptError ?? "",
            "active_without_progress_seconds": recovery?.activeWithoutProgress ?? 0, "handoffs_without_progress": recovery?.handoffs ?? 0,
            "cloud_wait_seconds": recovery?.cloudSeconds ?? 0, "transfer_idle_seconds": transferWatch?.idle ?? 0,
            "stage": failureStage ?? "unknown", "error": error, "system_error": failureSystemCode ?? "",
            "resource_count": resources.count, "source_count": sources.count,
            "pair_confirmed": hasConfirmedPairs, "strict_requested": settings.requiresStrictConfirmation,
            "verification_level": verificationLevel ?? "legacy", "checks": confirmationChecks ?? 0,
            "last_query_seconds": lastConfirmationSeconds ?? 0]
        return String(decoding: (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])) ?? Data(), as: UTF8.self)
    }
}

// Legacy self-built cleanup candidate/selection types
// (`LiveCleanupPolicy`, `CleanupCandidates`, `CleanupSelection`,
// `CleanupOutcome`) were removed in the stage-2 unification pass:
// PicHarbor no longer scans, selects or deletes local assets. The
// only cleanup surface is the official Google Photos free-up-space
// guidance (`CleanupView`), gated per item by the shared core's
// `decide_cleanup` evidence. `CleanupOutcome.failure`'s error-code
// table is gone with it; the codes themselves stay in `Engine` as
// user-facing messages for old jobs that still carry them.
