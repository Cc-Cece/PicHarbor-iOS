import Foundation
import Photos

/// Cancels PhotoKit downloads too, rather than only pausing the later HTTP upload.
final class ExportControl: @unchecked Sendable {
    let wifiOnly: Bool
    private let budget: PipelineBufferBudget?
    private let jobID: String
    private let lease: BackupExecutionLease?
    private let lock = NSLock()
    private var requests = Set<PHAssetResourceDataRequestID>()
    private var observers: [UUID: (String) -> Void] = [:]
    private var reason: String?
    init(wifiOnly: Bool, budget: PipelineBufferBudget? = nil, jobID: String = "") { self.wifiOnly = wifiOnly; self.budget = budget; self.jobID = jobID; self.lease = BackupExecutionContext.lease }
    func reserve(_ bytes: Int64) throws { try lease?.check(); try budget?.reserve(bytes, job: jobID); lease?.progress() }
    var failure: String? { lock.lock(); defer { lock.unlock() }; return reason ?? lease?.cancellation }
    func register(_ id: PHAssetResourceDataRequestID) {
        lock.lock(); let cancelled = reason != nil
        if !cancelled { requests.insert(id) }; lock.unlock()
        if cancelled { PHAssetResourceManager.default().cancelDataRequest(id) }
    }
    func unregister(_ id: PHAssetResourceDataRequestID) { lock.lock(); requests.remove(id); lock.unlock() }
    func observe(_ id: UUID, handler: @escaping (String) -> Void) {
        lock.lock(); let code = reason ?? lease?.cancellation
        if code == nil { observers[id] = handler }; lock.unlock()
        if let code { handler(code) }
    }
    func unobserve(_ id: UUID) { lock.lock(); observers.removeValue(forKey: id); lock.unlock() }
    func cancel(_ code: String) {
        lock.lock(); reason = reason ?? code; let ids = requests; requests = []; let callbacks = Array(observers.values); observers = [:]; lock.unlock()
        for callback in callbacks { callback(code) }
        for id in ids { PHAssetResourceManager.default().cancelDataRequest(id) }
    }
}

final class ResourceFileWriter: @unchecked Sendable {
    private let lock = NSLock()
    private let file: FileHandle
    private let url: URL
    private let control: ExportControl?
    private var id: PHAssetResourceDataRequestID?
    private var finished = false
    private var failure: Error?
    private var completion: ((Error?) -> Void)?
    private var bytesSinceCheck = 16 * 1024 * 1024
    init(url: URL, control: ExportControl?) throws {
        self.url = url; self.control = control
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw HarborError("FILE_ACCESS") }
        file = try FileHandle(forWritingTo: url)
    }
    func attach(_ id: PHAssetResourceDataRequestID) {
        lock.lock()
        self.id = id
        let mustCancel = finished || failure != nil
        lock.unlock()
        if mustCancel { PHAssetResourceManager.default().cancelDataRequest(id); return }
        control?.register(id)
        lock.lock(); let alreadyFinished = finished; lock.unlock()
        if alreadyFinished { control?.unregister(id) }
    }
    func append(_ data: Data) {
        lock.lock()
        guard !finished && failure == nil else { lock.unlock(); return }
        do {
            if let code = control?.failure { throw HarborError(code) }
            if bytesSinceCheck >= 16 * 1024 * 1024 {
                let free = (try FileManager.default.attributesOfFileSystem(forPath: url.deletingLastPathComponent().path)[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
                guard free > Int64(data.count) + 64 * 1024 * 1024 else { throw HarborError("DISK_FULL") }
                bytesSinceCheck = 0
            }
            try control?.reserve(Int64(data.count))
            try file.write(contentsOf: data); bytesSinceCheck += data.count
            lock.unlock()
        } catch {
            failure = error; let id = self.id; let callback = completion; lock.unlock()
            callback?(error)
            if let id { PHAssetResourceManager.default().cancelDataRequest(id) }
        }
    }
    func setCompletion(_ callback: @escaping (Error?) -> Void) { lock.lock(); completion = callback; lock.unlock() }
    func finish(_ error: Error?) -> (Bool, Error?) {
        lock.lock()
        guard !finished else { lock.unlock(); return (false, nil) }
        finished = true; completion = nil
        let result: Error? = failure ?? (control?.failure).map { HarborError($0) as Error } ?? error
        let id = self.id
        do { try file.close() } catch { failure = error }
        let final = result ?? failure; lock.unlock()
        if let id { control?.unregister(id) }
        if final != nil { try? FileManager.default.removeItem(at: url) }
        return (true, final)
    }
    static func write(resource: PHAssetResource, url: URL, control: ExportControl?) async throws {
        if let code = control?.failure { throw HarborError(code) }
        let writer = try ResourceFileWriter(url: url, control: control)
        let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let observer = UUID()
            let complete: (Error?) -> Void = { error in
                let result = writer.finish(error)
                guard result.0 else { return }
                control?.unobserve(observer)
                if let error = result.1 { continuation.resume(throwing: error) } else { continuation.resume() }
            }
            writer.setCompletion(complete)
            control?.observe(observer) { code in complete(HarborError(code)) }
            if let code = control?.failure { complete(HarborError(code)); return }
            let id = PHAssetResourceManager.default().requestData(for: resource, options: options, dataReceivedHandler: { writer.append($0) }) { error in
                complete(error)
            }
            writer.attach(id)
        }
    }
}

enum PhotoResourceWriter {
    static func write(resource: PHAssetResource, url: URL, control: ExportControl?) async throws {
        try await ResourceFileWriter.write(resource: resource, url: url, control: control)
    }
}
