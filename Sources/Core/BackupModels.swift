import Foundation

enum UploadQuality: String, Codable, CaseIterable, Identifiable {
    case original, quota, saver
    var id: String { rawValue }
    var title: String {
        switch self { case .original: return L10n.text("不计配额原画质"); case .quota: return L10n.text("计配额原画质"); case .saver: return L10n.text("节省空间") }
    }
}
enum LiveStrategy: String, Codable, CaseIterable, Identifiable {
    case motion, applePair, appleReconcile
    var id: String { rawValue }
    var title: String {
        switch self {
        case .motion: return L10n.text("动态照片封装")
        case .applePair: return L10n.text("原始照片配对")
        case .appleReconcile: return L10n.text("原始照片配对（分步上传）")
        }
    }
}
enum EditPolicy: String, Codable, CaseIterable, Identifiable {
    case both, original, current
    var id: String { rawValue }
    var title: String { self == .both ? L10n.text("原始与编辑后均保留") : self == .original ? L10n.text("仅原始版本") : L10n.text("仅编辑后版本") }
}
struct BackupSettings: Codable, Equatable {
    var quality: UploadQuality = .original
    var live: LiveStrategy = .applePair
    var edits: EditPolicy = .both
    var automatic = false
    var scopeConfirmed: Bool?
    var wifiOnly = true
    var syncAlbums = false
    var pipelineMode: PipelineMode?
    var pipelineOverrides: PipelineLimits?
    var executionOverrides: BackupExecutionPolicy?
    var selectedAlbums: [String] = []
    // Legacy cleanup preferences remain decodable for upgrades. No longer used
    // by the native application; local removal is delegated to Google Photos.
    var cloudState = true
    var originalAccess = true
    var appearance = "system"
    var strictLiveConfirmation: Bool?
    var allowUnverifiedLiveCleanup: Bool?
    var allowsUnverifiedLiveCleanup: Bool { allowUnverifiedLiveCleanup ?? false }
    var requiresStrictConfirmation: Bool { strictLiveConfirmation ?? false }
    var cleanupPolicy: String { "\(cloudState ? 1 : 0)\(originalAccess ? 1 : 0):live\(allowsUnverifiedLiveCleanup ? 1 : 0)" }
    // Scheduling/network/cleanup preferences do not change the encoded media identity.
    var mediaPolicy: String { "\(quality.rawValue):\(live.rawValue):\(edits.rawValue):mux1" }
    func restoringDefaults() -> BackupSettings {
        var value = BackupSettings()
        value.appearance = appearance
        return value
    }
}
enum JobState: String, Codable {
    case queued, preparing, transferring, committing, confirming, paired, completed, paused, waiting, failed, attention, cancelled
    var title: String {
        switch self {
        case .queued: return L10n.text("等待备份")
        case .preparing: return L10n.text("准备照片")
        case .transferring: return L10n.text("上传中")
        case .committing: return L10n.text("确认保存")
        case .confirming: return L10n.text("确认保存")
        case .paired: return L10n.text("即将完成 · 配对已确认")
        case .completed: return L10n.text("已备份")
        case .paused: return L10n.text("已暂停")
        case .waiting: return L10n.text("等待条件")
        case .failed: return L10n.text("可重试")
        case .attention: return L10n.text("需要处理")
        case .cancelled: return L10n.text("已取消")
        }
    }
    var active: Bool { [.preparing, .transferring, .committing, .confirming, .paired].contains(self) }
}
enum TransferDisposition: Equatable { case run, pause, cancel }
enum BackupOrigin: String, Codable, CaseIterable {
    case manual, automatic
    var title: String { self == .manual ? L10n.text("手动备份") : L10n.text("自动备份") }
}
struct AssetBackupState {
    var account: String
    var revision: String
    var state: JobState
    var created: Date
    var skipped = false
}

enum LibraryBackupFilter: String, CaseIterable, Identifiable {
    case all, backedUp, notBackedUp
    var id: String { rawValue }
    var title: String {
        switch self { case .all: return L10n.text("全部"); case .backedUp: return L10n.text("已备份"); case .notBackedUp: return L10n.text("未备份") }
    }
    func includes(backedUp: Bool) -> Bool { self == .all || (self == .backedUp ? backedUp : !backedUp) }
}

