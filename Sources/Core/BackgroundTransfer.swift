import Foundation
import UIKit
import BackgroundTasks
import Network

struct TransferReceipt: Codable, Identifiable {
    var id: Int
    var jobID: String
    var resourceID: String
    var responsePath: String
    var status: Int
    var error: String
}

final class HarborTransferTask {
    let raw: URLSessionTask
    let taskIdentifier: Int
    init(_ raw: URLSessionTask, port: Int = 0) {
        self.raw = raw; taskIdentifier = (port << 32) | raw.taskIdentifier
    }
    var taskDescription: String? { raw.taskDescription }
    var originalRequest: URLRequest? { raw.originalRequest }
    var state: URLSessionTask.State { raw.state }
    func resume() { raw.resume() }
    func suspend() { raw.suspend() }
    func cancel() { raw.cancel() }
}

final class BackgroundTransfer: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    static let identifier = "com.cccece.picharbor.transfers.v2"
    static let shared = BackgroundTransfer()
    var onReceipt: ((TransferReceipt) -> Void)?
    var onProgress: ((UploadProgressSample) -> Void)?
    var backgroundCompletion: (() -> Void)?
    private var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PicHarbor/Staging", isDirectory: true)
    }
    private var lastProgress: [Int: TimeInterval] = [:]
    private var responseFailures: [Int: String] = [:]
    private let delegateQueue: OperationQueue = { let queue = OperationQueue(); queue.maxConcurrentOperationCount = 1; return queue }()
    private var responses: UploadResponseStore { UploadResponseStore(root: root) }
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.waitsForConnectivity = true
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForResource = 7 * 24 * 3600
        configuration.timeoutIntervalForRequest = 120
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
    }()
    private let proxyLock = NSLock()
    private var proxySessions: [Int: URLSession] = [:]
    private func proxySession(_ port: Int) -> URLSession {
        proxyLock.withLock {
            if let existing = proxySessions[port] { return existing }
            let configuration = URLSessionConfiguration.default
            ProxyManager.apply(port: port, to: configuration)
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 24 * 3600
            configuration.urlCache = nil
            let value = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
            value.sessionDescription = String(port); proxySessions[port] = value; return value
        }
    }
    private func identifier(_ session: URLSession, _ task: URLSessionTask) -> Int {
        ((Int(session.sessionDescription ?? "") ?? 0) << 32) | task.taskIdentifier
    }
    func activate() { _ = session }
    func create(job: BackupJob, resource: MediaResource, plan: [String: Any]) throws -> HarborTransferTask {
        guard let address = plan["url"] as? String, let url = URL(string: address), url.scheme == "https", url.host == "photos.googleapis.com" else { throw HarborError("INVALID_UPLOAD_URL") }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.allowsCellularAccess = !job.settings.wifiOnly
        request.setValue(String(resource.size), forHTTPHeaderField: "Content-Length")
        for (key, value) in plan["headers"] as? [String: String] ?? [:] { request.setValue(value, forHTTPHeaderField: key) }
        let port = max(0, job.proxyPort ?? 0)
        let transport = port > 0 ? proxySession(port) : session
        let task = transport.uploadTask(with: request, fromFile: URL(fileURLWithPath: resource.path))
        guard task.taskIdentifier < Int(UInt32.max) else { task.cancel(); throw HarborError("DATABASE_ERROR") }
        task.taskDescription = job.id + ":" + resource.id
        let wrapped = HarborTransferTask(task, port: port)
        onProgress?(UploadProgressSample(taskID: wrapped.taskIdentifier, jobID: job.id, resourceID: resource.id,
                                         sent: 0, total: resource.size, time: ProcessInfo.processInfo.systemUptime))
        return wrapped
    }
    func tasks() async -> [HarborTransferTask] {
        var result = await session.allTasks.map { HarborTransferTask($0) }
        let sessions = proxyLock.withLock { proxySessions }
        for (port, value) in sessions {
            result += await value.allTasks.map { HarborTransferTask($0, port: port) }
        }
        return result
    }
    func pause(jobID: String) async {
        for task in await tasks() where task.taskDescription?.hasPrefix(jobID + ":") == true { task.suspend() }
    }
    func resume(jobID: String) async {
        for task in await tasks() where task.taskDescription?.hasPrefix(jobID + ":") == true { task.resume() }
    }
    func cancel(jobID: String) async {
        for task in await tasks() where task.taskDescription?.hasPrefix(jobID + ":") == true { task.cancel() }
    }
    func pendingReceipts() throws -> [TransferReceipt] {
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        return try files.filter { $0.lastPathComponent.hasPrefix("receipt-") }.map { try JSONDecoder().decode(TransferReceipt.self, from: Data(contentsOf: $0)) }
    }
    func acknowledge(_ receipt: TransferReceipt) {
        try? FileManager.default.removeItem(at: root.appendingPathComponent("receipt-\(receipt.id).json"))
    }
    private func responseURL(_ id: Int) -> URL { responses.url(id) }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        do {
            try responses.prepare(identifier(session, dataTask))
            completionHandler(.allow)
        } catch { responseFailures[identifier(session, dataTask)] = "UPLOAD_RESPONSE_WRITE"; completionHandler(.cancel) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try responses.append(data, id: identifier(session, dataTask))
        } catch { responseFailures[identifier(session, dataTask)] = (error as? HarborError)?.code ?? "UPLOAD_RESPONSE_WRITE"; dataTask.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let now = Date.timeIntervalSinceReferenceDate
        guard totalBytesSent == totalBytesExpectedToSend || now - (lastProgress[identifier(session, task)] ?? 0) >= 0.25 else { return }
        lastProgress[identifier(session, task)] = now
        let parts = (task.taskDescription ?? "").components(separatedBy: ":")
        guard parts.count == 2 else { return }
        onProgress?(UploadProgressSample(taskID: identifier(session, task), jobID: parts[0], resourceID: parts[1],
                                         sent: totalBytesSent, total: totalBytesExpectedToSend, time: ProcessInfo.processInfo.systemUptime))
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lastProgress.removeValue(forKey: identifier(session, task))
        let parts = (task.taskDescription ?? "").components(separatedBy: ":")
        guard parts.count == 2 else { return }
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        var code = responseFailures.removeValue(forKey: identifier(session, task)) ?? (error == nil && (200..<300).contains(status) ? "" : ([401, 403].contains(status) ? "UPLOAD_EXPIRED" : "NETWORK_ERROR"))
        if code.isEmpty {
            do { try responses.validate(identifier(session, task)) }
            catch { code = (error as? HarborError)?.code ?? "UPLOAD_RESPONSE_READ" }
        }
        let receipt = TransferReceipt(id: identifier(session, task), jobID: parts[0], resourceID: parts[1], responsePath: responseURL(identifier(session, task)).path, status: status, error: code)
        do {
            try JSONEncoder().encode(receipt).write(to: root.appendingPathComponent("receipt-\(receipt.id).json"), options: .atomic)
            onReceipt?(receipt)
        } catch {
            // Missing receipt is reconciled against persisted task IDs on the next launch.
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { let completion = self.backgroundCompletion; self.backgroundCompletion = nil; completion?() }
    }
}

