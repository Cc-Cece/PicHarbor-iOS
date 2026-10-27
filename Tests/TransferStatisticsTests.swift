import XCTest
@testable import PicHarbor

final class TransferStatisticsTests: XCTestCase {
    func testLargeQueueReportsKnownBytesAndUnknownCountWithoutInspectingPhotos() throws {
        var known = BackupJob(account: "a", assetID: "known", assetRevision: "v1", settings: BackupSettings())
        known.state = .transferring
        known.resources = [MediaResource(role: "original.photo", path: "unused", name: "test.heic", size: 1_000, transportID: 1)]
        let jobs = [known] + (1..<10_000).map { BackupJob(account: "a", assetID: "asset-\($0)", assetRevision: "v1", settings: BackupSettings()) }
        let start = Date()
        let workload = UploadWorkload(jobs: jobs, account: "a")
        var tracker = TransferRateTracker()
        tracker.record(sample(1, 0, 0)); tracker.record(sample(1, 200, 2))
        for _ in 0..<50 {
            let summary = workload.summary(tracker: tracker, now: 2, canTransfer: true)
            XCTAssertEqual(summary.remainingBytes, 800)
            XCTAssertEqual(summary.unknownSizeCount, 9_999)
        }
        print("Upload workload 10000 assets and 50 cached byte counts: \(Date().timeIntervalSince(start)) seconds")
    }
    private func sample(_ id: Int, _ sent: Int64, _ time: Double, total: Int64 = 10_000) -> UploadProgressSample {
        UploadProgressSample(taskID: id, jobID: "job-\(id)", resourceID: "resource-\(id)", sent: sent, total: total, time: time)
    }
    func testParallelTransfersUseAggregateBytesAndMonotonicElapsedTime() throws {
        var tracker = TransferRateTracker()
        tracker.record(sample(1, 0, 0)); tracker.record(sample(2, 0, 0))
        tracker.record(sample(1, 100, 2)); tracker.record(sample(2, 200, 2))
        XCTAssertEqual(try XCTUnwrap(tracker.speed(now: 2, active: [1, 2])), 150, accuracy: 0.001)
        XCTAssertNil(tracker.speed(now: 0.5, active: [1, 2]))
        XCTAssertEqual(tracker.speed(now: 6, active: [1, 2]), 0)
        XCTAssertEqual(tracker.speed(now: 2, active: []), 0)
    }
    func testSequentialShortFilesDoNotMultiplyUploadSpeed() throws {
        var tracker = TransferRateTracker()
        tracker.record(sample(1, 0, 0)); tracker.record(sample(1, 100, 1)); tracker.finish(1)
        tracker.record(sample(2, 0, 1)); tracker.record(sample(2, 100, 2))
        XCTAssertEqual(try XCTUnwrap(tracker.speed(now: 2, active: [2])), 100, accuracy: 0.001)
    }
    func testRetryCountersAndOldCallbacksDoNotDoubleCount() throws {
        var tracker = TransferRateTracker()
        tracker.record(sample(1, 0, 0)); tracker.record(sample(1, 100, 1))
        tracker.record(sample(1, 50, 0.5)) // late callback is ignored
        tracker.record(sample(1, 200, 2))
        XCTAssertEqual(try XCTUnwrap(tracker.speed(now: 2, active: [1])), 100, accuracy: 0.001)
        tracker.record(sample(1, 0, 3)) // restarted transport counter
        tracker.record(sample(1, 100, 4))
        XCTAssertEqual(try XCTUnwrap(tracker.speed(now: 4, active: [1])), 75, accuracy: 0.001)
    }
    func testResumeAndInitialPartialCountersDoNotInventFastTransfers() throws {
        var tracker = TransferRateTracker()
        tracker.record(sample(1, 1_000, 0)); tracker.record(sample(1, 1_100, 1))
        XCTAssertEqual(try XCTUnwrap(tracker.speed(now: 1, active: [1])), 100, accuracy: 0.001)
        tracker.record(sample(1, 9_000, 100))
        XCTAssertNil(tracker.speed(now: 100, active: [1]))
        tracker.record(sample(1, 9_100, 101))
        XCTAssertEqual(try XCTUnwrap(tracker.speed(now: 101, active: [1])), 100, accuracy: 0.001)
    }
    func testRemainingBytesExcludeOtherAccountsAndPausedJobsAndKeepUnknownSizes() throws {
        var current = BackupJob(account: "a", assetID: "current", assetRevision: "v1", settings: BackupSettings())
        current.state = .transferring
        current.resources = [MediaResource(role: "original.photo", path: "unused", name: "test.heic", size: 1_000, transportID: 1)]
        var history = current; history.id = "history"; history.state = .completed
        history.resources[0].size = 2_000; history.resources[0].confirmed = true
        var otherAccount = history; otherAccount.account = "b"; otherAccount.resources[0].size = 9_000_000
        let unknown = BackupJob(account: "a", assetID: "unknown", assetRevision: "v1", settings: BackupSettings())
        var paused = unknown; paused.state = .paused; paused.mediaKind = "video"
        var tracker = TransferRateTracker()
        tracker.record(sample(1, 0, 0)); tracker.record(sample(1, 200, 2))
        let workload = UploadWorkload(jobs: [current, history, otherAccount, unknown, unknown, paused], account: "a")
        let summary = workload.summary(tracker: tracker, now: 2, canTransfer: true)
        XCTAssertEqual(summary.remainingBytes, 800); XCTAssertEqual(summary.unknownSizeCount, 2)
        let offline = workload.summary(tracker: tracker, now: 2, canTransfer: false)
        XCTAssertEqual(offline.remainingBytes, 800); XCTAssertEqual(offline.bytesPerSecond, 0)
        paused.state = .queued
        let missingVideoSize = UploadWorkload(jobs: [current, history, unknown, paused], account: "a")
        XCTAssertEqual(missingVideoSize.summary(tracker: tracker, now: 2, canTransfer: true).unknownSizeCount, 2)
    }
    func testLargeVideoBytesAndCloudConfirmationStaySeparate() throws {
        let size: Int64 = 5 * 1024 * 1024 * 1024
        var video = BackupJob(account: "a", assetID: "video", assetRevision: "v1", settings: BackupSettings())
        video.state = .transferring; video.mediaKind = "video"
        video.resources = [MediaResource(role: "original.video", path: "unused", name: "test.mov", size: size, transportID: 1)]
        var tracker = TransferRateTracker()
        tracker.record(sample(1, 0, 0, total: size)); tracker.record(sample(1, 1024 * 1024, 2, total: size))
        let summary = UploadWorkload(jobs: [video], account: "a").summary(tracker: tracker, now: 2, canTransfer: true)
        XCTAssertEqual(summary.remainingBytes, size - 1024 * 1024)
        video.state = .confirming; video.resources[0].confirmed = true
        let cloud = UploadWorkload(jobs: [video], account: "a").summary(tracker: tracker, now: 2, canTransfer: true)
        XCTAssertTrue(cloud.uploadFinished); XCTAssertEqual(cloud.remainingBytes, 0)
        XCTAssertEqual(video.state, .confirming)
        let unknown = BackupJob(account: "a", assetID: "unknown", assetRevision: "v1", settings: BackupSettings())
        XCTAssertFalse(UploadWorkload(jobs: [unknown], account: "a").summary(tracker: tracker, now: 2, canTransfer: true).uploadFinished)
    }
}
