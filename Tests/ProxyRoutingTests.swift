import XCTest
import Darwin
@testable import PicHarbor

final class ProxyRoutingTests: XCTestCase {
    private let node: [String: Any] = ["name": "local-test", "type": "socks5", "server": "127.0.0.1", "port": 9]
    func testRuntimeOwnsListenersAndNeverImportsSystemRouting() throws {
        let input: [String: Any] = ["proxies": [node], "tun": ["enable": true], "external-controller": "0.0.0.0:9090", "rules": ["MATCH,DIRECT"]]
        let nodes = try ProxyConfiguration.nodes(input)
        let (json, ports) = try ProxyConfiguration.runtime(nodes)
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual((value["tun"] as? [String: Bool])?["enable"], false)
        XCTAssertEqual(value["rules"] as? [String], ["MATCH,REJECT"])
        XCTAssertEqual(value["external-controller"] as? String, "")
        let listener = try XCTUnwrap((value["listeners"] as? [[String: Any]])?.first)
        XCTAssertEqual(listener["listen"] as? String, "127.0.0.1")
        XCTAssertEqual(listener["proxy"] as? String, "local-test")
        XCTAssertEqual(ports["local-test"], 24500)
    }
    func testInvalidNodesAreNotSilentlyAccepted() {
        var chain = node; chain["dialer-proxy"] = "other"
        XCTAssertThrowsError(try ProxyConfiguration.nodes(["proxies": [node, node]]))
        XCTAssertThrowsError(try ProxyConfiguration.nodes(["proxies": [chain]]))
        var direct = node; direct["type"] = "direct"
        XCTAssertThrowsError(try ProxyConfiguration.nodes(["proxies": [direct]]))
        XCTAssertThrowsError(try ProxyConfiguration.nodes(["proxies": []]))
    }
    func testFallbackRequiresExplicitDirectPermissionAndTaskOverridesGlobal() {
        var preferences = ProxyPreferences(); preferences.enabled = true; preferences.primary = "a"; preferences.backups = ["b"]
        XCTAssertEqual(ProxyConfiguration.candidates(preferences, override: nil, failures: []), ["a"])
        XCTAssertEqual(ProxyConfiguration.candidates(preferences, override: .nodes, failures: ["a"]), ["b"])
        XCTAssertEqual(ProxyConfiguration.candidates(preferences, override: .direct, failures: ["a", "b"]), [""])
        XCTAssertEqual(ProxyConfiguration.candidates(preferences, override: .nodes, failures: ["a", "b"]), [])
        preferences.fallback = .direct
        XCTAssertEqual(ProxyConfiguration.candidates(preferences, override: .wait, failures: []), ["a"])
        XCTAssertEqual(preferences.fallback, .direct)
    }
    func testProxyTransferIdentifiersCannotCollideAcrossRoutes() {
        let first = URLSession(configuration: .ephemeral), second = URLSession(configuration: .ephemeral)
        defer { first.invalidateAndCancel(); second.invalidateAndCancel() }
        let url = URL(string: "https://example.invalid")!
        let a = first.dataTask(with: url), b = second.dataTask(with: url)
        XCTAssertEqual(a.taskIdentifier, b.taskIdentifier)
        XCTAssertNotEqual(HarborTransferTask(a, port: 24500).taskIdentifier, HarborTransferTask(b, port: 24501).taskIdentifier)
        XCTAssertNotEqual(HarborTransferTask(a).taskIdentifier, HarborTransferTask(a, port: 24500).taskIdentifier)
    }
    func testNodeCoreStartsWithoutNetworkExtension() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("proxy-test-" + UUID().uuidString)
        let (json, _) = try ProxyConfiguration.runtime([node])
        XCTAssertTrue(ProxyCoreBridge.start(json, home: home.path))
        defer { ProxyCoreBridge.stop() }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(descriptor, 0); defer { Darwin.close(descriptor) }
        var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = UInt16(24500).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        XCTAssertEqual(result, 0, "The core must expose the loopback listener, not merely report startup success")
    }
    func testTaskPolicyAndConnectionStateSurviveSerialization() throws {
        var job = BackupJob(account: "test@example.com", assetID: "asset", assetRevision: "revision", settings: BackupSettings())
        job.proxyFallback = .nodes; job.proxyPort = 24501; job.proxyLastNode = "b"; job.proxyFailures = ["a"]
        let saved = try JSONDecoder().decode(BackupJob.self, from: JSONEncoder().encode(job))
        XCTAssertEqual(saved.proxyFallback, .nodes); XCTAssertEqual(saved.proxyPort, 24501)
        XCTAssertEqual(saved.proxyFailures, ["a"])
        XCTAssertEqual(saved.account, job.account)
    }
}
