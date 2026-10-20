import XCTest
@testable import PicHarbor

final class BackupResilienceTests: XCTestCase {
    func testTimedOutSharedRouteDetachesAndIgnoresItsLateResult() async throws {
        let lease = BackupExecutionLease(stage: .lookup, policy: BackupExecutionPolicy())
        let canceller = Task { try? await Task.sleep(for: .milliseconds(20)); lease.cancel("STAGE_TIMEOUT") }
        let start = Date()
        do {
            _ = try await BackupRouteGuard.run(lease: lease) {
                try await Task.sleep(for: .milliseconds(150))
                return "late-route"
            }
            XCTFail("A timed-out route cannot supply a result")
        } catch { XCTAssertEqual((error as? HarborError)?.code, "STAGE_TIMEOUT") }
        await canceller.value
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.12)
        // Let the detached shared operation finish: no double continuation resume.
        try await Task.sleep(for: .milliseconds(170))
    }
    func testFiniteRetriesPersistAcrossRelaunchAndStageChanges() throws {
        var job = BackupJob(account: "a", assetID: "asset", assetRevision: "v1", settings: BackupSettings())
        for attempt in 1...4 {
            job.pipelineStage = attempt % 2 == 0 ? .lookup : .confirmation
            job.retryFailure("STAGE_TIMEOUT", policy: BackupExecutionPolicy())
            XCTAssertEqual(job.recovery?.failures, attempt)
            XCTAssertEqual(job.state, attempt <= 3 ? .waiting : .attention)
            job = try JSONDecoder().decode(BackupJob.self, from: JSONEncoder().encode(job))
        }
        XCTAssertEqual(job.error, "RETRY_LIMIT")
        XCTAssertNil(job.retryAt)
        job.resetRecoveryAllowance()
        job.retryFailure("NETWORK_ERROR", policy: BackupExecutionPolicy())
        XCTAssertEqual(job.recovery?.failures, 1)
        XCTAssertEqual(job.state, .waiting)
    }
    func testOnlyNewDurableProgressResetsAllowance() {
        var job = BackupJob(account: "a", assetID: "asset", assetRevision: "v1", settings: BackupSettings())
        job.resources = [MediaResource(role: "original.photo", path: "local", name: "test")]
        job.observeRecoveryProgress()
        job.retryFailure("NETWORK_ERROR", policy: BackupExecutionPolicy())
        job.resources[0].responsePath = "response"
        job.observeRecoveryProgress()
        XCTAssertEqual(job.recovery?.failures, 0)
        job.retryFailure("UPLOAD_RESPONSE_INVALID", policy: BackupExecutionPolicy())
        job.resources[0].responsePath = nil; job.observeRecoveryProgress()
        job.resources[0].responsePath = "new-response"; job.observeRecoveryProgress()
        XCTAssertEqual(job.recovery?.failures, 1, "The same receipt milestone cannot replenish the allowance")
        job.resources[0].submitted = true; job.observeRecoveryProgress()
        XCTAssertEqual(job.recovery?.failures, 0)
        XCTAssertTrue(job.resources[0].submitted)
    }
    func testBothActiveTimeAndHandoffLoopHaveLimits() {
        var budget = BackupRecoveryBudget()
        budget.handoffs = 32
        XCTAssertTrue(budget.stalled(policy: BackupExecutionPolicy()))
        budget.handoffs = 0; budget.activeWithoutProgress = 120
        XCTAssertTrue(budget.stalled(policy: BackupExecutionPolicy()))
        budget.observe(["new-checkpoint"])
        XCTAssertFalse(budget.stalled(policy: BackupExecutionPolicy()))
    }
    func testLeaseTimeoutCancelsOnlyRegisteredAttemptAndChecksWork() throws {
        let lease = BackupExecutionLease(stage: .lookup, policy: BackupExecutionPolicy())
        var called = 0
        lease.register("old") { _ in XCTFail("An unregistered request must not be cancelled") }
        lease.unregister("old")
        lease.register("current") { code in XCTAssertEqual(code, "STAGE_TIMEOUT"); called += 1 }
        for _ in 0..<6 { lease.tick(10) }
        XCTAssertEqual(called, 1)
        XCTAssertThrowsError(try lease.check())
        lease.cancel("NO_PROGRESS_TIMEOUT")
        XCTAssertEqual(called, 1)
        lease.register("late") { code in XCTAssertEqual(code, "STAGE_TIMEOUT"); called += 1 }
        XCTAssertEqual(called, 2)
    }
    func testPreparationProgressAndSuspensionAreNotStalls() throws {
        let lease = BackupExecutionLease(stage: .preparation, policy: BackupExecutionPolicy())
        lease.tick(600)
        XCTAssertEqual(lease.activeSeconds, 0)
        for _ in 0..<30 { lease.tick(10); lease.progress() }
        try lease.check()
        for _ in 0..<12 { lease.tick(10) }
        XCTAssertEqual(lease.cancellation, "NO_PROGRESS_TIMEOUT")
        var clock = BackupObservedClock()
        XCTAssertEqual(clock.tick(now: 0, running: true), 0)
        XCTAssertEqual(clock.tick(now: 10, running: true), 10)
        XCTAssertEqual(clock.tick(now: 1000, running: true), 0)
        XCTAssertEqual(clock.tick(now: 1010, running: false), 0)
        XCTAssertEqual(clock.tick(now: 2000, running: true), 0)
    }
    func testTransferProgressAndSizeAwareTotalLimit() {
        var watch = BackupTransferWatch(taskID: 1, resourceID: "r", policy: BackupExecutionPolicy())
        XCTAssertNil(watch.tick(100, size: 100))
        watch.progress(10)
        XCTAssertEqual(watch.idle, 0)
        watch.progress(10)
        XCTAssertNil(watch.tick(100, size: 100))
        XCTAssertEqual(watch.tick(20, size: 100), "NO_PROGRESS_TIMEOUT")
        let policy = BackupExecutionPolicy()
        XCTAssertEqual(policy.fileSeconds(size: 1), 600)
        XCTAssertEqual(policy.fileSeconds(size: 5 * 1024 * 1024 * 1024), 7200)
        watch = BackupTransferWatch(taskID: 2, resourceID: "r", policy: policy)
        for index in 1...59 { XCTAssertNil(watch.tick(10, size: 1)); watch.progress(Int64(index)) }
        XCTAssertEqual(watch.tick(10, size: 1), "TRANSFER_TIMEOUT")
    }
    func testLimitsValidationAndSubmittedFenceSurvivesExhaustion() {
        XCTAssertFalse(BackupExecutionPolicy(retries: 11).valid)
        XCTAssertFalse(BackupExecutionPolicy(querySeconds: 0).valid)
        XCTAssertFalse(BackupExecutionPolicy(fileMinutes: 1441).valid)
        var job = BackupJob(account: "a", assetID: "asset", assetRevision: "v1", settings: BackupSettings())
        job.resources = [MediaResource(role: "original.photo", path: "local", name: "test", submitted: true)]
        job.retryFailure("STAGE_TIMEOUT", policy: BackupExecutionPolicy(retries: 0))
        XCTAssertEqual(job.state, .attention)
        XCTAssertTrue(job.resources[0].submitted)
        XCTAssertEqual(PipelineScheduler.stage(job, hasPlan: false), .confirmation)
    }
    func testOldCloudMessageDoesNotSpendCloudBudgetDuringFileUpload() {
        var job = BackupJob(account: "a", assetID: "asset", assetRevision: "v1", settings: BackupSettings())
        job.error = "PAIR_CONFIRMATION_PENDING"; job.state = .confirming
        XCTAssertTrue(job.awaitingCloud)
        for state in [JobState.transferring, .committing, .queued, .paused, .attention] {
            job.state = state
            XCTAssertFalse(job.awaitingCloud)
        }
    }
}
