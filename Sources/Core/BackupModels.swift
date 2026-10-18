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
    var attempts = 0
    var retryAt: Date?
    var created = Date()
    var updated = Date()
    var albumIDs: [String] = []
    var albumsPending = false
    var progress: Double = 0
    var evidence: CleanupEvidence?
    var dedupKey: String { "\(account)|\(assetID)|\(assetRevision)|\(settings.mediaPolicy)" }
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
