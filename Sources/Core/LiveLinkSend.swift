import Foundation
import Combine
import CryptoKit
import Photos
import UIKit
import Darwin

enum LiveLinkDevice {
    static func model() -> String {
        var system = utsname()
        uname(&system)
        let machine = withUnsafeBytes(of: &system.machine) { raw -> String in
            guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return "" }
            return String(cString: base)
        }.trimmingCharacters(in: .whitespacesAndNewlines)
        return machine.isEmpty ? "iPhone" : String(machine.prefix(80))
    }

    static func name() -> String {
        let value = UIDevice.current.name.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "iPhone" : String(value.prefix(80))
    }
}

private struct LiveLinkHashEntry: Codable {
    var sha256: String
    var size: Int64
}

private final class LiveLinkHashCache {
    private var values: [String: LiveLinkHashEntry] = [:]
    private let url: URL
    init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PicHarbor/LiveLink", isDirectory: true)
        url = folder.appendingPathComponent("hashes.json")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: url), let decoded = try? JSONDecoder().decode([String: LiveLinkHashEntry].self, from: data) {
            values = decoded
        }
    }
    func hash(key: String, size: Int64) -> String? {
        guard let entry = values[key], entry.size == size, LiveLinkCheck.isHex(entry.sha256, count: 64) else { return nil }
        return entry.sha256
    }
    func store(key: String, sha256: String, size: Int64) {
        values[key] = LiveLinkHashEntry(sha256: sha256, size: size)
        if let data = try? JSONEncoder().encode(values) { try? data.write(to: url, options: .atomic) }
    }
}

private final class LiveLinkFileWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let url: URL
    private var request: PHAssetResourceDataRequestID?
    private var resumed = false
    private var failure: Error?
    private var cancelled = false

    init(url: URL) throws {
        self.url = url
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw LiveLinkFailure.file }
        do { handle = try FileHandle(forWritingTo: url) }
        catch { try? FileManager.default.removeItem(at: url); throw LiveLinkFailure.file }
    }

    func append(_ data: Data) {
        let request = lock.withLock { () -> PHAssetResourceDataRequestID? in
            guard failure == nil, !cancelled, !resumed else { return nil }
            do { try handle.write(contentsOf: data); return nil }
            catch { failure = error; return self.request }
        }
        if let request { PHAssetResourceManager.default().cancelDataRequest(request) }
    }

    func attach(_ id: PHAssetResourceDataRequestID) {
        let stop = lock.withLock { () -> Bool in
            request = id
            return cancelled || failure != nil || resumed
        }
        if stop { PHAssetResourceManager.default().cancelDataRequest(id) }
    }

    func cancel() {
        let request = lock.withLock { () -> PHAssetResourceDataRequestID? in
            cancelled = true
            return self.request
        }
        if let request { PHAssetResourceManager.default().cancelDataRequest(request) }
    }

    func finish(_ error: Error?, _ continuation: CheckedContinuation<Void, Error>) {
        let decision = lock.withLock { () -> (Bool, Error?) in
            guard !resumed else { return (false, nil) }
            resumed = true
            try? handle.close()
            if cancelled { return (true, CancellationError()) }
            return (true, failure ?? error)
        }
        guard decision.0 else { return }
        if let error = decision.1 {
            try? FileManager.default.removeItem(at: url)
            continuation.resume(throwing: error)
        } else {
            continuation.resume()
        }
    }
}

enum LiveLinkFiles {
    struct Prepared {
        var item: LiveLinkManifestItem
        var url: URL
        var cacheKey: String
    }

    static func parts(_ asset: PHAsset) -> [(PHAssetResource, String)] {
        let resources = PHAssetResource.assetResources(for: asset)
        func pick(_ types: [PHAssetResourceType]) -> PHAssetResource? {
            for type in types {
                if let found = resources.first(where: { $0.type == type }) { return found }
            }
            return nil
        }
        if asset.mediaType == .video {
            guard let video = pick([.video, .fullSizeVideo]) else { return [] }
            return [(video, "video")]
        }
        guard asset.mediaType == .image, let photo = pick([.photo, .fullSizePhoto]) else { return [] }
        var result = [(photo, "still")]
        if asset.mediaSubtypes.contains(.photoLive), let video = pick([.pairedVideo, .fullSizePairedVideo]) {
            result.append((video, "video"))
        }
        return result
    }

