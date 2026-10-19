import Foundation
import Network
import Security

enum ProxyFallback: String, Codable, CaseIterable, Identifiable {
    case wait, nodes, direct
    var id: String { rawValue }
    var title: String {
        switch self {
        case .wait: return L10n.text("暂停并等待")
        case .nodes: return L10n.text("尝试备用节点")
        case .direct: return L10n.text("备用节点失败后尝试直连")
        }
    }
}
struct ProxyPreferences: Codable {
    var enabled = false
    var primary = ""
    var backups: [String] = []
    var fallback: ProxyFallback = .wait
}
enum ProxyContext {
    // nil: global; -1: an explicitly chosen direct route; positive: loopback port.
    @TaskLocal static var port: Int?
}
enum ProxyConfiguration {
    static func nodes(_ object: [String: Any]) throws -> [[String: Any]] {
        guard let values = object["proxies"] as? [[String: Any]], !values.isEmpty, values.count <= 64 else { throw HarborError("PROXY_CONFIG_UNSUPPORTED") }
        var names = Set<String>()
        for node in values {
            guard let name = node["name"] as? String, !name.isEmpty, name.utf8.count <= 256,
                  names.insert(name).inserted, !["DIRECT", "REJECT", "GLOBAL"].contains(name.uppercased()),
                  let type = node["type"] as? String, !["direct", "reject", "dns"].contains(type.lowercased()),
                  node["dialer-proxy"] == nil, node["interface-name"] == nil, node["routing-mark"] == nil else { throw HarborError("PROXY_CONFIG_UNSUPPORTED") }
        }
        return values
    }
    static func runtime(_ nodes: [[String: Any]]) throws -> (String, [String: Int]) {
        var ports: [String: Int] = [:]
        var listeners: [[String: Any]] = []
        for (index, node) in nodes.enumerated() {
            guard let name = node["name"] as? String else { throw HarborError("PROXY_CONFIG_UNSUPPORTED") }
            let port = 24500 + index; ports[name] = port
            listeners.append(["name": "picharbor-\(index)", "type": "mixed", "listen": "127.0.0.1", "port": port, "proxy": name])
        }
        let document: [String: Any] = ["mode": "rule", "log-level": "silent", "allow-lan": false,
            "bind-address": "127.0.0.1", "port": 0, "socks-port": 0, "mixed-port": 0,
            "external-controller": "", "external-controller-unix": "", "tun": ["enable": false],
            "dns": ["enable": false], "profile": ["store-selected": false, "store-fake-ip": false],
            "proxies": nodes, "listeners": listeners, "rules": ["MATCH,REJECT"]]
        return (String(decoding: try JSONSerialization.data(withJSONObject: document), as: UTF8.self), ports)
    }
    static func candidates(_ preferences: ProxyPreferences, override: ProxyFallback?, failures: [String]) -> [String] {
        guard preferences.enabled else { return [""] }
        let policy = override ?? preferences.fallback
        var result = [preferences.primary]
        if policy != .wait { result += preferences.backups.filter { $0 != preferences.primary } }
        var seen = Set<String>(); result = result.filter { !$0.isEmpty && seen.insert($0).inserted && !failures.contains($0) }
        if policy == .direct && !failures.contains("") { result.append("") }
        return result
    }
}

enum ProxySecretStore {
    private static var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "PicHarbor.proxy", kSecAttrAccount as String: "nodes-v1"] }
    static func read() throws -> Data? {
        var query = query; query[kSecReturnData as String] = true
        var item: CFTypeRef?; let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw HarborError("KEYCHAIN_ERROR") }
        return data
    }
    static func save(_ data: Data) throws {
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var entry = query; entry[kSecValueData as String] = data
            entry[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(entry as CFDictionary, nil) == errSecSuccess else { throw HarborError("KEYCHAIN_ERROR") }
        } else if status != errSecSuccess { throw HarborError("KEYCHAIN_ERROR") }
    }
}

