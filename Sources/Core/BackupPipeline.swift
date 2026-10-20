import Foundation

enum PipelineMode: String, Codable, CaseIterable {
    case automatic, custom
    var title: String { self == .automatic ? L10n.text("自动") : L10n.text("自定义") }
}
enum PipelineStage: String, Codable, CaseIterable {
    case preparation, lookup, upload, commit, confirmation
    var title: String {
        switch self {
        case .preparation: return L10n.text("准备照片")
        case .lookup: return L10n.text("检查是否已备份")
        case .upload: return L10n.text("上传照片")
        case .commit: return L10n.text("确认保存")
        case .confirmation: return L10n.text("确认云端内容")
        }
    }
}
struct PipelineLimits: Codable, Equatable {
    var preparation: Int = 1
    var lookup: Int = 2
    var upload: Int = 4
    var commit: Int = 2
    var confirmation: Int = 1
    var bufferMB: Int = 512
    var valid: Bool {
        (1...3).contains(preparation) && (1...4).contains(lookup) && (1...12).contains(upload) &&
        (1...4).contains(commit) && (1...4).contains(confirmation) && (128...8192).contains(bufferMB)
    }
    var bufferBytes: Int64 { Int64(bufferMB) * 1024 * 1024 }
    func capacity(_ stage: PipelineStage) -> Int {
        switch stage {
        case .preparation: return preparation
        case .lookup: return lookup
        case .upload: return upload
        case .commit: return commit
        case .confirmation: return confirmation
        }
    }
    var diagnostic: [String: Int] { ["preparation": preparation, "lookup": lookup, "upload": upload, "commit": commit, "confirmation": confirmation, "buffer_mb": bufferMB] }
}
struct PipelineConditions: Equatable {
    var machine = "unknown"
    var memoryGB: Int = 4
    var availableMemory: UInt64 = 512 * 1024 * 1024
    var processors = 4
    var thermal = 0
    var lowPower = false
    var memoryWarning = false
    var freeDisk: Int64 = 4 * 1024 * 1024 * 1024
}
enum PipelineProfiles {
    // Stable machine identifiers, not user-visible names. Future/unknown models
    // start conservatively; RAM and runtime pressure always cap a preset.
    private static let performance: Set<String> = ["iPhone16,1", "iPhone16,2", "iPhone17,1", "iPhone17,2", "iPhone17,3", "iPhone17,4", "iPhone17,5"]
    private static let balanced: Set<String> = ["iPhone14,2", "iPhone14,3", "iPhone14,7", "iPhone14,8", "iPhone15,2", "iPhone15,3", "iPhone15,4", "iPhone15,5"]
    static func recommended(_ device: PipelineConditions) -> PipelineLimits {
        if performance.contains(device.machine), device.memoryGB >= 8 {
            return PipelineLimits(preparation: 2, lookup: 3, upload: 6, commit: 2, confirmation: 2, bufferMB: 768)
        }
        if balanced.contains(device.machine), device.memoryGB >= 6 {
            return PipelineLimits(preparation: 1, lookup: 2, upload: 4, commit: 2, confirmation: 1, bufferMB: 512)
        }
        return PipelineLimits(preparation: 1, lookup: 2, upload: device.memoryGB >= 4 ? 3 : 2, commit: 1, confirmation: 1, bufferMB: 256)
    }
    static func effective(settings: BackupSettings, device: PipelineConditions) -> PipelineLimits {
        var value = settings.pipelineMode == .custom && settings.pipelineOverrides?.valid == true ? settings.pipelineOverrides! : recommended(device)
        // All modes retain resource protection. Existing transfers finish;
        // these limits only control admission of additional work.
        if device.memoryGB < 6 { value.preparation = min(value.preparation, 1); value.upload = min(value.upload, 4) }
        if device.lowPower || device.thermal >= 2 || device.processors <= 2 || device.availableMemory < 256 * 1024 * 1024 {
            value.preparation = min(value.preparation, 1); value.lookup = min(value.lookup, 1)
            value.upload = min(value.upload, 2); value.commit = min(value.commit, 1); value.confirmation = min(value.confirmation, 1)
        }
        if device.memoryWarning || device.thermal >= 3 || device.availableMemory < 128 * 1024 * 1024 || device.freeDisk < 128 * 1024 * 1024 {
            value.preparation = 0; value.upload = min(value.upload, 1)
        }
        value.bufferMB = min(value.bufferMB, max(64, Int(max(0, device.freeDisk - 128 * 1024 * 1024) / (1024 * 1024))))
        return value
    }
}
struct PipelineCandidate {
    var id: String
    var stage: PipelineStage
    var created: Date
}
enum PipelineScheduler {
    static func stage(_ job: BackupJob, hasPlan: Bool) -> PipelineStage {
        if job.resources.isEmpty { return .preparation }
        if hasPlan { return .upload }
        if job.confirmationOnly { return .confirmation }
        if job.isLive && job.settings.live != .motion {
            // Match the processor's order. A completed earlier version must not
            // force the pending version back into the confirmation lane.
            guard let pair = job.livePairs?.first(where: { !$0.isConfirmed(in: job.resources) }) else { return .lookup }
            if pair.queryOnly { return .confirmation }
            guard let photo = job.resources.first(where: { $0.id == pair.photoID }),
                  let video = job.resources.first(where: { $0.id == pair.videoID }) else { return .lookup }
            if pair.route == "reconcile" {
                if photo.remoteKey.isEmpty {
                    if photo.submitted { return .confirmation }
                    return photo.responsePath == nil ? .lookup : .commit
                }
                return video.responsePath == nil ? .lookup : .commit
            }
            return photo.responsePath != nil && video.responsePath != nil ? .commit : .lookup
        }
        // Ordinary and Motion Photo versions are processed in resource order too.
        guard let resource = job.resources.first(where: { !$0.confirmed }) else { return .confirmation }
        if resource.submitted { return .confirmation }
        return resource.responsePath == nil ? .lookup : .commit
    }
    static func select(_ candidates: some Sequence<PipelineCandidate>, limits: PipelineLimits, occupied: [PipelineStage: Int], bufferedBytes: Int64, readyPlans: Int = 0) -> [PipelineCandidate] {
        var selected: [PipelineStage: [PipelineCandidate]] = [:]
        for value in candidates {
            let capacity = max(0, limits.capacity(value.stage) - (occupied[value.stage] ?? 0))
            guard capacity > 0, value.stage != .preparation || bufferedBytes < limits.bufferBytes else { continue }
            if value.stage == .lookup && readyPlans >= max(2, limits.upload * 2) { continue }
            var items = selected[value.stage] ?? []
            let index = items.firstIndex { $0.created > value.created || ($0.created == value.created && $0.id > value.id) } ?? items.count
            if index < capacity { items.insert(value, at: index); if items.count > capacity { items.removeLast() }; selected[value.stage] = items }
        }
        return [.upload, .commit, .lookup, .confirmation, .preparation].flatMap { selected[$0] ?? [] }
    }
    static func bufferedBytes(_ jobs: [BackupJob], account: String) -> Int64 {
        jobs.lazy.filter { $0.account == account && $0.unfinished && $0.state != .cancelled && $0.state != .transferring }
            .flatMap(\.resources).filter { !$0.confirmed && !$0.submitted && $0.responsePath == nil }.reduce(0) { $0 + $1.size }
    }
}

/// One oversize asset can make progress when the prefetch buffer is empty.
/// Additional preparations yield instead of filling the disk with partial files.
final class PipelineBufferBudget: @unchecked Sendable {
    private let lock = NSLock()
    private var limit: Int64 = 0, base: Int64 = 0
    private var writers: [String: Int64] = [:]
    private var primary: String?
    func configure(limit: Int64, base: Int64) { lock.lock(); defer { lock.unlock() }; self.limit = limit; self.base = base }
    func begin(_ id: String) { lock.lock(); defer { lock.unlock() }; writers[id] = 0; if primary == nil { primary = id } }
    func finish(_ id: String) { lock.lock(); defer { lock.unlock() }; writers.removeValue(forKey: id); if primary == id { primary = writers.keys.sorted().first } }
    func reserve(_ bytes: Int64, job: String) throws {
        lock.lock(); defer { lock.unlock() }
        let total = base + writers.values.reduce(0, +) + bytes
        guard total <= limit || (base == 0 && primary == job) else { throw HarborError("STAGING_BUFFER_WAIT") }
        writers[job, default: 0] += bytes
    }
}
