import SwiftUI
import Photos
import Combine

@MainActor
final class HarborModel: ObservableObject {
    static let shared = HarborModel()
    let engine = Engine()
    let library = PhotoLibrary()
    let network = NetworkStatus()
    @Published private(set) var jobs: [BackupJob] = []
    @Published private(set) var assetStates: [String: AssetBackupState] = [:]
    @Published var settings = BackupSettings()
    @Published private(set) var accounts: [String] = []
    @Published var notice = ""
    @Published var cleanupRunning = false
    @Published var cleanupReady: [String] = []
    @Published var cleanupResults: [String: String] = [:]
    @Published var applePairAvailable = false
    @Published var initialized = false
    @Published var storageFailed = false
    @Published private(set) var credentialStorageAvailable = true
    private var store: BackupStore?
    private var mappings: [AlbumMapping] = []
    private var assetIndex: [String: AssetSnapshot] = [:]
    private var settingsGeneration: [String: Int64] = [:]
    private let albumGate = PreparationGate()
    private var workers = Set<String>()
    private var collectedStaging = Set<String>()
    private var exports: [String: ExportControl] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private var timer: Task<Void, Never>?
    private var starting = false
    @Published private(set) var switching = false
    @Published private(set) var updatingNetwork = false
    @Published private(set) var connectionError = ""
    private let transfer = BackgroundTransfer.shared
    var account: String { engine.account }
    var visibleJobs: [BackupJob] { jobs.filter { $0.account == account && $0.activityHidden != true }.sorted { $0.created > $1.created } }
    var activeCount: Int { visibleJobs.filter { $0.state.active || $0.state == .queued }.count }
    var completedCount: Int { visibleJobs.filter { $0.state == .completed }.count }
    var stagedBytes: Int64 { jobs.filter { $0.state != .completed && $0.state != .cancelled }.flatMap(\.resources).reduce(0) { $0 + $1.size } }
    init() {
        engine.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        library.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        library.$revision.dropFirst().sink { [weak self] _ in Task { @MainActor in await self?.automaticScan() } }.store(in: &subscriptions)
        network.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        network.$connected.combineLatest(network.$wifi).dropFirst().sink { [weak self] connected, wifi in
            Task { @MainActor in
                guard let self else { return }
                for control in self.exports.values where !connected || (self.settings.wifiOnly && !wifi) { control.cancel("WAITING_NETWORK") }
                await self.pump()
            }
        }.store(in: &subscriptions)
        transfer.onReceipt = { [weak self] receipt in Task { @MainActor in await self?.receive(receipt) } }
        transfer.onProgress = { [weak self] id, sent, total in
            Task { @MainActor in
                guard let self, let index = self.jobs.firstIndex(where: { $0.id == id }), total > 0 else { return }
                self.jobs[index].progress = min(1, Double(sent) / Double(total))
            }
        }
    }
    func backgroundWake() async {
        await boot(); await library.refresh(); await automaticScan(); await pump()
        while !workers.isEmpty && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
    }
    func boot() async {
        guard !initialized && !starting else { return }
        starting = true
        storageFailed = false
        defer { starting = false }
        await engine.boot()
        guard engine.ready else { notice = engine.message; return }
        do {
            let repository = try BackupStore(url: engine.home.appendingPathComponent("backup-v2.sqlite"))
            store = repository
            jobs = try await repository.load(BackupJob.self, kind: "job")
            updateAssetStates(jobs)
            mappings = try await repository.load(AlbumMapping.self, kind: "album")
            assetIndex = Dictionary(uniqueKeysWithValues: try await repository.load(AssetSnapshot.self, kind: "asset").map { ($0.id, $0) })
            do { accounts = try KeychainStore.accounts(); credentialStorageAvailable = true }
            catch { accounts = []; credentialStorageAvailable = false; engine.message = error.localizedDescription }
            try await loadSettings()
            let capabilities = try await engine.invoke("capabilities")
            applePairAvailable = capabilities["apple_pair"] as? Bool == true
            transfer.activate()
            let existing = await transfer.tasks()
            let receipts = try transfer.pendingReceipts()
            for task in existing {
                guard let id = task.taskDescription?.components(separatedBy: ":").first,
                      let job = jobs.first(where: { $0.id == id }) else { task.cancel(); continue }
                switch job.transferDisposition(activeAccount: account) {
                case .cancel: task.cancel()
                case .pause: task.suspend()
                case .run:
                    if job.settings.wifiOnly != settings.wifiOnly { task.suspend() }
                    else if task.state == .suspended { task.resume() }
                }
            }
            for var job in jobs where job.state.active {
                let systemTask = existing.contains { $0.taskDescription?.hasPrefix(job.id + ":") == true }
                let hasReceipt = receipts.contains { $0.jobID == job.id }
                if !systemTask && !hasReceipt { job.state = .queued; job.retryAt = Date(timeIntervalSinceNow: 10); try await persist(job) }
            }
            for var job in jobs where job.state == .paused {
                for index in job.resources.indices {
                    if let id = job.resources[index].transportID, !existing.contains(where: { $0.taskIdentifier == id }), !receipts.contains(where: { $0.id == id }) {
                        job.resources[index].transportID = nil
                    }
                }
                try await persist(job)
            }
            initialized = true
            for receipt in receipts { await receive(receipt) }
            await applyNetworkSettings()
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
        if jobs.first(where: { $0.id == value.id })?.activityHidden == true && value.activityHidden != true { return }
        var value = value; value.updated = Date()
        value.generation = (jobs.first(where: { $0.id == value.id })?.generation ?? 0) + 1
        // Publish intent before yielding: pause/cancel must see the latest transport ID.
        if let index = jobs.firstIndex(where: { $0.id == value.id }) { jobs[index] = value } else { jobs.append(value) }
        updateAssetStates([value])
        do { try await store.save(value, kind: "job", id: value.id, revision: value.generation ?? 0) }
        catch { fatalStorage(error); throw error }
    }
    private func loadSettings() async throws {
        guard let store else { return }
        let saved = try await store.load(AccountSettings.self, kind: "settings")
        settingsGeneration = Dictionary(uniqueKeysWithValues: saved.map { ($0.account, $0.generation ?? 0) })
        settings = saved.first(where: { $0.account == account })?.settings ?? BackupSettings()
        assetStates = [:]; updateAssetStates(jobs)
    }
    private func updateAssetStates(_ values: [BackupJob]) {
        var updated = assetStates
        for job in values where job.account == account && job.activityHidden != true {
            if updated[job.assetID] == nil || job.created >= updated[job.assetID]!.created {
                updated[job.assetID] = AssetBackupState(account: job.account, revision: job.assetRevision, state: job.state, created: job.created)
            }
        }
        assetStates = updated
    }
    struct AccountSettings: Codable { var account: String; var settings: BackupSettings; var generation: Int64? }
    @discardableResult
    func saveSettings() async -> Bool {
        guard let store else { notice = "设置尚未就绪，请等待初始化完成后重试。"; return false }
        let targetAccount = account
        let snapshot = settings
        do {
            let generation = (settingsGeneration[targetAccount] ?? 0) + 1
            settingsGeneration[targetAccount] = generation
            try await store.save(AccountSettings(account: targetAccount, settings: snapshot, generation: generation), kind: "settings", id: targetAccount, revision: generation)
            cleanupReady = []
            await applyNetworkSettings()
            await automaticScan(); await pump()
            return true
        } catch { fatalStorage(error); return false }
    }
    private func applyNetworkSettings() async {
        guard initialized, !updatingNetwork, !switching, !cleanupRunning,
              jobs.contains(where: { $0.account == account && $0.unfinished && $0.state != .cancelled && $0.settings.wifiOnly != settings.wifiOnly }) else { return }
        updatingNetwork = true
        for control in exports.values { control.cancel("WAITING_NETWORK") }
        let changedJobs = Set(jobs.filter { $0.account == account && $0.unfinished && $0.settings.wifiOnly != settings.wifiOnly }.map(\.id))
        for task in await transfer.tasks() where changedJobs.contains(task.taskDescription?.components(separatedBy: ":").first ?? "") { task.suspend() }
        // Checkpoints stop workers before another commit/transfer can start.
        while !workers.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
        let targetAccount = account
        do {
            while let id = jobs.first(where: { $0.account == targetAccount && $0.unfinished && $0.state != .cancelled && $0.settings.wifiOnly != settings.wifiOnly })?.id {
                guard var job = jobs.first(where: { $0.id == id }) else { continue }
                // URLRequest's cellular policy cannot be changed on a running task.
                // Retain source/commit evidence and restart only the file transport.
                let oldIDs = job.updateNetwork(wifiOnly: settings.wifiOnly)
                try await persist(job)
                for task in await transfer.tasks() where oldIDs.contains(task.taskIdentifier) { task.cancel() }
            }
        } catch { fatalStorage(error) }
        // A rapid toggle back can leave the original policy unchanged after
        // the suspension above. Resume only tasks still owned by runnable jobs.
        for task in await transfer.tasks() {
            guard let job = jobs.first(where: { $0.resources.contains { $0.transportID == task.taskIdentifier } }),
                  job.account == account, job.state == .transferring,
                  job.settings.wifiOnly == settings.wifiOnly,
                  task.originalRequest?.allowsCellularAccess == !settings.wifiOnly else { continue }
            if task.state == .suspended { task.resume() }
        }
        updatingNetwork = false
        await replayReceipts()
        await pump()
    }
    @discardableResult
    func connect(_ credential: String) async -> Bool {
        connectionError = ""
        guard !switching && !updatingNetwork && !engine.busy else { connectionError = HarborError("ACCOUNT_BUSY").localizedDescription; return false }
        guard !cleanupRunning else { connectionError = HarborError("CLEANUP_BUSY").localizedDescription; return false }
        guard initialized, !storageFailed else { connectionError = "应用尚未就绪，请等待初始化完成并检查诊断。"; return false }
        switching = true
        await pauseAll()
        // Waiting for active protocol calls prevents changing identity mid-commit.
        while !workers.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        let connected = await engine.login(credential)
        if !connected { connectionError = engine.message }
        if connected {
            do { accounts = try KeychainStore.accounts(); credentialStorageAvailable = true }
            catch { credentialStorageAvailable = false; connectionError = error.localizedDescription }
        }
        // Failed authentication must keep its own error instead of triggering an
        // unrelated account-enumeration alert, particularly in unsigned tests.
        do { try await loadSettings() }
        catch { connectionError = error.localizedDescription; fatalStorage(error) }
        cleanupReady = []; switching = false
        await applyNetworkSettings()
        await replayReceipts(); await automaticScan(); await pump()
        return connected && connectionError.isEmpty
    }
    func switchAccount(_ value: String) async {
        do {
            guard let credential = try KeychainStore.load(account: value) else { throw HarborError("LOGIN_REQUIRED") }
            if !(await connect(credential)) { notice = connectionError }
        } catch { notice = error.localizedDescription }
    }
    func logout() async {
        guard !switching && !updatingNetwork && !engine.busy else { notice = HarborError("ACCOUNT_BUSY").localizedDescription; return }
        guard !cleanupRunning else { notice = HarborError("CLEANUP_BUSY").localizedDescription; return }
        switching = true
        await pauseAll()
        while !workers.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        await engine.logout()
        if !account.isEmpty { notice = engine.message }
        do { accounts = try KeychainStore.accounts(); try await loadSettings() } catch { notice = error.localizedDescription }
        cleanupReady = []; switching = false
    }
    func enqueue(_ assets: [PHAsset], force: Bool = false, feedback: Bool = true, policy: BackupSettings? = nil, origin: BackupOrigin = .manual, batchID: String? = nil) async {
        guard initialized, !account.isEmpty, !storageFailed, !switching, let store else { notice = "请先连接 Google 账号。"; return }
        guard !assets.isEmpty else { if feedback { notice = "当前范围没有可备份的照片或视频，请检查范围和相册权限。" }; return }
        var snapshot = policy ?? settings
        snapshot.wifiOnly = settings.wifiOnly
        let batch = batchID ?? UUID().uuidString
        let targetAccount = account
        let membership = snapshot.syncAlbums ? library.memberships(for: Set(assets.map(\.localIdentifier))) : [:]
        do {
            var known = Set(jobs.filter { $0.state != .cancelled || (origin == .automatic && $0.activityHidden == true) }.map { $0.discoveryKey(origin: origin) })
            let active = Set(jobs.filter { $0.state.active || $0.state == .queued || $0.state == .paused }.map(\.dedupKey))
            var additions: [BackupJob] = []
            var planned = Set<String>()
            for asset in assets {
                var job = BackupJob(account: targetAccount, assetID: asset.localIdentifier, assetRevision: PhotoLibrary.stamp(asset), settings: snapshot)
                job.isLive = asset.mediaSubtypes.contains(.photoLive)
                job.albumIDs = membership[asset.localIdentifier] ?? []
                job.forceUpload = force
                job.assetCreated = asset.creationDate; job.assetModified = asset.modificationDate
                job.origin = origin; job.batchID = batch
                // PhotoKit may publish several revisions while a fresh capture
                // settles. Keep one pending preparation instead of queueing each.
                if jobs.contains(where: { $0.account == targetAccount && $0.assetID == job.assetID &&
                    $0.settings.mediaPolicy == job.settings.mediaPolicy && $0.canRefreshSource &&
                    [.queued, .preparing, .waiting, .paused].contains($0.state) }) { continue }
                if !force && known.contains(job.discoveryKey(origin: origin)) { continue }
                if active.contains(job.dedupKey) || planned.contains(job.dedupKey) { continue }
                known.insert(job.discoveryKey(origin: origin))
                planned.insert(job.dedupKey); job.generation = 1; additions.append(job)
            }
            if !additions.isEmpty {
                jobs.append(contentsOf: additions)
                updateAssetStates(additions)
                do { try await store.saveBatch(additions.map { ($0.id, $0) }, kind: "job") }
                catch { fatalStorage(error); throw error }
                if feedback { notice = "已加入备份队列。" }
            } else if feedback { notice = "这些项目已有备份任务或已经完成，请到活动中查看或重试。" }
            await pump()
        } catch { notice = error.localizedDescription }
    }
    func automaticScan() async {
        guard initialized, !storageFailed else { return }
        do { try await indexLibrary() } catch { fatalStorage(error); return }
        guard settings.automatic, settings.scopeConfirmed == true, !account.isEmpty, !switching, !cleanupRunning else { return }
        await enqueue(library.scope(settings), feedback: false, origin: .automatic)
    }
    private func indexLibrary() async throws {
        guard let store, !library.refreshing else { return }
        var changed: [(String, AssetSnapshot)] = []
        let accessible = Set(library.assets.map(\.localIdentifier))
        for asset in library.assets {
            let stamp = PhotoLibrary.stamp(asset)
            if assetIndex[asset.localIdentifier]?.revision != stamp || assetIndex[asset.localIdentifier]?.accessible != true {
                let value = AssetSnapshot(id: asset.localIdentifier, revision: stamp, mediaType: asset.mediaType.rawValue, accessible: true)
                changed.append((value.id, value))
            }
        }
        for var value in assetIndex.values where value.accessible && !accessible.contains(value.id) {
            // This means inaccessible, not proof that the user deleted the photo.
            value.accessible = false; changed.append((value.id, value))
        }
        if !changed.isEmpty {
            try await store.saveBatch(changed, kind: "asset")
            for (id, value) in changed { assetIndex[id] = value }
        }
    }
    private func runnable(_ job: BackupJob) -> Bool {
        job.account == account && [.queued, .waiting, .confirming].contains(job.state) &&
        (job.retryAt == nil || job.retryAt! <= Date()) && !workers.contains(job.id)
    }
    func pump() async {
        guard initialized, !account.isEmpty, engine.ready, !storageFailed, !switching, !updatingNetwork, !cleanupRunning else { return }
        if jobs.contains(where: { $0.account == account && $0.unfinished && $0.state != .cancelled && $0.settings.wifiOnly != settings.wifiOnly }) {
            await applyNetworkSettings(); return
        }
        await collectFinishedStaging()
        let candidates = jobs.filter(runnable).sorted { $0.created < $1.created }
        for var job in candidates {
            // persist() can yield to another pump; recheck occupancy and identity each iteration.
            guard !switching, !updatingNetwork, !cleanupRunning, !storageFailed, runnable(job) else { continue }
            let occupying = Set(jobs.filter { $0.account == account && $0.state == .transferring }.map(\.id)).union(workers)
            if occupying.count >= 2 { break }
            guard network.connected && (!job.settings.wifiOnly || network.wifi) else {
                if job.state != .waiting { job.state = .waiting; job.error = "WAITING_NETWORK"; try? await persist(job) }
                continue
            }
            workers.insert(job.id)
            Task { [weak self] in
                guard let self else { return }
                await self.process(job)
                self.workers.remove(job.id)
                await self.pump()
            }
        }
    }
    private func collectFinishedStaging() async {
        let tasks = await transfer.tasks()
        let referenced = Set(tasks.compactMap { $0.taskDescription?.components(separatedBy: ":").first })
        let receipts = (try? transfer.pendingReceipts()) ?? []
        for job in jobs where [.completed, .cancelled].contains(job.state) && !workers.contains(job.id) && !referenced.contains(job.id) && !collectedStaging.contains(job.id) {
            let directory = engine.home.appendingPathComponent("Staging/\(job.id)", isDirectory: true)
            try? FileManager.default.removeItem(at: directory)
            for resource in job.resources {
                if let path = resource.responsePath { try? FileManager.default.removeItem(atPath: path) }
                if let id = resource.transportID { try? FileManager.default.removeItem(at: engine.home.appendingPathComponent("Staging/response-\(id).bin")) }
            }
            for receipt in receipts where receipt.jobID == job.id {
                try? FileManager.default.removeItem(atPath: receipt.responsePath); transfer.acknowledge(receipt)
            }
            collectedStaging.insert(job.id)
        }
    }
    private func checkpoint(_ job: BackupJob) throws {
        guard !switching, job.account == account else { throw HarborError("ACCOUNT_CHANGED") }
        guard let current = jobs.first(where: { $0.id == job.id }), current.state != .paused, current.state != .cancelled else { throw HarborError("JOB_PAUSED") }
        guard !updatingNetwork, network.connected && (!settings.wifiOnly || network.wifi) else { throw HarborError("WAITING_NETWORK") }
    }
    private func payload(_ resource: MediaResource, account: String) -> [String: Any] {
        ["account": account, "sha1": resource.sha1, "sha256": resource.sha256, "size": resource.size]
    }
    private func process(_ initial: BackupJob) async {
        var job = initial
        var stage = "preparation"
        var committingResourceID: String?
        defer { exports.removeValue(forKey: job.id) }
        do {
            try checkpoint(job)
            let directory = engine.home.appendingPathComponent("Staging/\(job.id)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if job.resources.isEmpty {
                job.state = .preparing; job.error = ""; job.failureStage = nil; try await persist(job)
                await PreparationGate.shared.acquire()
                do {
                try checkpoint(job)
                stage = "source_stability"
                guard job.canRefreshSource else { throw HarborError("SOURCE_SNAPSHOT_LOCKED") }
                job.error = "SOURCE_SETTLING"; job.failureStage = stage; try await persist(job)
                let asset = try await stableSource(for: job)
                try checkpoint(job)
                try job.refreshSource(revision: PhotoLibrary.stamp(asset), live: asset.mediaSubtypes.contains(.photoLive),
                                      created: asset.creationDate, modified: asset.modificationDate)
                job.error = ""; job.failureStage = nil; try await persist(job)
                try checkpoint(job)
                if job.isLive && job.settings.live != .motion && !applePairAvailable { throw HarborError("PAIR_PROTOCOL_UNVERIFIED") }
                let exportSignature = PhotoLibrary.preparationStamp(asset)
                // Only an unreferenced preparation directory is discarded, never a transfer file.
                try? FileManager.default.removeItem(at: directory)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let free = (try FileManager.default.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
                guard free > 64 * 1024 * 1024 else { throw HarborError("DISK_FULL") }
                let control = ExportControl(wifiOnly: job.settings.wifiOnly); exports[job.id] = control
                stage = "export"
                job.sources = try await ResourceExporter.export(assetID: job.assetID, settings: job.settings, directory: directory, control: control)
                if let code = control.failure { throw HarborError(code) }
                try checkpoint(job)
                guard let latest = PHAsset.fetchAssets(withLocalIdentifiers: [job.assetID], options: nil).firstObject else { throw HarborError("PHOTO_PERMISSION") }
                guard PhotoLibrary.preparationStamp(latest) == exportSignature else {
                    // Nothing has been uploaded: discard only this preparation
                    // and retry from a fresh snapshot, never mix Live versions.
                    try? FileManager.default.removeItem(at: directory)
                    throw HarborError("SOURCE_SETTLING")
                }
                job.sourceWaits = 0
                if job.isLive {
                    if job.settings.live == .motion {
                        stage = "motion_package"
                        job.resources = try await MotionPhoto.package(job.sources, directory: directory)
                    } else {
                        stage = "pair_export"
                        job.resources = job.sources
                        job.livePairs = try LivePairRecord.make(job.resources)
                        job.assetCreated = asset.creationDate; job.assetModified = asset.modificationDate
                    }
                } else { job.resources = job.sources }
                try checkpoint(job)
                try await persist(job)
                } catch { await PreparationGate.shared.release(); throw error }
                await PreparationGate.shared.release()
            }
            if job.isLive && job.settings.live != .motion {
                stage = "pair_commit"
                guard let finished = try await processApplePairs(job, directory: directory) else { return }
                job = finished
            } else {
                for index in job.resources.indices where !job.resources[index].confirmed {
                    try checkpoint(job)
                    let resource = job.resources[index]
                    var request = payload(resource, account: job.account)
                    // After an uncertain commit, query first; never label a submitted key confirmed.
                    if resource.submitted {
                        stage = "confirmation"
                        job.state = .confirming; try await persist(job)
                        let result = try await engine.invoke("confirm_resource", request)
                        try checkpoint(job)
                        guard result["confirmed"] as? Bool == true else { throw HarborError("REMOTE_NOT_VISIBLE") }
                        job.resources[index].confirmed = true
                        job.resources[index].remoteKey = result["remote_key"] as? String ?? ""
                        try await persist(job); continue
                    }
                    stage = "source_read"
                    guard FileManager.default.fileExists(atPath: resource.path) else { throw HarborError("SOURCE_FILE_MISSING") }
                    let digest = try await Task.detached { try ResourceExporter.hash(URL(fileURLWithPath: resource.path)) }.value
                    guard digest.1 == resource.sha256, digest.2 == resource.size else { throw HarborError("SOURCE_CHANGED") }
                    try checkpoint(job)
                    if let response = resource.responsePath {
                        stage = "commit_response"
                        committingResourceID = resource.id
                        job.state = .committing; job.resources[index].submitted = true
                        try await persist(job)
                        request["response_path"] = response; request["name"] = resource.name; request["quality"] = job.settings.quality.rawValue
                        let result = try await engine.invoke("commit_resource", request)
                        try checkpoint(job)
                        job.resources[index].remoteKey = result["remote_key"] as? String ?? ""
                        stage = "confirmation"
                        let confirmation = try await engine.invoke("confirm_resource", request)
                        try checkpoint(job)
                        guard confirmation["confirmed"] as? Bool == true else { throw HarborError("REMOTE_NOT_VISIBLE") }
                        job.resources[index].remoteKey = confirmation["remote_key"] as? String ?? ""
                        job.resources[index].confirmed = true; try await persist(job)
                    } else {
                        stage = "prepare_upload"
                        request["force"] = job.forceUpload
                        let plan = try await engine.invoke("prepare_upload", request)
                        try checkpoint(job)
                        if plan["exists"] as? Bool == true {
                            job.resources[index].remoteKey = plan["remote_key"] as? String ?? ""
                            job.resources[index].confirmed = true; try await persist(job)
                        } else {
                            let free = (try FileManager.default.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
                            let reserved = jobs.flatMap(\.resources).filter { $0.transportID != nil }.reduce(Int64(0)) { $0 + $1.size }
                            // Background URLSession may make its own file copy.
                            guard free > resource.size + reserved + 64 * 1024 * 1024 else { throw HarborError("DISK_FULL") }
                            stage = "transfer_creation"
                            let task = try transfer.create(job: job, resource: resource, plan: plan)
                            job.state = .transferring; job.resources[index].transportID = task.taskIdentifier
                            do { try await persist(job) } catch { task.cancel(); throw error }
                            let current = jobs.first(where: { $0.id == job.id })?.state
                            if current == .cancelled { task.cancel() }
                            else if current != .paused { task.resume() }
                            return
                        }
                    }
                }
            }
            try checkpoint(job)
            if job.isLive {
                stage = "confirmation"
                job.state = .confirming; try await persist(job)
                // Older jobs may retain the commit RPC's key rather than the
                // hash lookup's canonical key. Refresh every version without
                // retransmitting, including resources already marked confirmed.
                if job.settings.live == .motion {
                    for index in job.resources.indices {
                        let result = try await engine.invoke("confirm_resource", payload(job.resources[index], account: job.account))
                        try checkpoint(job)
                        guard result["confirmed"] as? Bool == true,
                              let key = result["remote_key"] as? String, !key.isEmpty else { throw HarborError("REMOTE_NOT_VISIBLE") }
                        job.resources[index].remoteKey = key
                    }
                }
                try await persist(job)
                let dynamic = try await engine.invoke("motion_status", ["account": job.account, "keys": job.resources.map(\.remoteKey)])
                try checkpoint(job)
                guard dynamic["recognized"] as? Bool == true else { throw HarborError(dynamic["reason"] as? String ?? "REMOTE_MOTION_PENDING") }
            }
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
            if stage == "pair_commit" && job.isLive && job.settings.live != .motion && !current.resources.isEmpty { stage = current.failureStage ?? stage }
            job = current
            let code = (error as? HarborError)?.code ?? ((error as NSError).domain == NSCocoaErrorDomain ? "FILE_ACCESS" : "ENGINE_ERROR")
            if code == "ACCOUNT_CHANGED" || code == "JOB_PAUSED" { return }
            // These response errors are guaranteed to occur before gpmc's
            // commit RPC, so a retry must not get stuck querying an unsent commit.
            job.recordFailure(code, stage: stage, committingResourceID: committingResourceID)
            job.attempts += 1
            let system = error as NSError
            job.failureSystemCode = [NSCocoaErrorDomain, NSPOSIXErrorDomain, NSURLErrorDomain, "PHPhotosErrorDomain"].contains(system.domain) ? "\(system.domain):\(system.code)" : nil
            if code == "SOURCE_SETTLING" {
                job.waitForSource()
            }
            else if code == "WAITING_NETWORK" { job.state = .waiting; job.retryAt = nil; job.attempts = max(0, job.attempts - 1) }
            else if (code.hasPrefix("REMOTE_MOTION_") && code != "REMOTE_MOTION_TRASHED") || code == "PAIR_CONFIRMATION_PENDING" {
                job.state = .confirming
                job.retryAt = Date(timeIntervalSinceNow: min(300, pow(2, Double(min(job.attempts, 6))) * 5))
            }
            else if ["NETWORK_ERROR", "UPLOAD_EXPIRED", "REMOTE_NOT_VISIBLE"].contains(code) && job.attempts <= 3 {
                job.state = code == "REMOTE_NOT_VISIBLE" ? .confirming : .waiting
                job.retryAt = Date(timeIntervalSinceNow: pow(2, Double(job.attempts)) * 5)
            } else { job.state = ["PAIR_PROTOCOL_UNVERIFIED", "PAIR_COMMIT_REJECTED", "SOURCE_CHANGED", "SOURCE_SNAPSHOT_LOCKED", "PHOTO_PERMISSION", "LOGIN_REQUIRED"].contains(code) ? .attention : .failed }
            try? await persist(job)
        }
    }
    private func stableSource(for job: BackupJob) async throws -> PHAsset {
        try await SourceStabilityProbe.wait(read: {
            try checkpoint(job)
            guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [job.assetID], options: nil).firstObject else { throw HarborError("PHOTO_PERMISSION") }
            return (asset, PhotoLibrary.preparationStamp(asset))
        }, pause: { try await Task.sleep(for: .seconds(1)) })
    }
    /// Returns nil when a native file transfer has been scheduled. Both routes
    /// keep opaque response files and a durable commit fence across relaunches.
    private func processApplePairs(_ initial: BackupJob, directory: URL) async throws -> BackupJob? {
        var job = initial
        if job.livePairs == nil { job.livePairs = try LivePairRecord.make(job.resources); try await persist(job) }
        for pairIndex in (job.livePairs ?? []).indices {
            try checkpoint(job)
            guard let pair = job.livePairs?[pairIndex],
                  let photoIndex = job.resources.firstIndex(where: { $0.id == pair.photoID }),
                  let videoIndex = job.resources.firstIndex(where: { $0.id == pair.videoID }) else { throw HarborError("LIVE_PAIR_MISSING") }
            func pairPayload(_ job: BackupJob) -> [String: Any] {
                var photo = payload(job.resources[photoIndex], account: job.account)
                var video = payload(job.resources[videoIndex], account: job.account)
                photo["name"] = job.resources[photoIndex].name; photo["response_path"] = job.resources[photoIndex].responsePath
                video["name"] = job.resources[videoIndex].name; video["response_path"] = job.resources[videoIndex].responsePath
                return ["account": job.account, "photo": photo, "video": video,
                        "quality": job.settings.quality.rawValue, "route": job.livePairs?[pairIndex].route ?? "",
                        "created_at": Int64((job.assetCreated ?? job.created).timeIntervalSince1970),
                        "modified_at": Int64((job.assetModified ?? job.assetCreated ?? job.created).timeIntervalSince1970)]
            }
            job.failureStage = "pair_lookup"; job.state = .confirming; try await persist(job)
            let presence = try await engine.invoke("confirm_pair", pairPayload(job))
            try checkpoint(job)
            if presence["confirmed"] as? Bool == true, let key = presence["remote_key"] as? String, !key.isEmpty {
                job.livePairs?[pairIndex].confirmed = true; job.livePairs?[pairIndex].remoteKey = key
                for index in [photoIndex, videoIndex] { job.resources[index].confirmed = true; job.resources[index].remoteKey = key }
                try await persist(job); continue
            }
            // A timeout/termination after submission cannot authorize another
            // commit. Retry here means query-only until association is visible.
            if pair.queryOnly { throw HarborError("PAIR_CONFIRMATION_PENDING") }
            if job.livePairs?[pairIndex].route == nil {
                let photoExists = !(presence["photo_key"] as? String ?? "").isEmpty
                job.livePairs?[pairIndex].route = photoExists || job.settings.live == .appleReconcile ? "reconcile" : "joint"
                try await persist(job)
            }
            if job.livePairs?[pairIndex].route == "reconcile" {
                let existing = presence["photo_key"] as? String ?? ""
                if !existing.isEmpty {
                    job.resources[photoIndex].remoteKey = existing
                    try await persist(job)
                } else {
                    if job.resources[photoIndex].submitted { throw HarborError("REMOTE_NOT_VISIBLE") }
                    if job.resources[photoIndex].responsePath == nil {
                        try await launchPairTransfer(job, index: photoIndex, directory: directory); return nil
                    }
                    var request = payload(job.resources[photoIndex], account: job.account)
                    request["name"] = job.resources[photoIndex].name
                    request["response_path"] = job.resources[photoIndex].responsePath
                    request["quality"] = job.settings.quality.rawValue
                    try await verifyPairSource(job.resources[photoIndex])
                    try checkpoint(job)
                    job.failureStage = "pair_photo_commit"; job.state = .committing
                    job.resources[photoIndex].submitted = true; try await persist(job)
                    do { try checkpoint(job) }
                    catch {
                        if var latest = jobs.first(where: { $0.id == job.id }) { latest.resources[photoIndex].submitted = false; try await persist(latest) }
                        throw error
                    }
                    do { _ = try await engine.invoke("commit_pair_photo", request) }
                    catch {
                        if (error as? HarborError)?.code.hasPrefix("UPLOAD_RESPONSE_") == true,
                           var latest = jobs.first(where: { $0.id == job.id }) {
                            latest.resources[photoIndex].submitted = false; latest.resources[photoIndex].responsePath = nil
                            try await persist(latest)
                        }
                        throw error
                    }
                    try checkpoint(job)
                    let visible = try await engine.invoke("confirm_resource", payload(job.resources[photoIndex], account: job.account))
                    try checkpoint(job)
                    guard visible["confirmed"] as? Bool == true else { throw HarborError("REMOTE_NOT_VISIBLE") }
                    job.resources[photoIndex].remoteKey = visible["remote_key"] as? String ?? ""
                    try await persist(job)
                }
            }
            let required = job.livePairs?[pairIndex].route == "joint" ? [photoIndex, videoIndex] : [videoIndex]
            for index in required where job.resources[index].responsePath == nil {
                try await launchPairTransfer(job, index: index, directory: directory); return nil
            }
            for index in [photoIndex, videoIndex] { try await verifyPairSource(job.resources[index]); try checkpoint(job) }
            try checkpoint(job)
            job.failureStage = "pair_commit"; job.state = .committing
            job.livePairs?[pairIndex].submitted = true
            try await persist(job)
            do { try checkpoint(job) }
            catch {
                if var latest = jobs.first(where: { $0.id == job.id }) { latest.livePairs?[pairIndex].submitted = false; try await persist(latest) }
                throw error
            }
            do {
                let result = try await engine.invoke("pair_apple", pairPayload(job))
                try checkpoint(job)
                job.livePairs?[pairIndex].remoteKey = result["remote_key"] as? String ?? ""
                job.failureStage = "pair_confirmation"; job.state = .confirming; try await persist(job)
            } catch {
                let code = (error as? HarborError)?.code ?? "ENGINE_ERROR"
                if code.hasPrefix("UPLOAD_RESPONSE_") || code == "PAIR_COMMIT_REJECTED" || code.hasPrefix("INVALID_PAIR_") {
                    job.livePairs?[pairIndex].submitted = false
                    if code.hasPrefix("UPLOAD_RESPONSE_") {
                        for index in required { job.resources[index].responsePath = nil }
                    }
                    // Only a guaranteed pre-acceptance rejection clears the fence.
                    // Never overwrite a pause/cancel that arrived during the RPC.
                    if var latest = jobs.first(where: { $0.id == job.id }) {
                        latest.livePairs?[pairIndex].submitted = false
                        if code.hasPrefix("UPLOAD_RESPONSE_") { for index in required { latest.resources[index].responsePath = nil } }
                        try await persist(latest)
                    }
                }
                throw error
            }
            let linked = try await engine.invoke("confirm_pair", pairPayload(job))
            try checkpoint(job)
            guard linked["confirmed"] as? Bool == true, let key = linked["remote_key"] as? String, !key.isEmpty else { throw HarborError("PAIR_CONFIRMATION_PENDING") }
            job.livePairs?[pairIndex].confirmed = true; job.livePairs?[pairIndex].remoteKey = key
            for index in [photoIndex, videoIndex] { job.resources[index].confirmed = true; job.resources[index].remoteKey = key }
            try await persist(job)
        }
        return job
    }
    private func verifyPairSource(_ resource: MediaResource) async throws {
        guard FileManager.default.fileExists(atPath: resource.path) else { throw HarborError("SOURCE_FILE_MISSING") }
        let digest = try await Task.detached { try ResourceExporter.hash(URL(fileURLWithPath: resource.path)) }.value
        guard digest.0 == resource.sha1, digest.1 == resource.sha256, digest.2 == resource.size else { throw HarborError("SOURCE_CHANGED") }
    }
    private func launchPairTransfer(_ initial: BackupJob, index: Int, directory: URL) async throws {
        var job = initial
        try checkpoint(job)
        let resource = job.resources[index]
        try await verifyPairSource(resource)
        try checkpoint(job)
        job.failureStage = "pair_transfer"; try await persist(job)
        let plan = try await engine.invoke("prepare_pair_component", payload(resource, account: job.account))
        try checkpoint(job)
        let free = (try FileManager.default.attributesOfFileSystem(forPath: directory.path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        let reserved = jobs.flatMap(\.resources).filter { $0.transportID != nil }.reduce(Int64(0)) { $0 + $1.size }
        guard free > resource.size + reserved + 64 * 1024 * 1024 else { throw HarborError("DISK_FULL") }
        let task = try transfer.create(job: job, resource: resource, plan: plan)
        job.state = .transferring; job.resources[index].transportID = task.taskIdentifier
        do { try await persist(job) } catch { task.cancel(); throw error }
        let state = jobs.first(where: { $0.id == job.id })?.state
        if state == .cancelled { task.cancel() } else if state != .paused { task.resume() }
    }
    private func synchronizeAlbums(_ job: BackupJob) async throws {
        guard let store else { throw HarborError("DATABASE_ERROR") }
        await albumGate.acquire()
        do {
        let keys = Array(Set(job.resources.map(\.remoteKey))).sorted()
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
        } catch { await albumGate.release(); throw error }
        await albumGate.release()
    }
    private func replayReceipts() async {
        do { for receipt in try transfer.pendingReceipts() { await receive(receipt) } }
        catch { notice = error.localizedDescription }
    }
    private func receive(_ receipt: TransferReceipt) async {
        guard initialized, !switching, !updatingNetwork else { return }
        guard var job = jobs.first(where: { $0.id == receipt.jobID }) else { transfer.acknowledge(receipt); return }
        guard job.account == account else { return }
        guard let index = job.resources.firstIndex(where: { $0.id == receipt.resourceID }), job.resources[index].transportID == receipt.id else {
            try? FileManager.default.removeItem(atPath: receipt.responsePath)
            transfer.acknowledge(receipt); return
        }
        do {
            let paused = job.state == .paused
            if job.state == .cancelled {
                try? FileManager.default.removeItem(atPath: receipt.responsePath)
                transfer.acknowledge(receipt); return
            }
            job.resources[index].transportID = nil
            if receipt.error.isEmpty {
                job.resources[index].responsePath = receipt.responsePath
                job.state = paused ? .paused : .queued; job.error = ""; job.retryAt = nil
            } else {
                job.state = paused ? .paused : .waiting; job.error = receipt.error
                job.failureStage = "upload_response"
                job.resources[index].responsePath = nil
                job.attempts += 1; job.retryAt = Date(timeIntervalSinceNow: min(300, pow(2, Double(job.attempts)) * 5))
                if job.attempts > 3 && !paused { job.state = .failed }
            }
            try await persist(job); transfer.acknowledge(receipt); await pump()
        } catch { notice = error.localizedDescription }
    }
    func pause(_ id: String) async {
        guard var job = jobs.first(where: { $0.id == id }), job.account == account, job.state != .completed, job.state != .cancelled else { return }
        exports[id]?.cancel("JOB_PAUSED")
        job.state = .paused; try? await persist(job); await transfer.pause(jobID: id)
    }
    func pauseAll() async { for job in visibleJobs where job.state.active || job.state == .queued || job.state == .waiting { await pause(job.id) } }
    func resume(_ id: String) async {
        guard !updatingNetwork else { notice = "正在应用网络设置，请稍后继续任务。"; return }
        if workers.contains(id) {
            if jobs.first(where: { $0.id == id })?.state != .paused { notice = "此任务正在处理，请等待本次检查结束。"; return }
            while workers.contains(id) { try? await Task.sleep(for: .milliseconds(50)) }
        }
        guard !updatingNetwork, !switching else { return }
        guard var job = jobs.first(where: { $0.id == id }), job.account == account, job.state != .completed, job.state != .cancelled else { return }
        job.error = ""; job.retryAt = nil; job.attempts = 0; job.sourceWaits = 0
        let liveTasks = await transfer.tasks()
        for index in job.resources.indices {
            if let transportID = job.resources[index].transportID, !liveTasks.contains(where: { $0.taskIdentifier == transportID }) { job.resources[index].transportID = nil }
        }
        if job.resources.contains(where: { $0.transportID != nil }) {
            job.state = .transferring; try? await persist(job); await transfer.resume(jobID: id)
        } else {
            job.state = .queued; try? await persist(job)
        }
        await pump()
    }
    func cancel(_ id: String) async {
        guard var job = jobs.first(where: { $0.id == id }), job.account == account, job.state != .completed else { return }
        exports[id]?.cancel("JOB_PAUSED")
        job.state = .cancelled; job.evidence = nil; try? await persist(job); await transfer.cancel(jobID: id)
    }
    func removeUnfinished(_ ids: Set<String>) async {
        for id in ids {
            guard var job = jobs.first(where: { $0.id == id }), job.account == account, job.unfinished else { continue }
            exports[id]?.cancel("JOB_PAUSED")
            job.removeFromActivity()
            do { try await persist(job) } catch { return }
            await transfer.cancel(jobID: id)
        }
        assetStates = [:]; updateAssetStates(jobs)
        await collectFinishedStaging()
    }
    func reprepare(_ id: String) async {
        guard initialized, !storageFailed, !updatingNetwork, engine.ready, !engine.busy else { notice = "应用尚未就绪，请等待账号连接完成后重试。"; return }
        guard let job = jobs.first(where: { $0.id == id }), job.account == account,
              [.failed, .attention, .paused].contains(job.state), !cleanupRunning, !switching else { return }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [job.assetID], options: nil).firstObject else { notice = HarborError("PHOTO_PERMISSION").localizedDescription; return }
        await cancel(id)
        // Preserve the original task policy, and check the cloud hash before
        // uploading again. A settings change must not silently change this task.
        await enqueue([asset], force: job.forceUpload, policy: job.settings, origin: job.origin ?? .manual, batchID: job.batchID)
    }
    func verifyCleanup() async {
        guard !account.isEmpty else { notice = "请先在设置中连接 Google 账号。"; return }
        guard !cleanupRunning, !updatingNetwork, workers.isEmpty, !visibleJobs.contains(where: { $0.state.active }), !account.isEmpty else { notice = "请先暂停或完成正在运行的备份。"; return }
        guard visibleJobs.contains(where: { $0.state == .completed }) else { notice = "当前账号还没有可核验的已完成备份。请先完成备份，再检查空间清理。"; return }
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
        guard network.connected && (!settings.wifiOnly || network.wifi) else { throw HarborError("WAITING_NETWORK") }
        guard job.account == account, job.state == .completed, !job.isLive else { throw HarborError(job.isLive ? "LIVE_CLEANUP_UNVERIFIED" : "CLEANUP_UNVERIFIED") }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [job.assetID], options: nil).firstObject,
              PhotoLibrary.stamp(asset) == job.assetRevision else { throw HarborError("SOURCE_CHANGED") }
        let directory = engine.home.appendingPathComponent("Staging/check-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var full = job.settings; full.edits = .both
        let control = ExportControl(wifiOnly: settings.wifiOnly); exports[job.id] = control
        defer { exports.removeValue(forKey: job.id) }
        let current = try await ResourceExporter.export(assetID: job.assetID, settings: full, directory: directory, control: control)
        guard Set(current.map(\.sha256)).isSubset(of: Set(job.sources.map(\.sha256))), !current.isEmpty else { throw HarborError("CLEANUP_UNVERIFIED") }
        for source in current {
            var request = payload(source, account: job.account)
            request["cloud_state"] = settings.cloudState; request["original_access"] = settings.originalAccess
            let result = try await engine.invoke("check_cleanup", request)
            guard result["eligible"] as? Bool == true else { throw HarborError(result["reason"] as? String ?? "CLEANUP_UNVERIFIED") }
        }
        return CleanupEvidence(account: job.account, revision: job.assetRevision, policy: settings.cleanupPolicy,
            manifest: job.sources.map { "\($0.role):\($0.sha256)" }.sorted())
    }
    func deleteVerified(ids: [String]? = nil) async {
        let selected = ids ?? cleanupReady
        guard !cleanupRunning, !selected.isEmpty, Set(selected).isSubset(of: Set(cleanupReady)) else { return }
        cleanupRunning = true
        defer { cleanupRunning = false; cleanupReady = [] }
        do {
            var identifiers = Set<String>()
            for id in selected {
                guard var job = jobs.first(where: { $0.id == id }), let evidence = job.evidence,
                      evidence.valid(job: job, settings: settings) else { throw HarborError("CLEANUP_UNVERIFIED") }
                // Re-export/hash and re-query immediately before the system deletion request.
                job.evidence = try await checkCleanup(job); try await persist(job); identifiers.insert(job.assetID)
            }
            // A long batch must not let the first item's evidence expire while checking the last.
            for id in selected {
                guard let job = jobs.first(where: { $0.id == id }), job.evidence?.valid(job: job, settings: settings) == true,
                      let asset = PHAsset.fetchAssets(withLocalIdentifiers: [job.assetID], options: nil).firstObject,
                      PhotoLibrary.stamp(asset) == job.assetRevision else { throw HarborError("CLEANUP_UNVERIFIED") }
            }
            let authorization = PHPhotoLibrary.authorizationStatus(for: .readWrite)
            guard authorization == .authorized || authorization == .limited else { throw HarborError("PHOTO_PERMISSION") }
            let values = PHAsset.fetchAssets(withLocalIdentifiers: Array(identifiers), options: nil)
            try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.deleteAssets(values) }
            guard PHPhotoLibrary.authorizationStatus(for: .readWrite) == authorization else { throw HarborError("PHOTO_PERMISSION") }
            let remaining = PHAsset.fetchAssets(withLocalIdentifiers: Array(identifiers), options: nil)
            var present = Set<String>(); remaining.enumerateObjects { asset, _, _ in present.insert(asset.localIdentifier) }
            for id in selected {
                cleanupResults[id] = jobs.first(where: { $0.id == id }).map { present.contains($0.assetID) ? "仍保留在相册" : "系统已完成删除请求" } ?? "请检查系统相册"
            }
            notice = "清理请求已完成，请查看结果。"; await library.refresh()
        } catch { notice = error.localizedDescription }
    }
    var diagnostics: String {
        let data: [String: Any] = ["version": 2, "job_count": jobs.count,
            "states": Dictionary(grouping: jobs, by: { $0.state.rawValue }).mapValues(\.count),
            "error_codes": jobs.map(\.error).filter { !$0.isEmpty }, "runtime": engine.runtime,
            "failure_stages": Dictionary(grouping: jobs.filter { !$0.error.isEmpty }, by: { $0.failureStage ?? "legacy_unknown" }).mapValues(\.count),
            "file_error_codes": jobs.compactMap(\.failureSystemCode),
            "apple_pair": applePairAvailable, "live_cleanup": false, "staged_bytes": stagedBytes,
            "pair_routes": Dictionary(grouping: jobs.flatMap { $0.livePairs ?? [] }, by: { $0.route ?? "unselected" }).mapValues(\.count),
            "pair_pending_submissions": jobs.flatMap { $0.livePairs ?? [] }.filter { $0.submitted && !$0.confirmed }.count,
            "storage_failed": storageFailed, "credential_storage_available": credentialStorageAvailable,
            "initialized": initialized, "engine_ready": engine.ready, "engine_busy": engine.busy,
            "account_switching": switching,
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            "app_build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "",
            "os": ProcessInfo.processInfo.operatingSystemVersionString]
        return String(decoding: (try? JSONSerialization.data(withJSONObject: data, options: [.prettyPrinted, .sortedKeys])) ?? Data(), as: UTF8.self)
    }
}