    static func fileName(_ resource: PHAssetResource, role: String) -> String {
        let raw = (resource.originalFilename as NSString).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty || raw == "." || raw == "/" { return role == "video" ? "video.mov" : "photo.heic" }
        return raw
    }

    static func export(resource: PHAssetResource, to url: URL, network: Bool) async throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let writer = try LiveLinkFileWriter(url: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let options = PHAssetResourceRequestOptions()
                options.isNetworkAccessAllowed = network
                let id = PHAssetResourceManager.default().requestData(for: resource, options: options, dataReceivedHandler: { writer.append($0) }) { error in
                    writer.finish(error, continuation)
                }
                writer.attach(id)
            }
        } onCancel: { writer.cancel() }
    }

    static func sha256(_ url: URL) throws -> (String, Int64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var size: Int64 = 0
        while true {
            try Task.checkCancellation()
            guard let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty else { break }
            hasher.update(data: data)
            size += Int64(data.count)
        }
        guard size > 0 else { throw LiveLinkFailure.file }
        return (hasher.finalize().map { String(format: "%02x", $0) }.joined(), size)
    }

    static func read(url: URL, offset: Int64, length: Int) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))
        var data = Data()
        data.reserveCapacity(length)
        while data.count < length {
            guard let piece = try handle.read(upToCount: length - data.count), !piece.isEmpty else { throw LiveLinkFailure.file }
            data.append(piece)
        }
        return data
    }

    static func cloudOnly(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == PHPhotosErrorDomain && ns.code == PHPhotosError.Code.networkAccessRequired.rawValue { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return cloudOnly(underlying) }
        return false
    }
}

@MainActor
final class LiveLinkController: ObservableObject {
    @Published var saved: SavedComputer?
    @Published var busy = false
    @Published var status = ""
    @Published var message = ""
    @Published var currentFile = ""
    @Published var fraction = 0.0
    @Published var skipped = 0
    @Published var sentCount = 0
    @Published var hadCount = 0
    @Published var failedCount = 0
    @Published var started = false
    private var task: Task<Void, Never>?
    private var run = 0
    private var connection: LiveLinkConnection?
    private let http = LiveLinkHTTP()
    private let cache = LiveLinkHashCache()

    func reload() { saved = LiveLinkStore.computer() }

    func forget() {
        LiveLinkStore.forgetComputer()
        saved = nil
        connection = nil
        message = ""
    }

    func stop() { task?.cancel() }

    func connectSaved() {
        guard let saved, !busy else { return }
        begin(trackSend: false) { [self] in
            status = L10n.text("正在连接电脑…")
            let link = try await open(LiveLinkTarget(host: saved.host, port: saved.port, pin: .full(saved.fingerprint), code: ""))
            message = L10n.text("已连接 {0}", [link.name])
        }
    }

    func send(host: String, port: String, prefix: String, code: String, scanned: String?, assets: [PHAsset], allowCloud: Bool) {
        guard !busy else { return }
        begin(trackSend: true) { [self] in
            let target = try resolve(host: host, portText: port, prefixText: prefix, codeText: code, scanned: scanned)
            status = L10n.text("正在连接电脑…")
            guard !assets.isEmpty else {
                message = L10n.text("没有可发送的照片或视频。")
                return
            }
            let link = try await open(target)
            message = L10n.text("已连接 {0}", [link.name])
            try await transfer(link, assets: assets, allowCloud: allowCloud)
            status = L10n.text("发送完成")
            fraction = 1
        }
    }

