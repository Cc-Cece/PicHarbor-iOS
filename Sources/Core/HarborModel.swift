import SwiftUI
import Photos
import Combine

@MainActor
final class HarborModel: ObservableObject {
    let engine = Engine()
    let library = PhotoLibrary()
    let network = NetworkStatus()
    @Published private(set) var jobs: [BackupJob] = []
    @Published var settings = BackupSettings()
    @Published private(set) var accounts: [String] = []
    @Published var notice = ""
    @Published var cleanupRunning = false
    @Published var cleanupReady: [String] = []
    @Published var cleanupResults: [String: String] = [:]
    @Published var applePairAvailable = false
    @Published var initialized = false
    @Published var storageFailed = false
    private var store: BackupStore?
    private var mappings: [AlbumMapping] = []
    private var workers = Set<String>()
    private var subscriptions = Set<AnyCancellable>()
    private var timer: Task<Void, Never>?
    private var starting = false
    private var switching = false
    private let transfer = BackgroundTransfer.shared
    var account: String { engine.account }
    var visibleJobs: [BackupJob] { jobs.filter { $0.account == account }.sorted { $0.created > $1.created } }
    var activeCount: Int { visibleJobs.filter { $0.state.active || $0.state == .queued }.count }
    var completedCount: Int { visibleJobs.filter { $0.state == .completed }.count }
    var stagedBytes: Int64 { jobs.filter { $0.state != .completed && $0.state != .cancelled }.flatMap(\.resources).reduce(0) { $0 + $1.size } }
    init() {
        engine.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        library.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        library.$revision.dropFirst().sink { [weak self] _ in Task { @MainActor in await self?.automaticScan() } }.store(in: &subscriptions)
        network.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        network.$connected.combineLatest(network.$wifi).dropFirst().sink { [weak self] _, _ in Task { @MainActor in await self?.pump() } }.store(in: &subscriptions)
        transfer.onReceipt = { [weak self] receipt in Task { @MainActor in await self?.receive(receipt) } }
        transfer.onProgress = { [weak self] id, sent, total in
            Task { @MainActor in
                guard let self, let index = self.jobs.firstIndex(where: { $0.id == id }), total > 0 else { return }
                self.jobs[index].progress = min(1, Double(sent) / Double(total))
            }
        }
        HarborAppDelegate.wake = { [weak self] in
            guard let self else { return }
            await self.boot(); await self.library.refresh(); await self.automaticScan(); await self.pump()
            while !self.workers.isEmpty && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
        }
    }
    func boot() async {
        guard !initialized && !starting else { return }
        starting = true
        defer { starting = false }
        await engine.boot()
        guard engine.ready else { notice = engine.message; return }
        do {
            let repository = try BackupStore(url: engine.home.appendingPathComponent("backup-v2.sqlite"))
            store = repository
            jobs = try await repository.load(BackupJob.self, kind: "job")
            mappings = try await repository.load(AlbumMapping.self, kind: "album")
            accounts = try KeychainStore.accounts()
            try await loadSettings()
            let capabilities = try await engine.invoke("capabilities")
            applePairAvailable = capabilities["apple_pair"] as? Bool == true
            transfer.activate()
            let existing = await transfer.tasks()
            let receipts = try transfer.pendingReceipts()
            for var job in jobs where job.state.active {
                let systemTask = existing.contains { $0.taskDescription?.hasPrefix(job.id + ":") == true }
                let hasReceipt = receipts.contains { $0.jobID == job.id }
                if !systemTask && !hasReceipt { job.state = .queued; try await persist(job) }
            }
            initialized = true
            for receipt in receipts { await receive(receipt) }
            await library.refresh()
            await pump()
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(10))
                    await self?.pump()
                }
            }
        } catch { fatalStorage(error) }
    }
    private func fatalStorage(_ error: Error) {
        storageFailed = true; notice = "任务存储不可用，已停止新任务：\(error.localizedDescription)"
    }
    private func persist(_ value: BackupJob) async throws {
        guard let store else { throw HarborError("DATABASE_ERROR") }
        var value = value; value.updated = Date()
        do { try await store.save(value, kind: "job", id: value.id) }
        catch { fatalStorage(error); throw error }
        if let index = jobs.firstIndex(where: { $0.id == value.id }) { jobs[index] = value } else { jobs.append(value) }
    }
    private func loadSettings() async throws {
        guard let store else { return }
        let saved = try await store.load(AccountSettings.self, kind: "settings")
        settings = saved.first(where: { $0.account == account })?.settings ?? BackupSettings()
    }
    struct AccountSettings: Codable { var account: String; var settings: BackupSettings }
    func saveSettings() async {
        guard !account.isEmpty, let store else { return }
        do {
            try await store.save(AccountSettings(account: account, settings: settings), kind: "settings", id: account)
            cleanupReady = []
            await automaticScan(); await pump()
        } catch { fatalStorage(error) }
    }
    func connect(_ credential: String) async {
        guard !switching && !cleanupRunning else { return }
        switching = true
        await pauseAll()
        // Waiting for active protocol calls prevents changing identity mid-commit.
        while !workers.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        await engine.login(credential)
        do { accounts = try KeychainStore.accounts(); try await loadSettings() } catch { notice = error.localizedDescription }
        cleanupReady = []; switching = false
        await replayReceipts(); await automaticScan(); await pump()
    }
    func switchAccount(_ value: String) async {
        do {
            guard let credential = try KeychainStore.load(account: value) else { throw HarborError("LOGIN_REQUIRED") }
            await connect(credential)
        } catch { notice = error.localizedDescription }
    }
    func logout() async {
        guard !switching && !cleanupRunning else { return }
        switching = true
        await pauseAll()
        while !workers.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        await engine.logout()
        accounts = (try? KeychainStore.accounts()) ?? []; settings = BackupSettings(); cleanupReady = []; switching = false
    }
    func enqueue(_ assets: [PHAsset], force: Bool = false) async {
        guard initialized, !account.isEmpty, !storageFailed, !switching else { notice = "请先连接 Google 账号。"; return }
        let snapshot = settings
        let membership = snapshot.syncAlbums ? library.memberships(for: Set(assets.map(\.localIdentifier))) : [:]
        do {
            var known = Set(jobs.filter { $0.state != .cancelled }.map(\.dedupKey))
            for asset in assets {
                var job = BackupJob(account: account, assetID: asset.localIdentifier, assetRevision: PhotoLibrary.stamp(asset), settings: snapshot)
                job.isLive = asset.mediaSubtypes.contains(.photoLive)
                job.albumIDs = membership[asset.localIdentifier] ?? []
                job.forceUpload = force
                if !force && known.contains(job.dedupKey) { continue }
                if jobs.contains(where: { $0.dedupKey == job.dedupKey && ($0.state.active || $0.state == .queued || $0.state == .paused) }) { continue }
                known.insert(job.dedupKey)
                try await persist(job)
            }
            notice = "已加入备份队列。"
            await pump()
        } catch { notice = error.localizedDescription }
    }
    func automaticScan() async {
        guard initialized, settings.automatic, !account.isEmpty, !switching, !cleanupRunning else { return }
        await enqueue(library.scope(settings))
    }
    private func runnable(_ job: BackupJob) -> Bool {
        job.account == account && [.queued, .waiting, .confirming].contains(job.state) &&
        (job.retryAt == nil || job.retryAt! <= Date()) && !workers.contains(job.id)
    }
    func pump() async {
        guard initialized, !account.isEmpty, engine.ready, !storageFailed, !switching, !cleanupRunning else { return }
        let occupying = Set(jobs.filter { $0.account == account && $0.state == .transferring }.map(\.id)).union(workers)
        let candidates = jobs.filter(runnable).sorted { $0.created < $1.created }
        var slots = max(0, 2 - occupying.count)
        for var job in candidates where slots > 0 {
            guard network.connected && (!job.settings.wifiOnly || network.wifi) else {
                if job.state != .waiting { job.state = .waiting; job.error = "WAITING_NETWORK"; try? await persist(job) }
                continue
            }
            workers.insert(job.id); slots -= 1
            Task { [weak self] in
                guard let self else { return }
                await self.process(job)
                self.workers.remove(job.id)
                await self.pump()
            }
        }
    }
    private func checkpoint(_ job: BackupJob) throws {
        guard !switching, job.account == account else { throw HarborError("ACCOUNT_CHANGED") }
        guard let current = jobs.first(where: { $0.id == job.id }), current.state != .paused, current.state != .cancelled else { throw HarborError("JOB_PAUSED") }
    }
    private func payload(_ resource: MediaResource, account: String) -> [String: Any] {
        ["account": account, "sha1": resource.sha1, "sha256": resource.sha256, "size": resource.size]
    }
    private func process(_ initial: BackupJob) async {
        var job = initial
        do {
            try checkpoint(job)
            let directory = engine.home.appendingPathComponent("Staging/\(job.id)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if job.resources.isEmpty {
                job.state = .preparing; job.error = ""; try await persist(job)
                if job.isLive && job.settings.live == .applePair && !applePairAvailable { throw HarborError("PAIR_PROTOCOL_UNVERIFIED") }
                guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [job.assetID], options: nil).firstObject,
                      PhotoLibrary.stamp(asset) == job.assetRevision else { throw HarborError("SOURCE_CHANGED") }
                job.sources = try await ResourceExporter.export(assetID: job.assetID, settings: job.settings, directory: directory)
                try checkpoint(job)
                if job.isLive {
                    guard job.settings.live == .motion else { throw HarborError("PAIR_PROTOCOL_UNVERIFIED") }
                    job.resources = try await MotionPhoto.package(job.sources, directory: directory)
                } else { job.resources = job.sources }
                try checkpoint(job)
                try await persist(job)
            }
            for index in job.resources.indices where !job.resources[index].confirmed {
                try checkpoint(job)
                let resource = job.resources[index]
                var request = payload(resource, account: job.account)
                // After an uncertain commit, query first; never label a submitted key confirmed.
                if resource.submitted {
                    job.state = .confirming; try await persist(job)
                    let result = try await engine.invoke("confirm_resource", request)
                    try checkpoint(job)
                    guard result["confirmed"] as? Bool == true else { throw HarborError("REMOTE_NOT_VISIBLE") }
                    job.resources[index].confirmed = true
                    job.resources[index].remoteKey = result["remote_key"] as? String ?? ""
                    try await persist(job); continue
                }
                let digest = try await Task.detached { try ResourceExporter.hash(URL(fileURLWithPath: resource.path)) }.value
                guard digest.1 == resource.sha256, digest.2 == resource.size else { throw HarborError("SOURCE_CHANGED") }
                try checkpoint(job)
                if let response = resource.responsePath {
                    job.state = .committing; job.resources[index].submitted = true
                    try await persist(job)
                    request["response_path"] = response; request["name"] = resource.name; request["quality"] = job.settings.quality.rawValue
                    let result = try await engine.invoke("commit_resource", request)
                    try checkpoint(job)
                    job.resources[index].remoteKey = result["remote_key"] as? String ?? ""
                    let confirmation = try await engine.invoke("confirm_resource", request)
                    try checkpoint(job)
                    guard confirmation["confirmed"] as? Bool == true else { throw HarborError("REMOTE_NOT_VISIBLE") }
                    job.resources[index].confirmed = true; try await persist(job)
                } else {
                    request["force"] = job.forceUpload
                    let plan = try await engine.invoke("prepare_upload", request)
                    try checkpoint(job)
                    if plan["exists"] as? Bool == true {
                        job.resources[index].remoteKey = plan["remote_key"] as? String ?? ""
                        job.resources[index].confirmed = true; try await persist(job)
                    } else {
                        let task = try transfer.create(job: job, resource: resource, plan: plan)
                        job.state = .transferring; job.resources[index].transportID = task.taskIdentifier
                        do { try await persist(job) } catch { task.cancel(); throw error }
                        task.resume()
                        return
                    }
                }
            }
            try checkpoint(job)
            if job.settings.syncAlbums && !job.albumIDs.isEmpty {
                job.albumsPending = true; try await persist(job)
                try await synchronizeAlbums(job)
                try checkpoint(job); job.albumsPending = false
            }
            job.state = .completed; job.progress = 1; job.error = ""; job.retryAt = nil
            try await persist(job)
            try? FileManager.default.removeItem(at: directory)
        } catch {
            guard let current = jobs.first(where: { $0.id == job.id }), current.state != .paused, current.state != .cancelled else { return }
            let code = (error as? HarborError)?.code ?? ((error as NSError).domain == NSCocoaErrorDomain ? "FILE_ACCESS" : "ENGINE_ERROR")
            if code == "ACCOUNT_CHANGED" || code == "JOB_PAUSED" { return }
            job.error = code; job.attempts += 1
            if ["NETWORK_ERROR", "UPLOAD_EXPIRED", "REMOTE_NOT_VISIBLE"].contains(code) && job.attempts <= 3 {
                job.state = code == "REMOTE_NOT_VISIBLE" ? .confirming : .waiting
                job.retryAt = Date(timeIntervalSinceNow: pow(2, Double(job.attempts)) * 5)
            } else { job.state = ["PAIR_PROTOCOL_UNVERIFIED", "SOURCE_CHANGED", "PHOTO_PERMISSION", "LOGIN_REQUIRED"].contains(code) ? .attention : .failed }
            try? await persist(job)
        }
    }
    private func synchronizeAlbums(_ job: BackupJob) async throws {
        guard let store else { throw HarborError("DATABASE_ERROR") }
        let keys = job.resources.map(\.remoteKey)
        for local in job.albumIDs {
            try checkpoint(job)
            if let map = mappings.first(where: { $0.account == job.account && $0.localID == local }) {
                _ = try await engine.invoke("add_to_album", ["account": job.account, "remote_key": map.remoteID, "keys": keys])
            } else {
                guard let album = library.albums.first(where: { $0.id == local }) else { throw HarborError("ALBUM_UNAVAILABLE") }
                let response = try await engine.invoke("create_album", ["account": job.account, "title": album.title, "keys": keys])
                guard let key = response["remote_key"] as? String else { throw HarborError("INVALID_RESPONSE") }
                let map = AlbumMapping(account: job.account, localID: local, remoteID: key)
                try await store.save(map, kind: "album", id: job.account + ":" + local); mappings.append(map)
            }
        }
    }
    private func replayReceipts() async {
        do { for receipt in try transfer.pendingReceipts() { await receive(receipt) } }
        catch { notice = error.localizedDescription }
    }
    private func receive(_ receipt: TransferReceipt) async {
        guard initialized, !switching, var job = jobs.first(where: { $0.id == receipt.jobID }), job.account == account,
              let index = job.resources.firstIndex(where: { $0.id == receipt.resourceID }), job.resources[index].transportID == receipt.id else { return }
        do {
            let paused = job.state == .paused
            if job.state == .cancelled { transfer.acknowledge(receipt); return }
            job.resources[index].transportID = nil
            if receipt.error.isEmpty {
                job.resources[index].responsePath = receipt.responsePath
                job.state = paused ? .paused : .queued; job.error = ""
            } else {
                job.state = paused ? .paused : .waiting; job.error = receipt.error
                job.attempts += 1; job.retryAt = Date(timeIntervalSinceNow: min(300, pow(2, Double(job.attempts)) * 5))
                if job.attempts > 3 && !paused { job.state = .failed }
            }
            try await persist(job); transfer.acknowledge(receipt); await pump()
        } catch { notice = error.localizedDescription }
    }
    func pause(_ id: String) async {
        guard var job = jobs.first(where: { $0.id == id }), job.account == account, job.state != .completed else { return }
        job.state = .paused; try? await persist(job); await transfer.pause(jobID: id)
    }
    func pauseAll() async { for job in visibleJobs where job.state.active || job.state == .queued || job.state == .waiting { await pause(job.id) } }
    func resume(_ id: String) async {
        guard var job = jobs.first(where: { $0.id == id }), job.account == account, job.state != .completed, job.state != .cancelled else { return }
        job.error = ""; job.retryAt = nil; job.attempts = 0
        if job.resources.contains(where: { $0.transportID != nil }) {
            job.state = .transferring; try? await persist(job); await transfer.resume(jobID: id)
        } else {
            job.state = .queued; try? await persist(job)
        }
        await pump()
    }
    func cancel(_ id: String) async {
        guard var job = jobs.first(where: { $0.id == id }), job.account == account, job.state != .completed else { return }
        job.state = .cancelled; job.evidence = nil; try? await persist(job); await transfer.cancel(jobID: id)
    }
    func verifyCleanup() async {
        guard !cleanupRunning, workers.isEmpty, !visibleJobs.contains(where: { $0.state.active }), !account.isEmpty else { notice = "请先暂停或完成正在运行的备份。"; return }
        cleanupRunning = true; cleanupReady = []; cleanupResults = [:]
        defer { cleanupRunning = false }
        do {
            if settings.cloudState { _ = try await engine.invoke("sync_cloud", ["account": account]) }
            for var job in visibleJobs where job.state == .completed {
                do {
                    let evidence = try await checkCleanup(job)
                    job.evidence = evidence; try await persist(job)
                    cleanupReady.append(job.id); cleanupResults[job.id] = "核验通过"
                } catch { cleanupResults[job.id] = error.localizedDescription }
            }
        } catch { notice = error.localizedDescription }
    }
    private func checkCleanup(_ job: BackupJob) async throws -> CleanupEvidence {
        guard job.account == account, job.state == .completed, !job.isLive else { throw HarborError(job.isLive ? "LIVE_CLEANUP_UNVERIFIED" : "CLEANUP_UNVERIFIED") }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [job.assetID], options: nil).firstObject,
              PhotoLibrary.stamp(asset) == job.assetRevision else { throw HarborError("SOURCE_CHANGED") }
        let directory = engine.home.appendingPathComponent("Staging/check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var full = job.settings; full.edits = .both
        let current = try await ResourceExporter.export(assetID: job.assetID, settings: full, directory: directory)
        guard Set(current.map(\.sha256)).isSubset(of: Set(job.sources.map(\.sha256))), !current.isEmpty else { throw HarborError("CLEANUP_UNVERIFIED") }
        for source in current {
            var request = payload(source, account: job.account)
            request["cloud_state"] = settings.cloudState; request["original_access"] = settings.originalAccess
            let result = try await engine.invoke("check_cleanup", request)
            guard result["eligible"] as? Bool == true else { throw HarborError("CLEANUP_UNVERIFIED") }
        }
        return CleanupEvidence(account: job.account, revision: job.assetRevision, policy: settings.cleanupPolicy,
            manifest: job.sources.map { "\($0.role):\($0.sha256)" }.sorted())
    }
    func deleteVerified() async {
        guard !cleanupRunning, !cleanupReady.isEmpty else { return }
        cleanupRunning = true
        defer { cleanupRunning = false; cleanupReady = [] }
        do {
            var identifiers = Set<String>()
            for id in cleanupReady {
                guard var job = jobs.first(where: { $0.id == id }), let evidence = job.evidence,
                      evidence.valid(job: job, settings: settings) else { throw HarborError("CLEANUP_UNVERIFIED") }
                // Re-export/hash and re-query immediately before the system deletion request.
                job.evidence = try await checkCleanup(job); try await persist(job); identifiers.insert(job.assetID)
            }
            let values = PHAsset.fetchAssets(withLocalIdentifiers: Array(identifiers), options: nil)
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(values) }
            let remaining = PHAsset.fetchAssets(withLocalIdentifiers: Array(identifiers), options: nil)
            var present = Set<String>(); remaining.enumerateObjects { asset, _, _ in present.insert(asset.localIdentifier) }
            for id in cleanupReady {
                cleanupResults[id] = jobs.first(where: { $0.id == id }).map { present.contains($0.assetID) ? "仍保留在相册" : "系统已完成删除请求" } ?? "请检查系统相册"
            }
            notice = "清理请求已完成，请查看结果。"; await library.refresh()
        } catch { notice = error.localizedDescription }
    }
    var diagnostics: String {
        let data: [String: Any] = ["version": 2, "job_count": jobs.count,
            "states": Dictionary(grouping: jobs, by: { $0.state.rawValue }).mapValues(\.count),
            "error_codes": jobs.map(\.error).filter { !$0.isEmpty }, "runtime": engine.runtime,
            "apple_pair": applePairAvailable, "live_cleanup": false, "staged_bytes": stagedBytes,
            "storage_failed": storageFailed, "os": ProcessInfo.processInfo.operatingSystemVersionString]
        return String(decoding: (try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])) ?? Data(), as: UTF8.self)
    }
}
