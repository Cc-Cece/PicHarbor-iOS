import XCTest
@testable import PicHarbor

final class LibraryBackupFilterTests: XCTestCase {
    private func job(_ state: JobState = .completed) -> BackupJob {
        var value = BackupJob(account: "a", assetID: "photo", assetRevision: "v1", settings: BackupSettings())
        value.state = state
        return value
    }
    func testAccountAndEditedVersionAreIsolated() {
        var index = CompletedAssetIndex()
        index.include([job()], account: "a")
        XCTAssertTrue(index.contains(assetID: "photo", revision: "v1", account: "a"))
        XCTAssertFalse(index.contains(assetID: "photo", revision: "v2", account: "a"))
        XCTAssertFalse(index.contains(assetID: "photo", revision: "v1", account: "b"))
        index.include([job()], account: "b")
        XCTAssertFalse(index.contains(assetID: "photo", revision: "v1", account: "b"))
    }
    func testPendingFailedAndBlueCheckAreNotCompleted() {
        for state in [JobState.queued, .preparing, .transferring, .confirming, .paired, .paused, .failed, .attention, .cancelled] {
            var index = CompletedAssetIndex(); index.include([job(state)], account: "a")
            XCTAssertFalse(index.contains(assetID: "photo", revision: "v1", account: "a"))
        }
    }
    func testArchivedSkippedCompletionSurvivesNewAttemptAndRepeatedProgressDoesNotInvalidateCache() {
        var saved = job(); saved.archivedAt = Date()
        saved.resources = [MediaResource(role: "original.photo", path: "", name: "photo", confirmed: true, reused: true)]
        var index = CompletedAssetIndex(); index.include([saved], account: "a")
        let revision = index.revision
        index.include([job(.transferring), saved], account: "a")
        XCTAssertEqual(index.revision, revision)
        XCTAssertTrue(index.contains(assetID: "photo", revision: "v1", account: "a"))
        index.reset(account: "a")
        XCTAssertGreaterThan(index.revision, revision)
        XCTAssertFalse(index.contains(assetID: "photo", revision: "v1", account: "a"))
    }
    func testFiltersAreComplementary() {
        for backedUp in [true, false] {
            XCTAssertTrue(LibraryBackupFilter.all.includes(backedUp: backedUp))
            XCTAssertNotEqual(LibraryBackupFilter.backedUp.includes(backedUp: backedUp), LibraryBackupFilter.notBackedUp.includes(backedUp: backedUp))
        }
    }
}
