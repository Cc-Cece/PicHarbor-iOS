import Foundation
import CryptoKit
import Security

struct LiveLinkConnection: Equatable {
    var host: String
    var port: Int
    var fingerprint: String
    var token: String
    var name: String
}

struct SavedComputer: Codable, Equatable {
    var host: String
    var port: Int
    var fingerprint: String
    var name: String
}

struct LiveLinkIdentity {
    var id: String
    var key: SecKey
    var publicKey: String
}

enum LiveLinkCertificate {
    static func fingerprint(_ trust: SecTrust) -> String? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let leaf = chain.first else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        guard !der.isEmpty else { return nil }
        return SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()
    }
}

enum LiveLinkKeychain {
    private static let service = "PicHarbor.live-link"

    static func read(_ account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw LiveLinkFailure.identity }
        return data
    }

    static func write(_ account: String, data: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw LiveLinkFailure.identity }
        } else if status != errSecSuccess {
            throw LiveLinkFailure.identity
        }
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

enum LiveLinkStore {
    private static let keyTag = Data("com.cccece.picharbor.live-link.p256".utf8)

    static func computer() -> SavedComputer? {
        guard let data = try? LiveLinkKeychain.read("computer"),
              let saved = try? JSONDecoder().decode(SavedComputer.self, from: data),
              LiveLinkCheck.isIPv4(saved.host),
              (1...65535).contains(saved.port),
              LiveLinkCheck.isHex(saved.fingerprint, count: 64) else { return nil }
        return saved
    }

    static func saveComputer(_ value: SavedComputer) throws {
        try LiveLinkKeychain.write("computer", data: JSONEncoder().encode(value))
    }

    static func forgetComputer() { LiveLinkKeychain.delete("computer") }

    static func loadOrCreate() throws -> LiveLinkIdentity {
        if let id = try deviceID(), LiveLinkCheck.isDeviceID(id), let key = privateKey(),
           SecKeyIsAlgorithmSupported(key, .sign, .ecdsaSignatureMessageRFC4754SHA256),
           let publicKey = try? publicPoint(key) {
            return LiveLinkIdentity(id: id, key: key, publicKey: publicKey)
        }
        deletePrivateKey()
        LiveLinkKeychain.delete("device-id")
        forgetComputer()
        let key = try makeKey()
        let publicKey = try publicPoint(key)
        let id = UUID().uuidString
        guard LiveLinkCheck.isDeviceID(id) else { throw LiveLinkFailure.identity }
        try LiveLinkKeychain.write("device-id", data: Data(id.utf8))
        return LiveLinkIdentity(id: id, key: key, publicKey: publicKey)
    }

    private static func deviceID() throws -> String? {
        guard let data = try LiveLinkKeychain.read("device-id") else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func privateKey() -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecReturnRef as String: true
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return (item as! SecKey)
    }

    private static func makeKey() throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyTag,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else { throw LiveLinkFailure.identity }
        return key
    }

    private static func deletePrivateKey() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Uncompressed point 0x04 || X || Y, not SPKI.
    static func publicPoint(_ key: SecKey) throws -> String {
        guard let publicKey = SecKeyCopyPublicKey(key) else { throw LiveLinkFailure.identity }
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?,
              data.count == 65, data.first == 0x04 else { throw LiveLinkFailure.identity }
        return data.base64EncodedString()
    }

    static func sign(key: SecKey, message: String) throws -> String {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCreateSignature(key, .ecdsaSignatureMessageRFC4754SHA256, Data(message.utf8) as CFData, &error) as Data?,
              data.count == 64 else { throw LiveLinkFailure.identity }
        return data.base64EncodedString()
    }

    static func nonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            return UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Foreground TLS sessions. Each call uses a new URLSession so each request is a new connection.
