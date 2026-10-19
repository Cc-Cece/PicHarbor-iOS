import XCTest
@testable import PicHarbor

final class ActivityArchiveTests: XCTestCase {
    private func job() -> BackupJob {
        BackupJob(account: "test@example.com", assetID: "asset", assetRevision: "revision", settings: BackupSettings())
    }
    @MainActor
    func testArchiveSettingsValidatePersistAndKeepLastValidValue() {
        let suite = "archive-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ActivityArchivePreferences(defaults: defaults)
        XCTAssertTrue(settings.enabled); XCTAssertEqual(settings.days, 14)
        for invalid in ["", "0", "91", "-1", "1.5", " 7", "abc", "999999999999999999999"] {
            XCTAssertFalse(settings.setDays(invalid)); XCTAssertEqual(settings.days, 14)
        }
        XCTAssertTrue(settings.setDays("1")); XCTAssertTrue(settings.setDays("90")); settings.enabled = false
        let reopened = ActivityArchivePreferences(defaults: defaults)
        XCTAssertEqual(reopened.days, 90); XCTAssertFalse(reopened.enabled)
    }
    func testArchiveUsesCompletionDateAndOnlyCompletedVisibleJobs() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        var value = job(); value.created = now.addingTimeInterval(-100 * 86400)
        value.state = .completed; value.completedAt = now.addingTimeInterval(-13 * 86400)
        XCTAssertFalse(value.shouldAutoArchive(days: 14, now: now))
        value.completedAt = now.addingTimeInterval(-14 * 86400)
        XCTAssertTrue(value.shouldAutoArchive(days: 14, now: now))
        value.archivedAt = now; XCTAssertFalse(value.shouldAutoArchive(days: 14, now: now))
        value.archivedAt = nil; value.unarchivedAt = now
        XCTAssertFalse(value.shouldAutoArchive(days: 14, now: now))
        value.unarchivedAt = nil; value.state = .failed
        XCTAssertFalse(value.shouldAutoArchive(days: 14, now: now))
        value.state = .completed; value.activityHidden = true
        XCTAssertFalse(value.shouldAutoArchive(days: 14, now: now))
    }
    func testSkipRequiresAllResourcesAndCompletion() {
        var value = job()
        value.resources = [MediaResource(role: "original.photo", path: "unused", name: "photo", remoteKey: "cloud", confirmed: true)]
        value.resources[0].reused = true
        XCTAssertFalse(value.skippedExisting)
        value.state = .completed; XCTAssertTrue(value.skippedExisting)
        value.resources.append(MediaResource(role: "current.photo", path: "unused", name: "edited", remoteKey: "cloud2", confirmed: true))
        XCTAssertFalse(value.skippedExisting); XCTAssertTrue(value.reusedSome)
    }
    func testLiveExistenceDoesNotReplacePairConfirmation() {
        var value = job(); value.isLive = true
        value.resources = [MediaResource(role: "original.photo", path: "unused", name: "photo", remoteKey: "a", confirmed: true), MediaResource(role: "original.pairedVideo", path: "unused", name: "video", remoteKey: "b", confirmed: true)]
        value.resources[0].reused = true; value.resources[1].reused = true
        value.state = .completed
        XCTAssertFalse(value.standardConfirmationPassed); XCTAssertFalse(value.skippedExisting)
    }
    func testArchiveAndReuseSurviveVersionedStorageAndKeepDiscoveryIdentity() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("archive.sqlite")
        let store = try BackupStore(url: url)
        var value = job(); value.state = .completed; value.completedAt = Date(); value.generation = 5
        value.resources = [MediaResource(role: "original.photo", path: "unused", name: "photo", remoteKey: "cloud", confirmed: true)]
        value.resources[0].reused = true
        let identity = value.discoveryKey(origin: .automatic)
        try await store.save(value, kind: "job", id: value.id, revision: 5)
        let old = value
        value.archivedAt = Date(); value.generation = 6
        try await store.saveJobs([value])
        try await store.save(old, kind: "job", id: old.id, revision: 5)
        let reopened = try BackupStore(url: url)
        let saved = try await reopened.load(BackupJob.self, kind: "job")
        XCTAssertNotNil(saved[0].archivedAt); XCTAssertTrue(saved[0].skippedExisting)
        XCTAssertEqual(saved[0].discoveryKey(origin: .automatic), identity)
        XCTAssertEqual(saved[0].state, .completed); XCTAssertNil(saved[0].activityHidden)
    }
    func testOldRecordsDecodeWithoutNewArchiveOrReuseFields() throws {
        let original = job()
        let decoded = try JSONDecoder().decode(BackupJob.self, from: JSONEncoder().encode(original))
        XCTAssertNil(decoded.archivedAt); XCTAssertNil(decoded.unarchivedAt); XCTAssertFalse(decoded.skippedExisting)
    }
}
