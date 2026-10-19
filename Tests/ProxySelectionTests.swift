import XCTest
@testable import PicHarbor

private actor ProbeCounter {
    var active = 0, maximum = 0, calls = 0
    func measure(_ port: Int) async -> Int? {
        active += 1; calls += 1; maximum = max(maximum, active)
        try? await Task.sleep(nanoseconds: 20_000_000)
        active -= 1
        return 200 - (port - 24500) * 10
    }
}

final class ProxySelectionTests: XCTestCase {
    func testLegacyPoliciesPreserveDirectPermissionAndWaitScope() throws {
        let old = Data(#"{"enabled":true,"primary":"a","backups":["b"],"fallback":"wait"}"#.utf8)
        let preferences = try JSONDecoder().decode(ProxyPreferences.self, from: old)
        XCTAssertEqual(ProxyPolicy.resolve(preferences).backups, [])
        XCTAssertEqual(ProxyPolicy.resolve(preferences).exhaustion, .wait)
        XCTAssertEqual(ProxyPolicy.resolve(preferences, legacy: .nodes).backups, ["b"])
        XCTAssertEqual(ProxyPolicy.resolve(preferences, legacy: .direct).exhaustion, .direct)
        let custom = ProxyPolicy(selection: .automatic, exhaustion: .wait)
        XCTAssertEqual(ProxyPolicy.resolve(preferences, legacy: .direct, override: custom), custom)
        XCTAssertEqual(try JSONDecoder().decode(ProxyPolicy.self, from: JSONEncoder().encode(custom)), custom)
    }
    func testHealthyCurrentNodeStaysAndCooldownExcludesFailures() {
        let now = Date()
        var a = ProxyNodeHealth(milliseconds: 200), b = ProxyNodeHealth(milliseconds: 50)
        a.succeed(at: now); b.succeed(at: now)
        XCTAssertEqual(ProxyNodeRanking.ordered(names: ["a", "b"], health: ["a": a, "b": b], preferred: "a", failures: [], now: now), ["a", "b"])
        a.fail(at: now.addingTimeInterval(1))
        XCTAssertEqual(ProxyNodeRanking.ordered(names: ["a", "b"], health: ["a": a, "b": b], preferred: "a", failures: [], now: now.addingTimeInterval(2)), ["b"])
        XCTAssertFalse(b.healthy(at: now.addingTimeInterval(301)))
        XCTAssertEqual(a.penalty(at: now.addingTimeInterval(302)), 0)
    }
    func testOlderProbeCannotOverwriteNewerTransferEvidence() {
        let began = Date()
        var failed = ProxyNodeHealth()
        failed.fail(at: began.addingTimeInterval(1))
        failed.recordMeasurement(30, began: began, now: began.addingTimeInterval(2))
        XCTAssertTrue(failed.cooling(at: began.addingTimeInterval(2)))
        var succeeded = ProxyNodeHealth()
        succeeded.succeed(at: began.addingTimeInterval(1))
        succeeded.recordMeasurement(nil, began: began, now: began.addingTimeInterval(2))
        XCTAssertTrue(succeeded.healthy(at: began.addingTimeInterval(2)))
    }
    @MainActor func testAutomaticSweepIsBoundedAndFailoverUsesActualOutcomes() async throws {
        let suite = "ProxySelection." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var stored: Data?
        let counter = ProbeCounter()
        let manager = ProxyManager(read: { stored }, save: { stored = $0 }, start: { _ in true }, stop: {}, defaults: defaults, latency: { await counter.measure($0) })
        let nodes = (0..<6).map { ["name": "n\($0)", "type": "socks5", "server": "127.0.0.1", "port": 9] as [String: Any] }
        let input = try JSONSerialization.data(withJSONObject: ["proxies": nodes])
        try await manager.importText(String(decoding: input, as: UTF8.self))
        manager.preferences.enabled = true; manager.preferences.selection = .automatic
        let first = try await manager.route()
        XCTAssertEqual(first.1, "n5")
        let maximum = await counter.maximum, calls = await counter.calls
        XCTAssertLessThanOrEqual(maximum, 3); XCTAssertEqual(calls, 6)
        XCTAssertEqual(manager.testedCount, 6)
        let before = manager.health["n5"]
        manager.recordOutcome(node: "n5", errorCode: "NETWORK_ERROR", scope: "previous-configuration")
        XCTAssertEqual(manager.health["n5"], before)
        manager.recordOutcome(node: "n5", errorCode: "LOGIN_REQUIRED")
        XCTAssertEqual(manager.health["n5"], before)
        manager.recordOutcome(node: "n5", errorCode: "NETWORK_ERROR")
        let second = try await manager.route(preferred: "n5")
        XCTAssertEqual(second.1, "n4")
        let callsAfterFailover = await counter.calls
        XCTAssertEqual(callsAfterFailover, 6)
        let manual = ProxyPolicy(primary: "n0")
        let third = try await manager.route(policy: manual)
        XCTAssertEqual(third.1, "n0")
        XCTAssertEqual(manager.preferences.selection, .automatic)
        let automatic = try await manager.route(policy: ProxyPolicy(selection: .automatic))
        XCTAssertEqual(automatic.1, "n4")
        let sweep = Task { try await manager.testAllNodes() }
        while !manager.testing { await Task.yield() }
        manager.stopTesting()
        do { try await sweep.value; XCTFail("A stopped sweep must be cancelled") } catch is CancellationError {} catch { XCTFail("Unexpected error") }
        XCTAssertFalse(manager.testing)
    }
    @MainActor func testAllFailuresRequireExplicitDirectPermission() async throws {
        let suite = "ProxySelection." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var stored: Data?
        let manager = ProxyManager(read: { stored }, save: { stored = $0 }, start: { _ in true }, stop: {}, defaults: defaults, latency: { _ in nil })
        let input = #"{"proxies":[{"name":"a","type":"socks5","server":"127.0.0.1","port":9}]}"#
        try await manager.importText(input)
        manager.preferences.enabled = true; manager.preferences.selection = .automatic
        do { _ = try await manager.route(); XCTFail("Direct must not be implicit") } catch {}
        let direct = try await manager.route(policy: ProxyPolicy(selection: .automatic, exhaustion: .direct))
        XCTAssertEqual(direct.0, -1)
        XCTAssertEqual(ProxyPolicy.resolve(manager.preferences).exhaustion, .wait)
    }
}
