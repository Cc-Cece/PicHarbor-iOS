import XCTest
@testable import PicHarbor

final class ProxyProfileTests: XCTestCase {
    private func nodes(_ port: Int, name: String = "node") throws -> Data {
        try JSONSerialization.data(withJSONObject: [["name": name, "type": "socks5", "server": "127.0.0.1", "port": port]])
    }
    private func document(_ port: Int, name: String = "node") throws -> String {
        let list = try JSONSerialization.jsonObject(with: nodes(port, name: name))
        return String(decoding: try JSONSerialization.data(withJSONObject: ["proxies": list]), as: UTF8.self)
    }
    func testSameNameChangedEndpointIsReportedAsModified() throws {
        let changes = try ProxyNodeChanges.compare(old: nodes(9), new: nodes(10))
        XCTAssertEqual(changes.modified, 1); XCTAssertEqual(changes.added, 0); XCTAssertEqual(changes.removed, 0)
        let renamed = try ProxyNodeChanges.compare(old: nodes(9), new: nodes(9, name: "other"))
        XCTAssertEqual(renamed.added, 1); XCTAssertEqual(renamed.removed, 1)
    }
    func testSubscriptionURLsPermitHTTPAndRejectNonWebSchemes() throws {
        XCTAssertEqual(try ProxySubscription.url(" http://example.com/config ").scheme, "http")
        XCTAssertEqual(try ProxySubscription.url("https://example.com/config?token=test").host, "example.com")
        for address in ["file:///tmp/config", "clash://config", "https://", "http://user:password@example.com"] {
            XCTAssertThrowsError(try ProxySubscription.url(address))
        }
    }
    @MainActor func testFailedSaveRestoresRuntimeAndPreservesCommittedProfile() async throws {
        let suite = "ProxyTests." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var stored: Data?, failSave = false, lastRuntime = ""
        let manager = ProxyManager(read: { stored }, save: { data in
            if failSave { throw HarborError("KEYCHAIN_ERROR") }; stored = data
        }, start: { lastRuntime = $0; return true }, stop: {}, defaults: defaults)
        manager.preferences.enabled = true
        try await manager.importText(document(9), name: "old")
        let previous = stored, id = try XCTUnwrap(manager.library.activeID)
        failSave = true
        do { try await manager.importText(document(10), profileID: id); XCTFail("Must reject uncommitted update") }
        catch { XCTAssertEqual((error as? HarborError)?.code, "KEYCHAIN_ERROR") }
        XCTAssertEqual(stored, previous); XCTAssertTrue(manager.running)
        let runtime = try JSONSerialization.jsonObject(with: Data(lastRuntime.utf8)) as! [String: Any]
        XCTAssertEqual((runtime["proxies"] as? [[String: Any]])?.first?["port"] as? Int, 9)
        XCTAssertEqual(try ProxyNodeChanges.compare(old: manager.library.profiles.first?.nodes, new: nodes(9)).modified, 0)
    }
    @MainActor func testFailedCoreStartRollsBackWithoutPublishingNewNodes() async throws {
        let suite = "ProxyTests." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var stored: Data?
        let manager = ProxyManager(read: { stored }, save: { stored = $0 }, start: { configuration in
            let value = try! JSONSerialization.jsonObject(with: Data(configuration.utf8)) as! [String: Any]
            return (value["proxies"] as? [[String: Any]])?.first?["port"] as? Int != 10
        }, stop: {}, defaults: defaults)
        manager.preferences.enabled = true
        try await manager.importText(document(9), name: "old")
        let before = stored
        do { try await manager.importText(document(10, name: "bad")); XCTFail("Must reject failed core") } catch {}
        XCTAssertEqual(manager.names, ["node"]); XCTAssertEqual(stored, before)
        XCTAssertTrue(manager.running); XCTAssertEqual(manager.library.profiles.count, 1)
    }
    @MainActor func testInactiveUpdateDoesNotSwitchAndPerProfileSelectionsSurvive() async throws {
        let suite = "ProxyTests." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var stored: Data?
        let manager = ProxyManager(read: { stored }, save: { stored = $0 }, start: { _ in true }, stop: {}, defaults: defaults)
        try await manager.importText(document(9, name: "a"), name: "A")
        let first = try XCTUnwrap(manager.library.activeID)
        try await manager.importText(document(10, name: "b"), name: "B")
        let second = try XCTUnwrap(manager.library.activeID)
        try await manager.importText(document(11, name: "a"), profileID: first)
        XCTAssertEqual(manager.library.activeID, second); XCTAssertEqual(manager.names, ["b"])
        try await manager.activateProfile(first)
        XCTAssertEqual(manager.preferences.primary, "a"); XCTAssertEqual(manager.names, ["a"])
        try await manager.removeProfile(first)
        XCTAssertNil(manager.library.activeID); XCTAssertFalse(manager.preferences.enabled)
        XCTAssertEqual(manager.library.profiles.count, 1)
        let restored = ProxyManager(read: { stored }, save: { stored = $0 }, start: { _ in true }, stop: {}, defaults: defaults)
        XCTAssertEqual(restored.library.profiles.first?.id, second); XCTAssertTrue(restored.names.isEmpty)
    }
    @MainActor func testLegacyNodesMigrateAndSubscriptionAddressPersistsPrivately() async throws {
        let suite = "ProxyTests." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var stored: Data? = Data(try document(9).utf8)
        let manager = ProxyManager(read: { stored }, save: { stored = $0 }, start: { _ in true }, stop: {}, defaults: defaults)
        XCTAssertEqual(manager.library.profiles.count, 1); XCTAssertEqual(manager.names, ["node"])
        let old = manager.library.activeID
        try await manager.importText(document(10, name: "new"), name: "subscription", subscriptionURL: "http://example.com/config?token=test")
        XCTAssertNotEqual(manager.library.activeID, old)
        let restored = ProxyManager(read: { stored }, save: { stored = $0 }, start: { _ in true }, stop: {}, defaults: defaults)
        XCTAssertEqual(restored.library.profiles.count, 2)
        XCTAssertEqual(restored.library.profiles.last?.subscriptionURL, "http://example.com/config?token=test")
    }
}
