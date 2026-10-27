import XCTest
@testable import PicHarbor

final class ActivityOrderingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)
    private func job(_ id: String, state: JobState, created: Double, batch: String? = "batch") -> BackupJob {
        var value = BackupJob(account: "a", assetID: id, assetRevision: "v1", settings: BackupSettings())
        value.id = id; value.state = state; value.created = Date(timeIntervalSince1970: created); value.batchID = batch
        return value
    }
    func testBatchShowsActiveThenOldestQueuedBeforePausedAndCompleted() {
        let jobs = [job("done", state: .completed, created: 1), job("later", state: .queued, created: 4),
                    job("next", state: .queued, created: 2), job("active", state: .transferring, created: 5),
                    job("paused", state: .paused, created: 3)]
        let batch = ActivityBatch.make(jobs, source: .all, status: .all, now: now)[0]
        XCTAssertEqual(batch.matching.map(\.id), ["active", "next", "later", "paused", "done"])
        XCTAssertEqual(batch.created, Date(timeIntervalSince1970: 1), "Batch date must remain its original creation time")
    }
    func testDeferredCloudConfirmationDoesNotHideNextUpload() {
        var cloud = job("cloud", state: .paired, created: 1); cloud.retryAt = now.addingTimeInterval(20)
        let next = job("next", state: .queued, created: 2)
        XCTAssertEqual(ActivityBatch.make([cloud, next], source: .all, status: .all, now: now)[0].matching.map(\.id), ["next", "cloud"])
        cloud.retryAt = now.addingTimeInterval(-1)
        XCTAssertEqual(ActivityBatch.make([cloud, next], source: .all, status: .all, now: now)[0].matching.map(\.id), ["cloud", "next"])
    }
    func testSingletonsAlsoShowActiveThenSchedulerOrder() {
        let jobs = [job("later", state: .queued, created: 3, batch: nil), job("next", state: .queued, created: 1, batch: nil),
                    job("active", state: .preparing, created: 2, batch: nil)]
        XCTAssertEqual(ActivityBatch.make(jobs, source: .all, status: .all, now: now).compactMap { $0.matching.first?.id }, ["active", "next", "later"])
    }
    func testEqualCreatedDatesMatchSchedulerIDTieBreak() {
        let jobs = [job("b", state: .queued, created: 1), job("a", state: .queued, created: 1)]
        XCTAssertEqual(ActivityBatch.make(jobs, source: .all, status: .all, now: now)[0].matching.map(\.id), ["a", "b"])
    }
    func testArchiveAndCompletedHistoryKeepNewestFirst() {
        let jobs = [job("old", state: .completed, created: 1), job("new", state: .completed, created: 2)]
        XCTAssertEqual(ActivityBatch.make(jobs, source: .all, status: .completed, now: now)[0].matching.map(\.id), ["new", "old"])
        XCTAssertEqual(ActivityBatch.make(jobs, source: .all, status: .all, queueOrder: false, now: now)[0].matching.map(\.id), ["new", "old"])
    }
}
