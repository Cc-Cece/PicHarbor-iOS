import Foundation

enum UploadQuality: String, Codable, CaseIterable, Identifiable {
    case original, quota, saver
    var id: String { rawValue }
    var title: String {
        switch self { case .original: return "不计配额原画质"; case .quota: return "计配额原画质"; case .saver: return "节省空间" }
    }
}
enum LiveStrategy: String, Codable, CaseIterable, Identifiable {
    case motion, applePair, appleReconcile
    var id: String { rawValue }
    var title: String {
        switch self {
        case .motion: return "Motion Photo"
        case .applePair: return "原始配对 · 联合提交（测试）"
        case .appleReconcile: return "原始配对 · 先照片后视频（测试）"
        }
    }
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
    case queued, preparing, transferring, committing, confirming, paired, completed, paused, waiting, failed, attention, cancelled
    var title: String {
        switch self {
        case .queued: return "等待备份"
        case .preparing: return "准备原件"
        case .transferring: return "传输中"
        case .committing: return "提交中"
        case .confirming: return "待云端确认"
        case .paired: return "即将完成 · 配对已确认"
        case .completed: return "已备份"
        case .paused: return "已暂停"
        case .waiting: return "等待条件"
        case .failed: return "可重试"
        case .attention: return "需要处理"
        case .cancelled: return "已取消"
        }
    }
    var active: Bool { [.preparing, .transferring, .committing, .confirming, .paired].contains(self) }
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
    var assetCreated: Date?
    var assetModified: Date?
    var livePairs: [LivePairRecord]?
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
    var sourceWaits: Int?
    var pairedAt: Date?
    var confirmationStartedAt: Date?
    var completedAt: Date?
    var confirmationChecks: Int?
    var confirmationRetries: Int?
    var lastConfirmationAt: Date?
    var lastConfirmationSeconds: Double?
    var retryAt: Date?
    var created = Date()
    var updated = Date()
    var albumIDs: [String] = []
    var albumsPending = false
    var progress: Double = 0
    var evidence: CleanupEvidence?
    var dedupKey: String { "\(account)|\(assetID)|\(assetRevision)|\(settings.mediaPolicy)" }
    func discoveryKey(origin: BackupOrigin) -> String {
        origin == .automatic ? "\(account)|\(assetID)|\(assetRevision)" : dedupKey
    }
    var unfinished: Bool { state != .completed && activityHidden != true }
    var hasConfirmedPairs: Bool {
        guard isLive, settings.live != .motion, let pairs = livePairs, !pairs.isEmpty,
              let expected = try? LivePairRecord.make(resources), expected.count == pairs.count else { return false }
        return expected.allSatisfy { expectedPair in
            guard let pair = pairs.first(where: { $0.id == expectedPair.id }), pair.confirmed, !pair.remoteKey.isEmpty,
                  pair.photoID == expectedPair.photoID, pair.videoID == expectedPair.videoID else { return false }
            return resources.filter { $0.id == pair.photoID || $0.id == pair.videoID }.allSatisfy {
                $0.confirmed && $0.remoteKey == pair.remoteKey
            }
        }
    }
    var confirmationOnly: Bool {
        isLive && !resources.isEmpty && resources.allSatisfy(\.confirmed) &&
        (settings.live == .motion || hasConfirmedPairs)
    }
    func canSchedule(alongside running: [BackupJob]) -> Bool {
        running.filter { $0.confirmationOnly == confirmationOnly }.count < (confirmationOnly ? 1 : 2)
    }
    var statusSymbol: String {
        state == .completed || state == .paired ? "checkmark.circle.fill" :
        state == .failed || state == .attention ? "exclamationmark.circle" : "icloud.and.arrow.up"
    }
    mutating func beginConfirmation(now: Date = Date()) {
        state = hasConfirmedPairs ? .paired : .confirming
        if hasConfirmedPairs && pairedAt == nil { pairedAt = now }
        if confirmationStartedAt == nil { confirmationStartedAt = now }
        confirmationChecks = (confirmationChecks ?? 0) + 1
        lastConfirmationAt = now; error = ""; failureStage = "confirmation"
    }
    mutating func waitForConfirmation(now: Date = Date()) {
        attempts = max(0, attempts - 1)
        confirmationRetries = (confirmationRetries ?? 0) + 1
        state = hasConfirmedPairs ? .paired : .confirming
        retryAt = now.addingTimeInterval(min(30, pow(2, Double(min(confirmationRetries!, 4) - 1)) * 5))
    }
    // Rebinding is allowed only before any exported or remotely submitted resource exists.
    var canRefreshSource: Bool {
        resources.isEmpty && sources.isEmpty && (livePairs ?? []).isEmpty && evidence == nil &&
        state != .completed && state != .cancelled
    }
    mutating func refreshSource(revision: String, live: Bool, created: Date?, modified: Date?) throws {
        guard canRefreshSource else { throw HarborError("SOURCE_SNAPSHOT_LOCKED") }
        assetRevision = revision; isLive = live; assetCreated = created; assetModified = modified
    }
    mutating func waitForSource(now: Date = Date()) {
        // PhotoKit settling must not consume the unrelated network retry budget.
        attempts = max(0, attempts - 1)
        sourceWaits = (sourceWaits ?? 0) + 1
        if sourceWaits! <= 6 {
            state = .waiting; retryAt = now.addingTimeInterval(min(60, Double(sourceWaits!) * 5))
        } else { state = .attention; error = "SOURCE_SETTLING_LIMIT"; retryAt = nil }
    }
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
        return ["preparation": "准备暂存目录", "source_stability": "等待相册资源稳定", "export": "从相册导出资源", "motion_package": "封装动态照片",
                "source_read": "读取暂存原件", "prepare_upload": "查重与申请上传", "transfer_creation": "创建后台传输",
                "upload_response": "保存上传响应", "commit_response": "读取响应并提交云端", "confirmation": "确认云端内容",
                "pair_export": "准备原始配对资源", "pair_lookup": "检查照片与视频关联", "pair_photo_commit": "提交配对用原图",
                "pair_transfer": "传输原始配对资源", "pair_commit": "关联照片与视频", "pair_confirmation": "确认同一云端动态项目"][failureStage] ?? "其他处理步骤"
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

/// Three matching observations are a bounded debounce, not a guarantee that a
/// camera asset will never change again. Export must independently check it.
struct SourceStabilityProbe {
    private var previous: String?
    private var matches = 0
    mutating func observe(_ signature: String) -> Bool {
        matches = signature == previous ? matches + 1 : 1
        previous = signature
        return matches >= 3
    }
    @MainActor
    static func wait<Value>(read: () throws -> (Value, String), pause: () async throws -> Void) async throws -> Value {
        var probe = SourceStabilityProbe()
        for _ in 0..<6 {
            let (value, signature) = try read()
            if probe.observe(signature) { return value }
            try await pause()
        }
        throw HarborError("SOURCE_SETTLING")
    }
}

struct LivePairRecord: Codable, Identifiable {
    var id: String
    var photoID: String
    var videoID: String
    var route: String?
    var submitted = false
    var confirmed = false
    var remoteKey = ""
    var queryOnly: Bool { submitted || confirmed }
    static func make(_ resources: [MediaResource]) throws -> [LivePairRecord] {
        var pairs: [LivePairRecord] = []
        for version in ["original", "current"] {
            let photos = resources.filter { $0.role == version + ".photo" }
            let videos = resources.filter { $0.role == version + ".pairedVideo" }
            if photos.isEmpty && videos.isEmpty { continue }
            guard photos.count == 1, videos.count == 1 else { throw HarborError("LIVE_PAIR_MISSING") }
            pairs.append(LivePairRecord(id: version, photoID: photos[0].id, videoID: videos[0].id))
        }
        guard !pairs.isEmpty, pairs.count * 2 == resources.count,
              Set(resources.map(\.id)).count == resources.count else { throw HarborError("LIVE_PAIR_MISSING") }
        return pairs
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