final class LiveLinkHTTP: @unchecked Sendable {
    func establish(_ target: LiveLinkTarget, identity: LiveLinkIdentity, deviceName: String) async throws -> LiveLinkConnection {
        let fingerprint: String
        switch target.pin {
        case .full(let value):
            fingerprint = value.lowercased()
        case .prefix:
            // The manual form only has 16 hex characters. Read the leaf, then MAC with the full digest.
            fingerprint = try await probe(host: target.host, port: target.port, pin: target.pin)
        }
        guard LiveLinkPin.full(fingerprint).accepts(fingerprint) else { throw LiveLinkFailure.pin }
        let saved = LiveLinkStore.computer()
        if saved?.fingerprint == fingerprint || target.code.isEmpty {
            do {
                return try await session(host: target.host, port: target.port, fingerprint: fingerprint, identity: identity, previousName: saved?.name)
            } catch LiveLinkFailure.rejected where target.code.count == 6 {
                // The computer no longer accepts this device key. Pair again when a code is available.
            }
        }
        guard target.code.count == 6 else { throw LiveLinkFailure.rejected }
        return try await pair(host: target.host, port: target.port, fingerprint: fingerprint, code: target.code, identity: identity, deviceName: deviceName)
    }

    func manifest(connection: LiveLinkConnection, model: String, items: [LiveLinkManifestItem]) async throws -> (need: Set<String>, have: Set<String>) {
        let body = try JSONEncoder().encode(LiveLinkManifestBody(model: model, items: items))
        let (status, data, _) = try await send(method: "POST", path: "/v1/manifest", host: connection.host, port: connection.port,
                                               pin: .full(connection.fingerprint), token: connection.token, body: body,
                                               contentType: "application/json", timeout: 60)
        guard status == 200, let decoded = try? JSONDecoder().decode(LiveLinkManifestResponse.self, from: data) else { throw LiveLinkFailure.rejected }
        return (Set(decoded.need), Set(decoded.have))
    }

    func put(connection: LiveLinkConnection, id: String, body: Data, name: String, size: Int64, offset: Int64, created: Int64, sha256: String) async throws -> LiveLinkBlobStep {
        guard let path = LiveLinkCrypto.blobPath(id) else { throw LiveLinkFailure.rejected }
        let headers = [
            "X-File-Name": LiveLinkCrypto.headerFileName(name),
            "X-Size": String(size),
            "X-Offset": String(offset),
            "X-Created": String(created),
            "X-Sha256": sha256
        ]
        let (status, data, _) = try await send(method: "PUT", path: path, host: connection.host, port: connection.port,
                                               pin: .full(connection.fingerprint), token: connection.token, body: body,
                                               contentType: "application/octet-stream", timeout: 180, extra: headers)
        if status == 401 { throw LiveLinkFailure.rejected }
        guard let step = LiveLinkBlob.step(status: status, data: data, fileSize: size) else { throw LiveLinkFailure.rejected }
        return step
    }

    private func probe(host: String, port: Int, pin: LiveLinkPin) async throws -> String {
        let (status, _, fingerprint) = try await send(method: "GET", path: "/", host: host, port: port, pin: pin, token: nil, body: nil, contentType: nil, timeout: 20)
        if status == 0, fingerprint.isEmpty { throw LiveLinkFailure.network }
        guard pin.accepts(fingerprint) else { throw LiveLinkFailure.pin }
        return fingerprint
    }