@MainActor
final class NetworkStatus: ObservableObject {
    @Published var connected = false
    @Published var wifi = false
    private let monitor = NWPathMonitor()
    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.connected = path.status == .satisfied; self?.wifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) }
        }
        monitor.start(queue: DispatchQueue(label: "io.picharbor.network"))
    }
}

final class HarborAppDelegate: NSObject, UIApplicationDelegate {
    static let processingID = "com.cccece.picharbor.processing"
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.processingID, using: nil) { task in
            let operation = Task { @MainActor in
                await HarborModel.shared.backgroundWake()
                task.setTaskCompleted(success: !Task.isCancelled)
                Self.schedule()
            }
            task.expirationHandler = { operation.cancel() }
        }
        return true
    }
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        guard identifier == BackgroundTransfer.identifier else { completionHandler(); return }
        BackgroundTransfer.shared.backgroundCompletion = completionHandler
        BackgroundTransfer.shared.activate()
        Task { @MainActor in
            var lease = UIBackgroundTaskIdentifier.invalid
            lease = application.beginBackgroundTask(withName: "Finish backup confirmation") {
                if lease != .invalid { application.endBackgroundTask(lease); lease = .invalid }
            }
            await HarborModel.shared.backgroundWake()
            if lease != .invalid { application.endBackgroundTask(lease) }
        }
    }
    static func schedule() {
        let request = BGProcessingTaskRequest(identifier: processingID)
        request.requiresNetworkConnectivity = true
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
