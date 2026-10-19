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
        didSet { if let data = try? JSONEncoder().encode(preferences) { UserDefaults.standard.set(data, forKey: "picharbor.proxy.preferences.v1") } }
    }
    @Published private(set) var names: [String] = []
    @Published private(set) var running = false
    @Published private(set) var busy = false
    @Published var message = ""
    private var ports: [String: Int] = [:]
    private let queue = DispatchQueue(label: "io.picharbor.proxy-core", qos: .utility)
    private var starting: Task<Void, Error>?
    private var home: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PicHarbor/Proxy").path
    }
    init() {
        preferences = UserDefaults.standard.data(forKey: "picharbor.proxy.preferences.v1").flatMap { try? JSONDecoder().decode(ProxyPreferences.self, from: $0) } ?? ProxyPreferences()
        if let data = try? ProxySecretStore.read(), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let nodes = try? ProxyConfiguration.nodes(object) { names = nodes.compactMap { $0["name"] as? String } }
    }
    func importText(_ text: String) async throws {
        guard !busy, text.utf8.count <= 4 * 1024 * 1024 else { throw HarborError("PROXY_CONFIG_UNSUPPORTED") }
        busy = true; defer { busy = false }
        let path = home
        let json: String? = await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: ProxyCoreBridge.parse(text, home: path)) } }
        guard let json, let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              (object["proxy-providers"] as? [String: Any] ?? [:]).isEmpty else { throw HarborError("PROXY_CONFIG_UNSUPPORTED") }
        let nodes = try ProxyConfiguration.nodes(object)
        let (configuration, newPorts) = try ProxyConfiguration.runtime(nodes)
        let succeeded = await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: ProxyCoreBridge.start(configuration, home: path)) } }
        running = succeeded
        guard succeeded else { throw HarborError("PROXY_START_FAILED") }
        // Persist only the validated node list, never the imported system routing.
        try ProxySecretStore.save(try JSONSerialization.data(withJSONObject: ["proxies": nodes]))
        ports = newPorts; names = nodes.compactMap { $0["name"] as? String }
        if !names.contains(preferences.primary) { preferences.primary = names.first ?? "" }
        preferences.backups = preferences.backups.filter { names.contains($0) }
        message = L10n.text("配置已导入，节点已就绪。")
    }
    func ensureRunning() async throws {
        if running { return }
        if let starting { return try await starting.value }
        let operation = Task { @MainActor in
            guard let data = try ProxySecretStore.read(), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HarborError("PROXY_CONFIG_REQUIRED") }
            let nodes = try ProxyConfiguration.nodes(object)
            let (configuration, newPorts) = try ProxyConfiguration.runtime(nodes); let path = home
            let succeeded = await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: ProxyCoreBridge.start(configuration, home: path)) } }
            guard succeeded else { throw HarborError("PROXY_START_FAILED") }
            ports = newPorts; running = true
        }
        starting = operation; defer { starting = nil }
        try await operation.value
    }
    func route(override: ProxyFallback? = nil, failures: [String] = []) async throws -> (Int, String) {
        guard preferences.enabled else { return (-1, "") }
        try await ensureRunning()
        for name in ProxyConfiguration.candidates(preferences, override: override, failures: failures) {
            if name.isEmpty { return (-1, "") }
            guard let port = ports[name] else { continue }
            if await probe(port: port) { return (port, name) }
        }
        throw HarborError("PROXY_UNAVAILABLE")
    }
    func probe(port: Int) async -> Bool {
        let configuration = URLSessionConfiguration.ephemeral
        Self.apply(port: port, to: configuration)
        configuration.timeoutIntervalForRequest = 6; configuration.timeoutIntervalForResource = 8
        let session = URLSession(configuration: configuration); defer { session.invalidateAndCancel() }
        do {
            let (_, response) = try await session.data(from: URL(string: "https://www.gstatic.com/generate_204")!)
            return (response as? HTTPURLResponse)?.statusCode == 204
        } catch { return false }
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
