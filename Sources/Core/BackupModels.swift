import Foundation

enum UploadQuality: String, Codable, CaseIterable, Identifiable {
    case original, quota, saver
    var id: String { rawValue }
    var title: String {
        switch self { case .original: return "不计配额原画质"; case .quota: return "计配额原画质"; case .saver: return "节省空间" }
    }
}
enum LiveStrategy: String, Codable, CaseIterable, Identifiable {
    case motion, applePair
    var id: String { rawValue }
    var title: String { self == .motion ? "Motion Photo" : "苹果原始资源配对方式" }
}
enum EditPolicy: String, Codable, CaseIterable, Identifiable {
    case both, original, current
    var id: String { rawValue }
    var title: String { self == .both ? "原始与编辑后均保留" : self == .original ? "仅原始版本" : "仅编辑后版本" }
}
struct BackupSettings: Codable, Equatable {
    var quality: UploadQuality = .original
    var live: LiveStrategy = .motion
    var edits: EditPolicy = .both
    var automatic = false
    var scopeConfirmed: Bool?
    var wifiOnly = true
    var syncAlbums = false
    var selectedAlbums: [String] = []
    var cloudState = true
    var originalAccess = true
    var appearance = "system"
    var cleanupPolicy: String { "\(cloudState ? 1 : 0)\(originalAccess ? 1 : 0)" }
    // Scheduling/network/cleanup preferences do not change the encoded media identity.
    var mediaPolicy: String { "\(quality.rawValue):\(live.rawValue):\(edits.rawValue):mux1" }
}
enum JobState: String, Codable {
    case queued, preparing, transferring, committing, confirming, completed, paused, waiting, failed, attention, cancelled
    var title: String {
        switch self {
        case .queued: return "等待备份"
        case .preparing: return "准备原件"
        case .transferring: return "传输中"
        case .committing: return "提交中"
        case .confirming: return "待云端确认"
        case .completed: return "已备份"
        case .paused: return "已暂停"
        case .waiting: return "等待条件"
        case .failed: return "可重试"
        case .attention: return "需要处理"
        case .cancelled: return "已取消"
        }
    }
    var active: Bool { [.preparing, .transferring, .committing, .confirming].contains(self) }
}
enum TransferDisposition: Equatable { case run, pause, cancel }
enum BackupOrigin: String, Codable, CaseIterable {
    case manual, automatic
    var title: String { self == .manual ? "手动备份" : "自动备份" }
}
struct AssetBackupState {
    var account: String
    var revision: String
    var state: JobState
    var created: Date
}
struct MediaResource: Codable, Identifiable, Equatable {
    var id = UUID().uuidString
    var role: String
    var path: String
    var name: String
    var sha1 = ""
    var sha256 = ""
    var size: Int64 = 0
    var remoteKey = ""
    var confirmed = false
    var transportID: Int?
    var responsePath: String?
    var submitted = false
}
struct BackupJob: Codable, Identifiable {
    var id = UUID().uuidString
    var generation: Int64?
    var origin: BackupOrigin?
    var batchID: String?
    var activityHidden: Bool?
    var account: String
    var assetID: String
    var assetRevision: String
    var settings: BackupSettings
    var state: JobState = .queued
    var resources: [MediaResource] = []
    // Exported source manifests are retained even when Motion Photo replaces upload resources.
    var sources: [MediaResource] = []
    var isLive = false
    var forceUpload = false
    var error = ""
    var failureStage: String?
    var failureSystemCode: String?
    var attempts = 0
    var retryAt: Date?
    var created = Date()
    var updated = Date()
    var albumIDs: [String] = []
    var albumsPending = false
    var progress: Double = 0
    var evidence: CleanupEvidence?
    var dedupKey: String { "\(account)|\(assetID)|\(assetRevision)|\(settings.mediaPolicy)" }
    var unfinished: Bool { state != .completed && activityHidden != true }
    @discardableResult
    mutating func updateNetwork(wifiOnly: Bool) -> Set<Int> {
        guard state != .completed, state != .cancelled else { return [] }
        settings.wifiOnly = wifiOnly
        if error == "WAITING_NETWORK" { error = ""; retryAt = nil; attempts = 0 }
        let oldIDs = Set(resources.compactMap(\.transportID))
        for index in resources.indices { resources[index].transportID = nil }
        if state == .transferring { state = .queued; progress = 0 }
        return oldIDs
    }
    mutating func removeFromActivity() {
        guard state != .completed else { return }
        state = .cancelled; activityHidden = true; evidence = nil; retryAt = nil
    }
    var failureStageTitle: String? {
        guard let failureStage else { return nil }
        return ["preparation": "准备暂存目录", "export": "从相册导出资源", "motion_package": "封装动态照片",
                "source_read": "读取暂存原件", "prepare_upload": "查重与申请上传", "transfer_creation": "创建后台传输",
                "upload_response": "保存上传响应", "commit_response": "读取响应并提交云端", "confirmation": "确认云端内容"][failureStage] ?? "其他处理步骤"
    }
    mutating func recordFailure(_ code: String, stage: String, committingResourceID: String?) {
        error = code; failureStage = stage
        if stage == "commit_response", code.hasPrefix("UPLOAD_RESPONSE_"),
           let index = resources.firstIndex(where: { $0.id == committingResourceID }) {
            resources[index].submitted = false; resources[index].responsePath = nil
        }
    }
    func transferDisposition(activeAccount: String) -> TransferDisposition {
        if state == .cancelled || state == .completed { return .cancel }
        if activeAccount.isEmpty || account != activeAccount || state != .transferring { return .pause }
        return .run
    }
}

struct ActivityGroup: Identifiable {
    var id: String
    var origin: BackupOrigin?
    var jobs: [BackupJob]
    var date: Date { jobs.map(\.created).min() ?? .distantPast }
    static func groups(_ jobs: [BackupJob], byBatch: Bool) -> [ActivityGroup] {
        let grouped = Dictionary(grouping: jobs.filter { $0.activityHidden != true }) { job in
            byBatch ? (job.batchID.map { job.account + ":" + $0 } ?? job.account + ":legacy") : job.account + ":" + (job.origin?.rawValue ?? "legacy")
        }
        return grouped.map { key, values in
            ActivityGroup(id: key, origin: values.first?.origin, jobs: values.sorted { $0.created > $1.created })
        }.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }
}
struct CleanupEvidence: Codable {
    var account: String
    var revision: String
    var policy: String
    var manifest: [String]
    var checked = Date()
    func valid(job: BackupJob, settings: BackupSettings, now: Date = Date()) -> Bool {
        account == job.account && revision == job.assetRevision && policy == settings.cleanupPolicy &&
        now.timeIntervalSince(checked) >= 0 && now.timeIntervalSince(checked) < 300 &&
        manifest == job.sources.map { "\($0.role):\($0.sha256)" }.sorted() && job.state == .completed
    }
}
struct AlbumMapping: Codable {
    var account: String
    var localID: String
    var remoteID: String
}
struct AssetSnapshot: Codable {
    var id: String
    var revision: String
    var mediaType: Int
    var accessible: Bool
}