    private func pair(host: String, port: Int, fingerprint: String, code: String, identity: LiveLinkIdentity, deviceName: String) async throws -> LiveLinkConnection {
        let nonce = LiveLinkStore.nonce()
        let body = try JSONEncoder().encode(LiveLinkPairBody(
            deviceId: identity.id, deviceName: deviceName, platform: "ios", nonce: nonce,
            mac: LiveLinkCrypto.pairMAC(deviceID: identity.id, nonce: nonce, fingerprint: fingerprint, code: code),
            publicKey: identity.publicKey))
        let (status, data, seen) = try await send(method: "POST", path: "/v1/pair", host: host, port: port, pin: .full(fingerprint),
                                                  token: nil, body: body, contentType: "application/json", timeout: 45)
        guard seen == fingerprint else { throw LiveLinkFailure.pin }
        if status == 401 {
            let error = (try? JSONDecoder().decode(LiveLinkErrorBody.self, from: data))?.error
            throw error == "bad_code" ? LiveLinkFailure.pin : LiveLinkFailure.rejected
        }
        guard status == 200, let decoded = try? JSONDecoder().decode(LiveLinkPairResponse.self, from: data),
              decoded.fp.lowercased() == fingerprint, !decoded.token.isEmpty, !decoded.token.contains(where: \.isNewline) else { throw LiveLinkFailure.rejected }
        let name = displayName(decoded.name, fallback: host)
        let saved = SavedComputer(host: host, port: port, fingerprint: fingerprint, name: name)
        try LiveLinkStore.saveComputer(saved)
        return LiveLinkConnection(host: host, port: port, fingerprint: fingerprint, token: decoded.token, name: name)
    }

    private func session(host: String, port: Int, fingerprint: String, identity: LiveLinkIdentity, previousName: String?) async throws -> LiveLinkConnection {
        let nonce = LiveLinkStore.nonce()
        let signature = try LiveLinkStore.sign(key: identity.key, message: LiveLinkCrypto.sessionPlaintext(nonce: nonce, fingerprint: fingerprint))
        let body = try JSONEncoder().encode(LiveLinkSessionBody(deviceId: identity.id, nonce: nonce, signature: signature))
        let (status, data, seen) = try await send(method: "POST", path: "/v1/session", host: host, port: port, pin: .full(fingerprint),
                                                  token: nil, body: body, contentType: "application/json", timeout: 45)
        guard seen == fingerprint else { throw LiveLinkFailure.pin }
        if status == 401 { throw LiveLinkFailure.rejected }
        guard status == 200, let decoded = try? JSONDecoder().decode(LiveLinkSessionResponse.self, from: data),
              !decoded.token.isEmpty, !decoded.token.contains(where: \.isNewline) else { throw LiveLinkFailure.rejected }
        let name = displayName(decoded.name, fallback: previousName ?? host)
        try LiveLinkStore.saveComputer(SavedComputer(host: host, port: port, fingerprint: fingerprint, name: name))
        return LiveLinkConnection(host: host, port: port, fingerprint: fingerprint, token: decoded.token, name: name)
    }

    private func displayName(_ value: String, fallback: String) -> String {
        let cleaned = value.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return String(fallback.prefix(120)) }
        return String(cleaned.prefix(120))
    }

    private func send(method: String, path: String, host: String, port: Int, pin: LiveLinkPin, token: String?, body: Data?, contentType: String?, timeout: TimeInterval, extra: [String: String] = [:]) async throws -> (Int, Data, String) {
        guard LiveLinkCheck.isIPv4(host), (1...65535).contains(port), path.hasPrefix("/"), !path.contains(".."),
              let url = URL(string: "https://\(host):\(port)\(path)"), url.host == host else { throw LiveLinkFailure.form }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("close", forHTTPHeaderField: "Connection")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (key, value) in extra { request.setValue(value, forHTTPHeaderField: key) }
        if let body { request.setValue(String(body.count), forHTTPHeaderField: "Content-Length") }
        let exchange = LiveLinkExchange(pin: pin)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 30
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.allowsConstrainedNetworkAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        let session = URLSession(configuration: configuration, delegate: exchange, delegateQueue: nil)
        defer {
            exchange.release()
            session.finishTasksAndInvalidate()
        }
        do {
            let (data, response) = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, URLResponse), Error>) in
                    let task: URLSessionTask
                    if let body {
                        task = session.uploadTask(with: request, from: body) { data, response, error in
                            LiveLinkExchange.finish(data, response, error, continuation)
                        }
                    } else {
                        task = session.dataTask(with: request) { data, response, error in
                            LiveLinkExchange.finish(data, response, error, continuation)
                        }
                    }
                    exchange.store(task)
                    task.resume()
                }
            } onCancel: { exchange.cancel() }
            let fingerprint = exchange.fingerprint
            if exchange.rejected || !pin.accepts(fingerprint) { throw LiveLinkFailure.pin }
            guard let http = response as? HTTPURLResponse else { throw LiveLinkFailure.network }
            return (http.statusCode, data, fingerprint)
        } catch let error as LiveLinkFailure {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if exchange.rejected { throw LiveLinkFailure.pin }
            if error is CancellationError { throw CancellationError() }
            if let urlError = error as? URLError, urlError.code == .cancelled { throw CancellationError() }
            if method == "GET", pin.accepts(exchange.fingerprint) { return (0, Data(), exchange.fingerprint) }
            throw LiveLinkFailure.network
        }
    }
}

