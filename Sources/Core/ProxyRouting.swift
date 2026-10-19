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
    var selection: ProxySelection?
    var exhaustion: ProxyExhaustion?
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
        // The SDK reads this JSON through its YAML decoder, which rejects JSON's
        // optional escaped slash (e.g. ALPN "http\/1.1"). Preserve plain slashes.
        return (String(decoding: try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys, .withoutEscapingSlashes]), as: UTF8.self), ports)
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
    @Published private(set) var health: [String: ProxyNodeHealth] = [:]
    @Published private(set) var testing = false
    @Published private(set) var testedCount = 0
    @Published private(set) var testTotal = 0
    @Published private(set) var currentNode = ""
    @Published private(set) var currentDirect = false
    private var generation = UUID()
    private var automaticNode = ""
    private var sweep: Task<Void, Error>?
    private var probes: [String: Task<Int?, Never>] = [:]
    private let probeLimiter = ProxyProbeLimiter()
    var routingScope: String { generation.uuidString }
    private var ports: [String: Int] = [:]
    private let queue = DispatchQueue(label: "io.picharbor.proxy-core", qos: .utility)
    private var starting: Task<Void, Error>?
    private let readStore: () throws -> Data?
    private let writeStore: (Data) throws -> Void
    private let testStart: ((String) -> Bool)?
    private let testStop: (() -> Void)?
    private let defaults: UserDefaults
    private let testLatency: ((Int) async -> Int?)?
    private var home: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PicHarbor/Proxy").path
    }
    init(read: @escaping () throws -> Data? = ProxySecretStore.read,
         save: @escaping (Data) throws -> Void = ProxySecretStore.save,
         start: ((String) -> Bool)? = nil, stop: (() -> Void)? = nil, defaults: UserDefaults = .standard,
         latency: ((Int) async -> Int?)? = nil) {
        readStore = read; writeStore = save; testStart = start; testStop = stop
        self.defaults = defaults
        testLatency = latency
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
    private func startupError() -> HarborError {
        HarborError("PROXY_START_FAILED", detail: testStart == nil ? ProxyCoreBridge.failureMessage() : nil)
    }
    private func compatibleNodes(_ nodes: [[String: Any]]) async throws -> ([[String: Any]], [ProxyNodeIssue]) {
        if let starting { try await starting.value }
        let previous = capturedLibrary(), wasRunning = running
        let oldNodes = try previous.profiles.first(where: { $0.id == previous.activeID }).map { try JSONSerialization.jsonObject(with: $0.nodes) as? [[String: Any]] ?? [] } ?? []
        var accepted: [[String: Any]] = [], issues: [ProxyNodeIssue] = []
        if await startCore(try ProxyConfiguration.runtime(nodes).0) { accepted = nodes }
        else {
            for node in nodes {
                if await startCore(try ProxyConfiguration.runtime([node]).0) { accepted.append(node) }
                else {
                    issues.append(ProxyNodeIssue(name: node["name"] as? String ?? "", kind: node["type"] as? String ?? "", reason: startupError().localizedDescription))
                }
            }
        }
        if wasRunning, !oldNodes.isEmpty {
            running = await startCore(try ProxyConfiguration.runtime(oldNodes).0)
            guard running else { message = L10n.text("旧配置未能重新启动，请重新测试连接。"); throw startupError() }
        } else { await stopCore(); running = false }
        guard !accepted.isEmpty else {
            throw HarborError("PROXY_START_FAILED", detail: issues.first?.reason)
        }
        return (accepted, issues)
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
            guard await startCore(candidate) else { throw startupError() }
            let active = proposed.profiles.first { $0.id == proposed.activeID }
            let activeNodes = try active.map { try JSONSerialization.jsonObject(with: $0.nodes) as? [[String: Any]] ?? [] } ?? []
            var activePorts: [String: Int] = [:]
            if !activeNodes.isEmpty {
                let (configuration, mapping) = try ProxyConfiguration.runtime(activeNodes); activePorts = mapping
                if configuration != candidate, preferences.enabled {
                    guard await startCore(configuration) else { throw startupError() }
                }
            }
            if !preferences.enabled || activeNodes.isEmpty { await stopCore() }
            try writeStore(encodedLibrary(proposed))
            if previous.activeID != proposed.activeID || previous.profiles.first(where: { $0.id == previous.activeID })?.nodes != active?.nodes {
                generation = UUID(); health = [:]; currentNode = ""; currentDirect = false; automaticNode = ""
            }
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
        guard !busy, !testing, text.utf8.count <= 4 * 1024 * 1024 else { throw HarborError("PROXY_CONFIG_UNSUPPORTED") }
        busy = true; defer { busy = false }
        let object: [String: Any]
        if let json = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] { object = json }
        else {
            let path = home
            let json: String? = await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: ProxyCoreBridge.parse(text, home: path)) } }
            guard let json, let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { throw HarborError("PROXY_CONFIG_UNSUPPORTED") }
            object = parsed
        }
        guard (object["proxy-providers"] as? [String: Any] ?? [:]).isEmpty else { throw HarborError("PROXY_CONFIG_UNSUPPORTED") }
        if (object["proxies"] as? [Any])?.isEmpty == true { throw HarborError("PROXY_EMPTY_SUBSCRIPTION") }
        let originalNodes = try ProxyConfiguration.nodes(object)
        let prepared = try ProxyNodePreparation.splitInformation(originalNodes)
        let (nodes, issues) = try await compatibleNodes(prepared.nodes)
        var proposed = capturedLibrary()
        let existing = proposed.profiles.first { $0.id == profileID }
        let data = try JSONSerialization.data(withJSONObject: nodes)
        let source = try JSONSerialization.data(withJSONObject: originalNodes)
        let changes = try ProxyNodeChanges.compare(old: existing?.nodes, new: data)
        let summary = L10n.text("{0} 个节点 · 新增 {1}，修改 {2}，移除 {3}", [String(nodes.count), String(changes.added), String(changes.modified), String(changes.removed)])
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var profile = existing ?? ProxyProfile(name: trimmedName.isEmpty ? L10n.text("本地配置") : trimmedName, nodes: data, primary: "", backups: [], updatedAt: Date())
        if !trimmedName.isEmpty { profile.name = trimmedName }
        profile.nodes = data; profile.updatedAt = Date(); profile.lastResult = summary; profile.lastError = nil
        profile.sourceNodes = source; profile.issues = issues; profile.information = prepared.information
        if !issues.isEmpty {
            profile.lastResult = L10n.text("可用 {0} 个，暂不可用 {1} 个。未通过的节点已保留，可重新检查。", [String(nodes.count), String(issues.count)]) + "\n" + summary
        }
        if let subscriptionURL { profile.subscriptionURL = try ProxySubscription.url(subscriptionURL).absoluteString }
        if let index = proposed.profiles.firstIndex(where: { $0.id == profile.id }) { proposed.profiles[index] = profile }
        else {
            guard proposed.profiles.count < 20 else { throw HarborError("PROXY_PROFILE_LIMIT") }
            proposed.profiles.append(profile); proposed.activeID = profile.id
        }
        try await commit(proposed, validating: nodes)
        message = L10n.text("更新成功：{0}", [profile.lastResult])
    }
    func activateProfile(_ id: String) async throws {
        guard !busy, !testing, let profile = library.profiles.first(where: { $0.id == id }) else { throw HarborError("PROXY_UNAVAILABLE") }
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
        guard !busy, !testing else { throw HarborError("PROXY_UNAVAILABLE") }
        busy = true; defer { busy = false }
        var proposed = capturedLibrary(); proposed.profiles.removeAll { $0.id == id }
        if proposed.activeID == id {
            // Never switch silently to a different subscription.
            proposed.activeID = nil
            try writeStore(encodedLibrary(proposed))
            await stopCore(); running = false; ports = [:]; names = []; generation = UUID(); health = [:]; currentNode = ""; currentDirect = false
            preferences.primary = ""; preferences.backups = []; preferences.enabled = false
        } else { try writeStore(encodedLibrary(proposed)) }
        library = proposed; message = L10n.text("配置已移除。")
    }
    func stop() async {
        if let starting { _ = try? await starting.value }
        await stopCore()
        running = false; currentNode = ""; currentDirect = false
    }
    func ensureRunning() async throws {
        if running { return }
        if let starting { return try await starting.value }
        let operation = Task { @MainActor in
            guard let data = try readStore(), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HarborError("PROXY_CONFIG_REQUIRED") }
            let nodes = try ProxyConfiguration.nodes(object)
            let (configuration, newPorts) = try ProxyConfiguration.runtime(nodes)
            let succeeded = await startCore(configuration)
            guard succeeded else { throw startupError() }
            ports = newPorts; running = true
        }
        starting = operation; defer { starting = nil }
        try await operation.value
    }
    func route(override legacy: ProxyFallback? = nil, failures: [String] = [], policy custom: ProxyPolicy? = nil, preferred: String? = nil) async throws -> (Int, String) {
        guard preferences.enabled else { return (-1, "") }
        guard !busy else { throw HarborError("PROXY_UNAVAILABLE") }
        try await ensureRunning()
        let policy = ProxyPolicy.resolve(preferences, legacy: legacy, override: custom)
        let token = generation
        let sticky = preferred ?? (custom == nil && legacy == nil ? automaticNode : nil)
        var candidates: [String]
        if policy.selection == .automatic {
            if let sticky, names.contains(sticky), !failures.contains(sticky),
               health[sticky]?.healthy(at: Date()) != true, !(health[sticky]?.cooling(at: Date()) ?? false),
               let port = ports[sticky] { _ = await measureNode(sticky, port: port) }
            var ranked = ProxyNodeRanking.ordered(names: names, health: health, preferred: sticky, failures: failures, now: Date())
            if !ranked.contains(where: { health[$0]?.healthy(at: Date()) == true }) {
                try await testAllNodes(force: false)
                ranked = ProxyNodeRanking.ordered(names: names, health: health, preferred: sticky, failures: failures, now: Date())
            }
            candidates = ranked
        } else {
            var seen = Set<String>()
            candidates = ([policy.primary] + policy.backups).filter { names.contains($0) && seen.insert($0).inserted && !failures.contains($0) && !(health[$0]?.cooling(at: Date()) ?? false) }
        }
        for name in candidates {
            try Task.checkCancellation()
            guard token == generation, preferences.enabled, !busy else { throw HarborError("PROXY_UNAVAILABLE") }
            guard let port = ports[name] else { continue }
            let healthy = health[name]?.healthy(at: Date()) == true
            let available = healthy ? true : await measureNode(name, port: port) != nil
            guard token == generation, preferences.enabled, !busy else { throw HarborError("PROXY_UNAVAILABLE") }
            if (available || health[name]?.healthy(at: Date()) == true) && !(health[name]?.cooling(at: Date()) ?? false) {
                currentNode = name; currentDirect = false
                if policy.selection == .automatic && custom == nil && legacy == nil { automaticNode = name }
                return (port, name)
            }
        }
        try Task.checkCancellation()
        guard token == generation else { throw HarborError("PROXY_UNAVAILABLE") }
        if policy.exhaustion == .direct && !failures.contains("") { currentNode = ""; currentDirect = true; return (-1, "") }
        throw HarborError("PROXY_UNAVAILABLE")
    }
    func recordOutcome(node: String?, errorCode: String?, scope: String? = nil) {
        if let scope, scope != routingScope { return }
        guard let node, names.contains(node) else { return }
        var value = health[node] ?? ProxyNodeHealth()
        if errorCode == nil { value.succeed(at: Date()) }
        else if errorCode == "NETWORK_ERROR" { value.fail(at: Date()) }
        else { return }
        health[node] = value
    }
    private func measureNode(_ name: String, port: Int) async -> Int? {
        if let existing = probes[name] { return await existing.value }
        let token = generation, began = Date(), injected = testLatency
        let operation = Task<Int?, Never> {
            await probeLimiter.acquire()
            let result: Int?
            if let injected { result = await injected(port) }
            else { result = await Self.latency(port: port) }
            await probeLimiter.release()
            return result
        }
        probes[name] = operation
        let milliseconds = await operation.value
        guard generation == token else { return nil }
        probes.removeValue(forKey: name)
        var value = health[name] ?? ProxyNodeHealth()
        value.recordMeasurement(milliseconds, began: began, now: Date())
        health[name] = value
        return milliseconds
    }
    func testAllNodes(force: Bool = true, only: String? = nil) async throws {
        if let sweep { return try await sweep.value }
        guard !busy else { throw HarborError("PROXY_UNAVAILABLE") }
        testing = true; testedCount = 0
        let operation = Task { @MainActor in
            try await ensureRunning()
            let token = generation
            let targets = names.filter { (only == nil || only == $0) && (force || !(health[$0]?.cooling(at: Date()) ?? false)) }.compactMap { name in ports[name].map { (name, $0) } }
            testTotal = targets.count
            await withTaskGroup(of: Void.self) { group in
                var index = 0
                for _ in 0..<min(3, targets.count) {
                    let target = targets[index]; index += 1
                    group.addTask { _ = await self.measureNode(target.0, port: target.1) }
                }
                while await group.next() != nil {
                    if token == generation { testedCount += 1 }
                    if Task.isCancelled { group.cancelAll(); continue }
                    if index < targets.count {
                        let target = targets[index]; index += 1
                        group.addTask { _ = await self.measureNode(target.0, port: target.1) }
                    }
                }
            }
            try Task.checkCancellation()
        }
        sweep = operation
        defer { sweep = nil; testing = false }
        do { try await operation.value }
        catch {
            if !preferences.enabled { await stopCore(); running = false }
            throw error
        }
        if !preferences.enabled { await stopCore(); running = false }
    }
    func stopTesting() { sweep?.cancel() }
    func retestNode(_ name: String) async throws {
        guard names.contains(name) else { throw HarborError("PROXY_UNAVAILABLE") }
        try await testAllNodes(only: name)
    }
    func probe(port: Int) async -> Bool { await Self.latency(port: port) != nil }
    func testPrimaryLatency() async throws -> (String, Int) {
        guard !busy else { throw HarborError("PROXY_UNAVAILABLE") }
        try await ensureRunning()
        guard let port = ports[preferences.primary], let milliseconds = await measureNode(preferences.primary, port: port) else { throw HarborError("PROXY_UNAVAILABLE") }
        return (preferences.primary, milliseconds)
    }
    private nonisolated static func latency(port: Int) async -> Int? {
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
