import XCTest
@testable import PicHarbor

final class PipelineTests: XCTestCase {
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