/// One delegate per TLS connection so a cancelled request cannot change the next pin check.
private final class LiveLinkExchange: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let pin: LiveLinkPin
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false
    private var seen = ""
    private var failed = false
    init(pin: LiveLinkPin) { self.pin = pin }
    var fingerprint: String { lock.withLock { seen } }
    var rejected: Bool { lock.withLock { failed } }

    func store(_ task: URLSessionTask) {
        let stop = lock.withLock { () -> Bool in
            self.task = task
            return cancelled
        }
        if stop { task.cancel() }
    }

    func cancel() {
        let task = lock.withLock { () -> URLSessionTask? in
            cancelled = true
            return self.task
        }
        task?.cancel()
    }

    func release() { lock.withLock { task = nil } }

    /// Accept the server only after the leaf SHA-256 matches the pin. Default trust rejects this self-signed certificate.
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        decide(challenge, completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        decide(challenge, completionHandler)
    }

    private func decide(_ challenge: URLAuthenticationChallenge, _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        guard let fingerprint = LiveLinkCertificate.fingerprint(trust), pin.accepts(fingerprint) else {
            lock.withLock { failed = true }
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        lock.withLock { seen = fingerprint; failed = false }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    static func finish(_ data: Data?, _ response: URLResponse?, _ error: Error?, _ continuation: CheckedContinuation<(Data, URLResponse), Error>) {
        if let error {
            continuation.resume(throwing: error)
        } else if let response {
            continuation.resume(returning: (data ?? Data(), response))
        } else {
            continuation.resume(throwing: LiveLinkFailure.network)
        }
    }
}

struct LiveLinkManifestItem: Codable {
    var id: String
    var name: String
    var size: Int64
    var created: Int64
    var sha256: String
    var pairId: String
    var role: String
}

private struct LiveLinkPairBody: Codable {
    var deviceId: String
    var deviceName: String
    var platform: String
    var nonce: String
    var mac: String
    var publicKey: String
}

private struct LiveLinkSessionBody: Codable {
    var deviceId: String
    var nonce: String
    var signature: String
}

private struct LiveLinkManifestBody: Codable {
    var model: String
    var items: [LiveLinkManifestItem]
}

private struct LiveLinkPairResponse: Codable {
    var token: String
    var name: String
    var fp: String
}

private struct LiveLinkSessionResponse: Codable {
    var token: String
    var name: String
}

private struct LiveLinkManifestResponse: Codable {
    var need: [String]
    var have: [String]
}

private struct LiveLinkErrorBody: Codable {
    var error: String?
}

/// Registered so a relaunch for this identifier can drain events. File bytes are not queued here:
/// nsurlsessiond evaluates trust itself and cannot accept this self-signed certificate.
final class LiveLinkBackground: NSObject, URLSessionTaskDelegate {
    static let identifier = "com.cccece.picharbor.link.transfers"
    static let shared = LiveLinkBackground()
    var backgroundCompletion: (() -> Void)?
    private var session: URLSession?

    func activate() {
        guard session == nil else { return }
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.identifier)
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            let completion = self.backgroundCompletion
            self.backgroundCompletion = nil
            completion?()
        }
    }
}