struct CompletedAssetIndex {
    private struct Version: Hashable { let assetID: String; let revision: String }
    private var versions = Set<Version>()
    private(set) var account = ""
    private(set) var revision = 0
    mutating func reset(account: String) { self.account = account; versions.removeAll(keepingCapacity: true); revision += 1 }
    mutating func include(_ jobs: [BackupJob], account: String) {
        if self.account != account { reset(account: account) }
        for job in jobs where !account.isEmpty && job.account == account && job.state == .completed {
            if versions.insert(Version(assetID: job.assetID, revision: job.assetRevision)).inserted { revision += 1 }
        }
    }
    func contains(assetID: String, revision: String, account: String) -> Bool {
        !account.isEmpty && account == self.account && versions.contains(Version(assetID: assetID, revision: revision))
    }
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
    var reused: Bool?
    var transportID: Int?
    var responsePath: String?
    var submitted = false
}
struct BackupJob: Codable, Identifiable {
    var repairStaging: Bool?
    var pipelineStage: PipelineStage?
    var pipelineSeconds: [String: Double]?
    var transferStartedAt: Date?
    var recovery: BackupRecoveryBudget?
    var lastAttemptError: String?
    var transferWatch: BackupTransferWatch?
    var id = UUID().uuidString
    var generation: Int64?
    var origin: BackupOrigin?
    var batchID: String?
    var activityHidden: Bool?
    var proxyFallback: ProxyFallback?
    var proxyPolicy: ProxyPolicy?
    var proxyScope: String?
    var proxyPort: Int?
    var proxyLastNode: String?
    var proxyFailures: [String]?
    var archivedAt: Date?
    var unarchivedAt: Date?
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
    var mediaKind: String?
    var forceUpload = false
    var priorResourceKeys: [String: String]?
    var allowMissingPriorUpload: Bool?
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
    var verificationLevel: String?
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
    var skippedExisting: Bool { state == .completed && standardConfirmationPassed && resources.allSatisfy { $0.reused == true } }
    var reusedSome: Bool { resources.contains { $0.reused == true } }
    func shouldAutoArchive(days: Int, now: Date = Date()) -> Bool {
        guard state == .completed, activityHidden != true, archivedAt == nil, let completedAt,
              (1...90).contains(days) else { return false }
        return max(completedAt, unarchivedAt ?? completedAt) <= now.addingTimeInterval(-Double(days) * 86400)
    }
    var standardConfirmationPassed: Bool {
        !resources.isEmpty && resources.allSatisfy { $0.confirmed && !$0.remoteKey.isEmpty } &&
        (!isLive || settings.live == .motion || hasConfirmedPairs)
    }
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
        return ["preparation": L10n.text("准备暂存目录"), "source_stability": L10n.text("等待相册资源稳定"), "export": L10n.text("从相册导出资源"), "motion_package": L10n.text("封装动态照片"),
                "source_read": L10n.text("读取暂存原件"), "prepare_upload": L10n.text("查重与申请上传"), "transfer_creation": L10n.text("创建后台传输"),
                "upload_response": L10n.text("保存上传响应"), "commit_response": L10n.text("读取响应并提交云端"), "confirmation": L10n.text("确认云端内容"),
                "pair_export": L10n.text("准备原始配对资源"), "pair_lookup": L10n.text("检查照片与视频关联"), "pair_photo_commit": L10n.text("提交配对用原图"),
                "pair_transfer": L10n.text("传输原始配对资源"), "pair_commit": L10n.text("关联照片与视频"), "pair_confirmation": L10n.text("确认同一云端动态项目")][failureStage] ?? L10n.text("其他处理步骤")
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
    /// A saved pair checkpoint is reusable only for these exact two resources.
    func isConfirmed(in resources: [MediaResource]) -> Bool {
        guard confirmed, !remoteKey.isEmpty, photoID != videoID,
              let photo = resources.first(where: { $0.id == photoID }),
              let video = resources.first(where: { $0.id == videoID }) else { return false }
        return photo.confirmed && video.confirmed && photo.remoteKey == remoteKey && video.remoteKey == remoteKey
    }
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