@MainActor
final class ProxyManager: ObservableObject {
    static let shared = ProxyManager()
    @Published var preferences: ProxyPreferences {
        didSet { if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: "picharbor.proxy.preferences.v1") } }
    }
    @Published private(set) var names: [String] = []
    @Published private(set) var running = false
    @Published private(set) var busy = false
    @Published var message = ""
    @Published private(set) var library = ProxyProfileLibrary()
    private var ports: [String: Int] = [:]
    private let queue = DispatchQueue(label: "io.picharbor.proxy-core", qos: .utility)
    private var starting: Task<Void, Error>?
    private let readStore: () throws -> Data?
    private let writeStore: (Data) throws -> Void
    private let testStart: ((String) -> Bool)?
    private let testStop: (() -> Void)?
    private let defaults: UserDefaults
    private var home: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PicHarbor/Proxy").path
    }
    init(read: @escaping () throws -> Data? = ProxySecretStore.read,
         save: @escaping (Data) throws -> Void = ProxySecretStore.save,
         start: ((String) -> Bool)? = nil, stop: (() -> Void)? = nil, defaults: UserDefaults = .standard) {
        readStore = read; writeStore = save; testStart = start; testStop = stop
        self.defaults = defaults
        preferences = defaults.data(forKey: "picharbor.proxy.preferences.v1").flatMap { try? JSONDecoder().decode(ProxyPreferences.self, from: $0) } ?? ProxyPreferences()
        if let data = try? readStore(), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let stored = object["library"], let encoded = try? JSONSerialization.data(withJSONObject: stored),
               let decoded = try? JSONDecoder().decode(ProxyProfileLibrary.self, from: encoded) { library = decoded }
            if let nodes = try? ProxyConfiguration.nodes(object) {
                names = nodes.compactMap { $0["name"] as? String }
                if library.profiles.isEmpty, let encoded = try? JSONSerialization.data(withJSONObject: nodes) {
                    let legacy = ProxyProfile(name: L10n.text("原有配置"), nodes: encoded, primary: preferences.primary, backups: preferences.backups, updatedAt: Date())
                    library = ProxyProfileLibrary(profiles: [legacy], activeID: legacy.id)
                }
            }
        }
    }
    private func capturedLibrary() -> ProxyProfileLibrary {
        var copy = library
        if let index = copy.profiles.firstIndex(where: { $0.id == copy.activeID }) {
            copy.profiles[index].primary = preferences.primary; copy.profiles[index].backups = preferences.backups
        }
        return copy
    }
    private func encodedLibrary(_ value: ProxyProfileLibrary) throws -> Data {
        let nodes = try value.profiles.first(where: { $0.id == value.activeID }).map { try JSONSerialization.jsonObject(with: $0.nodes) } ?? []
        return try JSONSerialization.data(withJSONObject: ["proxies": nodes, "library": JSONSerialization.jsonObject(with: JSONEncoder().encode(value))])
    }
    private func startCore(_ configuration: String) async -> Bool {
        if let testStart { return testStart(configuration) }
        let path = home
        return await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: ProxyCoreBridge.start(configuration, home: path)) } }
    }
    private func stopCore() async {
        if let testStop { testStop(); return }
        await withCheckedContinuation { continuation in queue.async { ProxyCoreBridge.stop(); continuation.resume() } }
    }
    // Validate the candidate before committing a single Keychain envelope. Restore the
    // previous runtime on every failure; never publish stale names as a working core.
    private func commit(_ proposed: ProxyProfileLibrary, validating nodes: [[String: Any]]) async throws {
        if let starting { try await starting.value }
        let previous = capturedLibrary(), wasRunning = running
        let previousNodes = try previous.profiles.first(where: { $0.id == previous.activeID }).map { try JSONSerialization.jsonObject(with: $0.nodes) as? [[String: Any]] ?? [] } ?? []
        let oldConfiguration = previousNodes.isEmpty ? nil : try ProxyConfiguration.runtime(previousNodes).0
        let candidate = try ProxyConfiguration.runtime(nodes).0
        do {
            guard await startCore(candidate) else { throw HarborError("PROXY_START_FAILED") }
            let active = proposed.profiles.first { $0.id == proposed.activeID }
            let activeNodes = try active.map { try JSONSerialization.jsonObject(with: $0.nodes) as? [[String: Any]] ?? [] } ?? []
            var activePorts: [String: Int] = [:]
            if !activeNodes.isEmpty {
                let (configuration, mapping) = try ProxyConfiguration.runtime(activeNodes); activePorts = mapping
                if configuration != candidate, preferences.enabled {
                    guard await startCore(configuration) else { throw HarborError("PROXY_START_FAILED") }
                }
            }
            if !preferences.enabled || activeNodes.isEmpty { await stopCore() }
            try writeStore(encodedLibrary(proposed))
            library = proposed; ports = activePorts; names = activeNodes.compactMap { $0["name"] as? String }
            preferences.primary = active.flatMap { names.contains($0.primary) ? $0.primary : nil } ?? names.first ?? ""
            preferences.backups = active?.backups.filter { names.contains($0) && $0 != preferences.primary } ?? []
            running = preferences.enabled && !activeNodes.isEmpty
        } catch {
            if wasRunning, let oldConfiguration { running = await startCore(oldConfiguration) }
            else { await stopCore(); running = false }
            if wasRunning && !running { message = L10n.text("旧配置未能重新启动，请重新测试连接。") }
            throw error
        }
    }
    func importText(_ text: String, profileID: String? = nil, name: String = "", subscriptionURL: String? = nil) async throws {
        guard !busy, text.utf8.count <= 4 * 1024 * 1024 else { throw HarborError("PROXY_CONFIG_UNSUPPORTED") }
        busy = true; defer { busy = false }
        let path = home
        let json: String? = await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: ProxyCoreBridge.parse(text, home: path)) } }
        guard let json, let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              (object["proxy-providers"] as? [String: Any] ?? [:]).isEmpty else { throw HarborError("PROXY_CONFIG_UNSUPPORTED") }
        let nodes = try ProxyConfiguration.nodes(object)
        var proposed = capturedLibrary()
        let existing = proposed.profiles.first { $0.id == profileID }
        let data = try JSONSerialization.data(withJSONObject: nodes)
        let changes = try ProxyNodeChanges.compare(old: existing?.nodes, new: data)
        let summary = L10n.text("{0} 个节点 · 新增 {1}，修改 {2}，移除 {3}", [String(nodes.count), String(changes.added), String(changes.modified), String(changes.removed)])
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var profile = existing ?? ProxyProfile(name: trimmedName.isEmpty ? L10n.text("本地配置") : trimmedName, nodes: data, primary: "", backups: [], updatedAt: Date())
        if !trimmedName.isEmpty { profile.name = trimmedName }
        profile.nodes = data; profile.updatedAt = Date(); profile.lastResult = summary; profile.lastError = nil
        if let subscriptionURL { profile.subscriptionURL = try ProxySubscription.url(subscriptionURL).absoluteString }
        if let index = proposed.profiles.firstIndex(where: { $0.id == profile.id }) { proposed.profiles[index] = profile }
        else {
            guard proposed.profiles.count < 20 else { throw HarborError("PROXY_PROFILE_LIMIT") }
            proposed.profiles.append(profile); proposed.activeID = profile.id
        }
        try await commit(proposed, validating: nodes)
        message = L10n.text("更新成功：{0}", [summary])
    }
    func activateProfile(_ id: String) async throws {
        guard !busy, let profile = library.profiles.first(where: { $0.id == id }) else { throw HarborError("PROXY_UNAVAILABLE") }
        busy = true; defer { busy = false }
        var proposed = capturedLibrary(); proposed.activeID = id
        let nodes = try JSONSerialization.jsonObject(with: profile.nodes) as? [[String: Any]] ?? []
        try await commit(proposed, validating: nodes)
        message = L10n.text("配置已切换。")
    }
    func editProfile(_ id: String, name: String, address: String?) throws {
        guard !busy else { throw HarborError("PROXY_UNAVAILABLE") }
        var proposed = capturedLibrary()
        guard let index = proposed.profiles.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { proposed.profiles[index].name = trimmed }
        if let address { proposed.profiles[index].subscriptionURL = try ProxySubscription.url(address).absoluteString }
        try writeStore(encodedLibrary(proposed)); library = proposed
    }
    func recordProfileFailure(_ id: String, message: String) {
        guard !busy else { return }
        var proposed = capturedLibrary()
        guard let index = proposed.profiles.firstIndex(where: { $0.id == id }) else { return }
        proposed.profiles[index].lastError = message
        do { try writeStore(encodedLibrary(proposed)); library = proposed }
        catch { self.message = L10n.text("未能保存更新记录。") }
    }
    func removeProfile(_ id: String) async throws {
        guard !busy else { throw HarborError("PROXY_UNAVAILABLE") }
        busy = true; defer { busy = false }
        var proposed = capturedLibrary(); proposed.profiles.removeAll { $0.id == id }
        if proposed.activeID == id {
            // Never switch silently to a different subscription.
            proposed.activeID = nil
            try writeStore(encodedLibrary(proposed))
            await stopCore(); running = false; ports = [:]; names = []
            preferences.primary = ""; preferences.backups = []; preferences.enabled = false
        } else { try writeStore(encodedLibrary(proposed)) }
        library = proposed; message = L10n.text("配置已移除。")
    }
    func stop() async {
        if let starting { _ = try? await starting.value }
        await stopCore()
        running = false
    }
    func ensureRunning() async throws {
        if running { return }
        if let starting { return try await starting.value }
        let operation = Task { @MainActor in
            guard let data = try readStore(), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HarborError("PROXY_CONFIG_REQUIRED") }
            let nodes = try ProxyConfiguration.nodes(object)
            let (configuration, newPorts) = try ProxyConfiguration.runtime(nodes)
            let succeeded = await startCore(configuration)
            guard succeeded else { throw HarborError("PROXY_START_FAILED") }
            ports = newPorts; running = true
        }
        starting = operation; defer { starting = nil }
        try await operation.value
    }
    func route(override: ProxyFallback? = nil, failures: [String] = []) async throws -> (Int, String) {
        guard preferences.enabled else { return (-1, "") }
        guard !busy else { throw HarborError("PROXY_UNAVAILABLE") }
        try await ensureRunning()
        for name in ProxyConfiguration.candidates(preferences, override: override, failures: failures) {
            if name.isEmpty { return (-1, "") }
            guard let port = ports[name] else { continue }
            if await probe(port: port) { return (port, name) }
        }
        throw HarborError("PROXY_UNAVAILABLE")
    }
    func probe(port: Int) async -> Bool {
        await latency(port: port) != nil
    }
    func testPrimaryLatency() async throws -> (String, Int) {
        guard !busy else { throw HarborError("PROXY_UNAVAILABLE") }
        try await ensureRunning()
        guard let port = ports[preferences.primary], let milliseconds = await latency(port: port) else { throw HarborError("PROXY_UNAVAILABLE") }
        return (preferences.primary, milliseconds)
    }
    private func latency(port: Int) async -> Int? {
        let configuration = URLSessionConfiguration.ephemeral
        Self.apply(port: port, to: configuration)
        configuration.timeoutIntervalForRequest = 6; configuration.timeoutIntervalForResource = 8
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        let started = ContinuousClock.now
        do {
            let (_, response) = try await session.data(from: URL(string: "https://www.gstatic.com/generate_204")!)
            guard (response as? HTTPURLResponse)?.statusCode == 204 else { return nil }
            let elapsed = started.duration(to: .now).components
            return max(1, Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000))
        } catch { return nil }
    }
    nonisolated static func apply(port: Int, to configuration: URLSessionConfiguration) {
        guard port > 0 else { return }
        let proxy = ProxyConfigurationForPort.make(port)
        configuration.proxyConfigurations = [proxy]
    }
    func portForPrimary() -> Int? { preferences.enabled ? ports[preferences.primary] : nil }
}

enum ProxyConfigurationForPort {
    static func make(_ port: Int) -> Network.ProxyConfiguration {
        var proxy = Network.ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(port))!), tlsOptions: nil)
        proxy.allowFailover = false
        return proxy
    }
}
