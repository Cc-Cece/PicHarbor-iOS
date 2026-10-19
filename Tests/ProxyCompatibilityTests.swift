import XCTest
@testable import PicHarbor

final class ProxyCompatibilityTests: XCTestCase {
    func testRuntimeDoesNotEscapeSlashesForTheSDKYAMLDecoder() throws {
        let node: [String: Any] = ["name": "test/anytls", "type": "anytls", "server": "127.0.0.1", "port": 9,
                                   "password": "synthetic/password", "sni": "example.invalid", "alpn": ["h2", "http/1.1"], "client-fingerprint": "chrome"]
        let (text, _) = try ProxyConfiguration.runtime([node])
        XCTAssertFalse(text.contains("\\/"))
        XCTAssertTrue(text.contains("http/1.1"))
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(ProxyCoreBridge.start(text, home: home.path), ProxyCoreBridge.failureMessage())
        ProxyCoreBridge.stop()
    }
    func testInformationNamesAreHiddenOnlyWhenTheyDuplicateAnActualNode() throws {
        let actual: [String: Any] = ["name": "real", "type": "socks5", "server": "127.0.0.1", "port": 9]
        var info = actual; info["name"] = "剩余流量：100 GB"
        var unique = actual; unique["name"] = "套餐到期：example"; unique["port"] = 10
        let result = try ProxyNodePreparation.splitInformation([info, actual, unique])
        XCTAssertEqual(result.nodes.count, 2)
        XCTAssertEqual(result.information, ["剩余流量：100 GB"])
        XCTAssertEqual(result.nodes.first?["name"] as? String, "real")
    }
    @MainActor func testUnsupportedNodeIsRetainedAndCanRecoverOnRecheck() async throws {
        let suite = "ProxyCompatibility." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var stored: Data?, allowSecond = false
        let manager = ProxyManager(read: { stored }, save: { stored = $0 }, start: { text in
            let configuration = try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
            let nodes = configuration["proxies"] as! [[String: Any]]
            return allowSecond || !nodes.contains { $0["port"] as? Int == 10 }
        }, stop: {}, defaults: defaults)
        let nodes: [[String: Any]] = [["name": "a", "type": "socks5", "server": "127.0.0.1", "port": 9],
                                     ["name": "b", "type": "socks5", "server": "127.0.0.1", "port": 10]]
        let data = try JSONSerialization.data(withJSONObject: ["proxies": nodes])
        try await manager.importText(String(decoding: data, as: UTF8.self))
        let profile = try XCTUnwrap(manager.library.profiles.first)
        XCTAssertEqual(manager.names, ["a"]); XCTAssertEqual(profile.issues?.map(\.name), ["b"])
        XCTAssertEqual((try JSONSerialization.jsonObject(with: XCTUnwrap(profile.sourceNodes)) as? [[String: Any]])?.count, 2)
        allowSecond = true
        try await manager.importText(String(decoding: data, as: UTF8.self), profileID: profile.id)
        XCTAssertEqual(manager.names, ["a", "b"]); XCTAssertEqual(manager.library.profiles.first?.issues?.count, 0)
    }
}