    private func begin(trackSend: Bool, _ work: @escaping @MainActor () async throws -> Void) {
        run += 1
        let ticket = run
        task?.cancel()
        busy = true
        message = ""
        status = ""
        currentFile = ""
        if trackSend {
            started = true
            fraction = 0
            skipped = 0
            sentCount = 0
            hadCount = 0
            failedCount = 0
        }
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await work()
            } catch is CancellationError {
                if ticket == self.run { self.message = L10n.text("已取消") }
            } catch {
                if ticket == self.run {
                    self.connection = nil
                    self.message = error.localizedDescription
                }
            }
            if ticket == self.run {
                self.busy = false
                self.saved = LiveLinkStore.computer()
            }
        }
    }

    private func resolve(host: String, portText: String, prefixText: String, codeText: String, scanned: String?) throws -> LiveLinkTarget {
        let hostTrim = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = prefixText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let codeRaw = codeText.trimmingCharacters(in: .whitespacesAndNewlines)
        if hostTrim.isEmpty, prefix.isEmpty, codeRaw.isEmpty, let saved {
            return LiveLinkTarget(host: saved.host, port: saved.port, pin: .full(saved.fingerprint), code: "")
        }
        guard LiveLinkCheck.isIPv4(hostTrim), let port = LiveLinkCheck.port(portText) else { throw LiveLinkFailure.form }
        if let scannedFull = scanned?.lowercased(), LiveLinkCheck.isHex(scannedFull, count: 64), !prefix.isEmpty, scannedFull.hasPrefix(prefix) {
            if codeRaw.isEmpty { return LiveLinkTarget(host: hostTrim, port: port, pin: .full(scannedFull), code: "") }
            guard let code = LiveLinkCheck.pairingCode(codeRaw) else { throw LiveLinkFailure.form }
            return LiveLinkTarget(host: hostTrim, port: port, pin: .full(scannedFull), code: code)
        }
        guard prefix.count == 16 || prefix.count == 64, LiveLinkCheck.isHex(prefix) else { throw LiveLinkFailure.form }
        let pin: LiveLinkPin = prefix.count == 64 ? .full(prefix) : .prefix(prefix)
        if codeRaw.isEmpty {
            guard let saved, saved.host == hostTrim, saved.port == port, pin.accepts(saved.fingerprint) else { throw LiveLinkFailure.form }
            return LiveLinkTarget(host: saved.host, port: saved.port, pin: .full(saved.fingerprint), code: "")
        }
        guard let code = LiveLinkCheck.pairingCode(codeRaw) else { throw LiveLinkFailure.form }
        return LiveLinkTarget(host: hostTrim, port: port, pin: pin, code: code)
    }

    private func open(_ target: LiveLinkTarget) async throws -> LiveLinkConnection {
        if let connection, connection.host == target.host, connection.port == target.port, target.pin.accepts(connection.fingerprint) {
            return connection
        }
        let identity = try LiveLinkStore.loadOrCreate()
        let link = try await http.establish(target, identity: identity, deviceName: LiveLinkDevice.name())
        connection = link
        saved = LiveLinkStore.computer()
        return link
    }

    private func transfer(_ link: LiveLinkConnection, assets: [PHAsset], allowCloud: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PicHarborLiveLink-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = LiveLinkDevice.model()
        let total = assets.count
        for (index, asset) in assets.enumerated() {
            try Task.checkCancellation()
            status = L10n.text("正在准备并核对文件…")
            fraction = Double(index) / Double(max(total, 1))
            let prepared = try await prepare(asset, directory: directory, allowCloud: allowCloud)
            if prepared.isEmpty { continue }
            status = L10n.text("正在发送 {0}/{1}", [String(index + 1), String(total)])
            let response = try await http.manifest(connection: link, model: model, items: prepared.map(\.item))
            for file in prepared {
                currentFile = file.item.name
                if response.need.contains(file.item.id) {
                    try await upload(file, connection: link, done: index, total: total)
                    sentCount += 1
                } else if response.have.contains(file.item.id) {
                    hadCount += 1
                } else {
                    failedCount += 1
                }
                try? FileManager.default.removeItem(at: file.url)
            }
            fraction = Double(index + 1) / Double(max(total, 1))
        }
        currentFile = ""
    }

    /// One asset, or both parts of one Live Photo, is exported and manifested together.
    private func prepare(_ asset: PHAsset, directory: URL, allowCloud: Bool) async throws -> [LiveLinkFiles.Prepared] {
        let parts = LiveLinkFiles.parts(asset)
        if parts.isEmpty { failedCount += 1; return [] }
        var prepared: [LiveLinkFiles.Prepared] = []
        var failedPart = false
        for (resource, role) in parts {
            try Task.checkCancellation()
            let name = LiveLinkFiles.fileName(resource, role: role)
            currentFile = name
            let ext = (name as NSString).pathExtension
            let base = directory.appendingPathComponent(UUID().uuidString)
            let url = ext.isEmpty ? base : base.appendingPathExtension(ext)
            do {
                try await LiveLinkFiles.export(resource: resource, to: url, network: allowCloud)
                let stamp = asset.modificationDate.map { $0.timeIntervalSince1970.bitPattern } ?? 0
                let key = asset.localIdentifier + "\n" + String(stamp) + "\n" + role
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
                guard size > 0 else { throw LiveLinkFailure.file }
                let sha256: String
                if let cached = cache.hash(key: key, size: size) {
                    sha256 = cached
                } else {
                    let hashed = try await Task.detached(priority: .userInitiated) { try LiveLinkFiles.sha256(url) }.value
                    guard hashed.1 == size else { throw LiveLinkFailure.file }
                    sha256 = hashed.0
                    cache.store(key: key, sha256: sha256, size: size)
                }
                let created = max(Int64(0), Int64(asset.creationDate?.timeIntervalSince1970 ?? 0))
                let item = LiveLinkManifestItem(id: LiveLinkCrypto.itemID(localIdentifier: asset.localIdentifier, role: role),
                                                name: name, size: size, created: created,
                                                sha256: sha256, pairId: LiveLinkCrypto.pairID(asset.localIdentifier), role: role)
                prepared.append(LiveLinkFiles.Prepared(item: item, url: url, cacheKey: key))
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: url)
                throw CancellationError()
            } catch {
                try? FileManager.default.removeItem(at: url)
                if !allowCloud, LiveLinkFiles.cloudOnly(error) { skipped += 1 }
                else { failedPart = true }
            }
        }
        if failedPart { failedCount += 1 }
        return prepared
    }

    private func upload(_ file: LiveLinkFiles.Prepared, connection: LiveLinkConnection, done: Int, total: Int) async throws {
        let url = file.url
        var item = file.item
        var offset: Int64 = 0
        var rehashed = false
        var restarts = 0
        var importRetries = 0
        var networkRetries = 0
        var stalls = 0
        // The computer rejects chunks above 8 MB. Stay at 4 MB.
        let limit = 4 * 1024 * 1024
        while offset < item.size {
            try Task.checkCancellation()
            let within = Double(offset) / Double(max(item.size, 1))
            fraction = min(1, (Double(done) + within) / Double(max(total, 1)))
            let length = Int(min(Int64(limit), item.size - offset))
            let chunk = try await Task.detached(priority: .userInitiated) { try LiveLinkFiles.read(url: url, offset: offset, length: length) }.value
            do {
                let step = try await http.put(connection: connection, id: item.id, body: chunk, name: item.name, size: item.size,
                                              offset: offset, created: item.created, sha256: item.sha256)
                switch step {
                case .done:
                    return
                case .advance(let received):
                    if received == offset { stalls += 1; if stalls > 3 { throw LiveLinkFailure.rejected } }
                    else { stalls = 0 }
                    offset = received
                    importRetries = 0
                    networkRetries = 0
                case .retry:
                    importRetries += 1
                    if importRetries > 3 { throw LiveLinkFailure.rejected }
                    try await Task.sleep(nanoseconds: 400_000_000)
                case .restart:
                    if !rehashed {
                        let hashed = try await Task.detached(priority: .userInitiated) { try LiveLinkFiles.sha256(url) }.value
                        rehashed = true
                        if hashed.0 != item.sha256 || hashed.1 != item.size {
                            guard hashed.1 == item.size else { throw LiveLinkFailure.file }
                            item = LiveLinkManifestItem(id: item.id, name: item.name, size: item.size, created: item.created,
                                                        sha256: hashed.0, pairId: item.pairId, role: item.role)
                            cache.store(key: file.cacheKey, sha256: hashed.0, size: hashed.1)
                        }
                    } else {
                        restarts += 1
                        if restarts > 2 { throw LiveLinkFailure.rejected }
                    }
                    offset = 0
                    stalls = 0
                }
            } catch LiveLinkFailure.network {
                networkRetries += 1
                if networkRetries > 3 { throw LiveLinkFailure.network }
                try await Task.sleep(nanoseconds: 400_000_000)
            }
        }
    }
}
