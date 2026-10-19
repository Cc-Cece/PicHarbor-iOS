import Foundation

struct ProxyProfile: Codable, Identifiable {
    var id = UUID().uuidString
    var name: String
    var subscriptionURL: String?
    var nodes: Data
    var primary: String
    var backups: [String]
    var updatedAt: Date
    var lastResult: String = ""
    var lastError: String?
    var nodeCount: Int { (try? JSONSerialization.jsonObject(with: nodes) as? [[String: Any]])?.count ?? 0 }
}

struct ProxyProfileLibrary: Codable {
    var profiles: [ProxyProfile] = []
    var activeID: String?
}

struct ProxyNodeChanges {
    let added: Int
    let modified: Int
    let removed: Int
    static func compare(old: Data?, new: Data) throws -> Self {
        func index(_ data: Data?) throws -> [String: Data] {
            guard let data else { return [:] }
            let nodes = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
            var result: [String: Data] = [:]
            for node in nodes {
                if let name = node["name"] as? String { result[name] = try JSONSerialization.data(withJSONObject: node, options: [.sortedKeys]) }
            }
            return result
        }
        let before = try index(old), after = try index(new)
        return Self(added: after.keys.filter { before[$0] == nil }.count,
                    modified: after.keys.filter { before[$0] != nil && before[$0] != after[$0] }.count,
                    removed: before.keys.filter { after[$0] == nil }.count)
    }
}

enum ProxySubscription {
    static func url(_ address: String) throws -> URL {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { throw HarborError("PROXY_SUBSCRIPTION_URL") }
        return url
    }
    // This runs outside the UI actor; byte-by-byte download must not block SwiftUI.
    nonisolated static func download(_ url: URL, port: Int) async throws -> String {
        let configuration = URLSessionConfiguration.ephemeral
        ProxyManager.apply(port: port, to: configuration)
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("Clash/PicHarbor", forHTTPHeaderField: "User-Agent")
        request.setValue("application/yaml, text/yaml, application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw HarborError("PROXY_SUBSCRIPTION_DOWNLOAD") }
        guard response.expectedContentLength <= 4 * 1024 * 1024 else { throw HarborError("PROXY_CONFIG_UNSUPPORTED") }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 4 * 1024 * 1024 else { throw HarborError("PROXY_CONFIG_UNSUPPORTED") }
            data.append(byte)
        }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else { throw HarborError("PROXY_CONFIG_UNSUPPORTED") }
        return text
    }
}
