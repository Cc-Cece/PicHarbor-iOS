import XCTest
@testable import PicHarbor

final class PipelineTests: XCTestCase {
    private func editedLiveJob() throws -> BackupJob {
        var job = BackupJob(account: "a", assetID: "edited-live", assetRevision: "v1", settings: BackupSettings())
        job.isLive = true
        job.resources = ["original", "current"].flatMap { version in
            [MediaResource(role: version + ".photo", path: version + ".heic", name: version + ".heic"),
             MediaResource(role: version + ".pairedVideo", path: version + ".mov", name: version + ".mov")]
        }
        job.livePairs = try LivePairRecord.make(job.resources)
        return job
    }
    private func confirm(_ version: Int, in job: inout BackupJob) {
        let key = "saved-\(version)"
        job.livePairs?[version].submitted = true; job.livePairs?[version].confirmed = true; job.livePairs?[version].remoteKey = key
        for index in [version * 2, version * 2 + 1] {
            job.resources[index].submitted = true; job.resources[index].confirmed = true; job.resources[index].remoteKey = key
        }
    }
    func testCompletedOriginalAllowsEditedJointVersionToUploadCommitAndConfirm() throws {
        var job = try editedLiveJob()
        job.livePairs?[0].route = "reconcile"; job.livePairs?[1].route = "joint"
        confirm(0, in: &job)
        // Reproduce the upgraded, stuck task with a stale displayed stage.
        job.pipelineStage = .confirmation; job.state = .confirming
        job = try JSONDecoder().decode(BackupJob.self, from: JSONEncoder().encode(job))
        XCTAssertTrue(job.livePairs![0].isConfirmed(in: job.resources))
        XCTAssertEqual(PipelineScheduler.stage(job, hasPlan: false), .lookup)
        XCTAssertEqual(PipelineScheduler.stage(job, hasPlan: true), .upload)
        job.resources[2].responsePath = "edited-photo-response"
        XCTAssertEqual(PipelineScheduler.stage(job, hasPlan: false), .lookup)
        job.resources[3].responsePath = "edited-video-response"
        XCTAssertEqual(PipelineScheduler.stage(job, hasPlan: false), .commit)
        job.livePairs?[1].submitted = true
        XCTAssertEqual(PipelineScheduler.stage(job, hasPlan: false), .confirmation)
        // Commit ambiguity remains query-only even after a relaunch.
        job = try JSONDecoder().decode(BackupJob.self, from: JSONEncoder().encode(job))
        XCTAssertEqual(PipelineScheduler.stage(job, hasPlan: false), .confirmation)
        confirm(1, in: &job)
        XCTAssertTrue(job.standardConfirmationPassed)
        XCTAssertEqual(PipelineScheduler.stage(job, hasPlan: false), .confirmation)
        XCTAssertEqual(job.resources[0].remoteKey, "saved-0")
    }
    func testCompletedOriginalAllowsEditedReconcileVersionToAdvance() throws {
        var job = try editedLiveJob(); confirm(0, in: &job)
        job.livePairs?[1].route = "reconcile"
        XCTAssertEqual(PipelineScheduler.stage(job, hasPlan: false), .lookup)
        job.resources[2].responsePath = "photo-response"
        XCTAssertEqual(PipelineScheduler.stage(job, hasPlan: false), .commit)
        job.resources[2].submitted = true
        XCTAssertEqual(PipelineScheduler.stage(job, hasPlan: false), .confirmation)
        job.resources[2].remoteKey = "existing-still"
        XCTAssertEqual(PipelineScheduler.stage(job, hasPlan: false), .lookup)
        job.resources[3].responsePath = "video-response"
        XCTAssertEqual(PipelineScheduler.stage(job, hasPlan: false), .commit)
        job.livePairs?[1].submitted = true
        XCTAssertEqual(PipelineScheduler.stage(job, hasPlan: false), .confirmation)
    }
    func testLaterVersionCannotOverrideFirstPendingPairStage() throws {
        var job = try editedLiveJob()
        job.livePairs?[0].route = "joint"; job.livePairs?[1].submitted = true
        XCTAssertEqual(PipelineScheduler.stage(job, hasPlan: false), .lookup)
        job.resources[0].responsePath = "original-photo-response"
        job.resources[1].responsePath = "original-video-response"
        XCTAssertEqual(PipelineScheduler.stage(job, hasPlan: false), .commit)
        confirm(0, in: &job)
        XCTAssertEqual(PipelineScheduler.stage(job, hasPlan: false), .confirmation)
        confirm(1, in: &job)
        job.livePairs?[0].confirmed = false; job.livePairs?[0].submitted = false
        job.resources[0].confirmed = false; job.resources[1].confirmed = false
        XCTAssertEqual(PipelineScheduler.stage(job, hasPlan: false), .commit)
    }
    func testConfirmedCheckpointMustMatchBothResourceKeys() throws {
        var job = try editedLiveJob(); confirm(0, in: &job)
        job.resources[1].remoteKey = "another-cloud-item"
        XCTAssertFalse(job.livePairs![0].isConfirmed(in: job.resources))
        XCTAssertEqual(PipelineScheduler.stage(job, hasPlan: false), .confirmation)
        job.resources.remove(at: 1)
        XCTAssertFalse(job.livePairs![0].isConfirmed(in: job.resources))
    }
    func testOrdinaryAndMotionVersionsFollowFirstPendingResource() {
        for live in [false, true] {
            var settings = BackupSettings(); settings.live = .motion
            var job = BackupJob(account: "a", assetID: "two-versions", assetRevision: "v1", settings: settings)
            job.isLive = live
            job.resources = [MediaResource(role: "original.photo", path: "original", name: "original"),
                             MediaResource(role: "current.photo", path: "edited", name: "edited")]
            job.resources[1].submitted = true
            XCTAssertEqual(PipelineScheduler.stage(job, hasPlan: false), .lookup)
            job.resources[0].responsePath = "response"
            XCTAssertEqual(PipelineScheduler.stage(job, hasPlan: false), .commit)
            job.resources[0].confirmed = true; job.resources[0].remoteKey = "original-key"
            XCTAssertEqual(PipelineScheduler.stage(job, hasPlan: false), .confirmation)
        }
    }
    func testIndependentLanesAndBoundedSelectionAtScale() {
        let limits = PipelineLimits(preparation: 2, lookup: 3, upload: 6, commit: 2, confirmation: 2)
        var visits = 0
        let candidates = (0..<10_000).lazy.map { index in
            visits += 1
            return PipelineCandidate(id: String(index), stage: PipelineStage.allCases[index % 5], created: Date(timeIntervalSince1970: Double(index)))
        }
        let result = PipelineScheduler.select(candidates, limits: limits, occupied: [.confirmation: 2], bufferedBytes: 0)
        XCTAssertEqual(visits, 10_000)
        XCTAssertEqual(result.filter { $0.stage == .preparation }.count, 2)
        XCTAssertEqual(result.filter { $0.stage == .lookup }.count, 3)
        XCTAssertEqual(result.filter { $0.stage == .upload }.count, 6)
        XCTAssertEqual(result.filter { $0.stage == .commit }.count, 2)
        XCTAssertFalse(result.contains { $0.stage == .confirmation })
        XCTAssertEqual(result.first?.stage, .upload)
        let blocked = PipelineScheduler.select(candidates, limits: limits, occupied: [:], bufferedBytes: limits.bufferBytes, readyPlans: 12)
        XCTAssertFalse(blocked.contains { [.preparation, .lookup].contains($0.stage) })
        XCTAssertEqual(blocked.filter { $0.stage == .upload }.count, 6)
    }
    func testDurableStageRecoveryAndCommitFences() throws {
        var job = BackupJob(account: "a", assetID: "asset", assetRevision: "v1", settings: BackupSettings())
        XCTAssertEqual(PipelineScheduler.stage(job, hasPlan: false), .preparation)
        job.resources = [MediaResource(role: "original.photo", path: "local", name: "photo.heic")]
        XCTAssertEqual(PipelineScheduler.stage(job, hasPlan: false), .lookup)
        XCTAssertEqual(PipelineScheduler.stage(job, hasPlan: true), .upload)
        job.resources[0].responsePath = "receipt"
        XCTAssertEqual(PipelineScheduler.stage(job, hasPlan: false), .commit)
        job.resources[0].submitted = true; job.resources[0].remoteKey = "tentative"
        XCTAssertEqual(PipelineScheduler.stage(job, hasPlan: false), .confirmation)
        job.isLive = true
        job.resources.append(MediaResource(role: "original.pairedVideo", path: "local-video", name: "video.mov"))
        job.resources[0].submitted = false; job.resources[0].remoteKey = ""
        job.livePairs = try LivePairRecord.make(job.resources)
        job.livePairs?[0].route = "joint"
        XCTAssertEqual(PipelineScheduler.stage(job, hasPlan: false), .lookup)
        job.resources[1].responsePath = "video-receipt"
        XCTAssertEqual(PipelineScheduler.stage(job, hasPlan: false), .commit)
        job.livePairs?[0].submitted = true
        XCTAssertEqual(PipelineScheduler.stage(job, hasPlan: false), .confirmation)
        let recovered = try JSONDecoder().decode(BackupJob.self, from: JSONEncoder().encode(job))
        XCTAssertEqual(PipelineScheduler.stage(recovered, hasPlan: false), .confirmation)
        job.livePairs?[0].submitted = false; job.livePairs?[0].route = "reconcile"
        job.resources[1].responsePath = nil
        XCTAssertEqual(PipelineScheduler.stage(job, hasPlan: false), .commit)
        job.resources[0].submitted = true
        XCTAssertEqual(PipelineScheduler.stage(job, hasPlan: false), .confirmation)
        job.resources[0].remoteKey = "photo"
        XCTAssertEqual(PipelineScheduler.stage(job, hasPlan: false), .lookup)
    }
    func testAutomaticProfilesCustomValidationAndPressureProtection() {
        var device = PipelineConditions(machine: "iPhone17,1", memoryGB: 8)
        var settings = BackupSettings()
        XCTAssertEqual(PipelineProfiles.effective(settings: settings, device: device).upload, 6)
        device.machine = "future-device"
        XCTAssertEqual(PipelineProfiles.effective(settings: settings, device: device).upload, 3)
        settings.pipelineMode = .custom; settings.pipelineOverrides = PipelineLimits(upload: 12)
        XCTAssertEqual(PipelineProfiles.effective(settings: settings, device: device).upload, 12)
        device.lowPower = true
        XCTAssertEqual(PipelineProfiles.effective(settings: settings, device: device).upload, 2)
        device.memoryWarning = true
        XCTAssertEqual(PipelineProfiles.effective(settings: settings, device: device).preparation, 0)
        XCTAssertEqual(PipelineProfiles.effective(settings: settings, device: device).upload, 1)
        XCTAssertFalse(PipelineLimits(upload: 13).valid)
        XCTAssertFalse(PipelineLimits(bufferMB: 127).valid)
        XCTAssertEqual(settings.mediaPolicy, settings.restoringDefaults().mediaPolicy)
    }
    func testBufferBudgetAllowsSingleOversizeWithoutDeadlock() throws {
        let budget = PipelineBufferBudget()
        budget.configure(limit: 100, base: 0); budget.begin("first"); budget.begin("second")
        try budget.reserve(101, job: "first")
        XCTAssertThrowsError(try budget.reserve(1, job: "second"))
        budget.finish("first"); budget.configure(limit: 100, base: 0)
        try budget.reserve(101, job: "second")
        budget.finish("second"); budget.configure(limit: 100, base: 95); budget.begin("third")
        XCTAssertThrowsError(try budget.reserve(6, job: "third"))
    }
}
