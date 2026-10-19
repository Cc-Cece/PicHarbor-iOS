import XCTest
@testable import PicHarbor

final class ResourceReuseTests: XCTestCase {
    private func completed() -> BackupJob {
        var job = BackupJob(account: "a", assetID: "asset", assetRevision: "old", settings: BackupSettings())
        job.resources = [MediaResource(role: "original.photo", path: "deleted-stage", name: "before.jpg", sha1: "sha1", sha256: "sha256", size: 100, remoteKey: "cloud", confirmed: true)]
        job.state = .completed
        return job
    }
    func testArchivedEvidenceUsesContentNotNameOrPhotoKitRevision() {
        var old = completed(); old.archivedAt = Date()
        var new = old; new.id = "new"; new.state = .queued; new.assetRevision = "new-revision"
        new.resources[0].name = "renamed.jpg"; new.resources[0].path = "new-stage"
        XCTAssertEqual(ResourceReuse.evidence(for: new, history: [old]), [new.resources[0].id: "cloud"])
    }
    func testDifferentAccountContentSizeAndUnconfirmedHistoryCannotSuppressUploads() {
        let old = completed(); var new = old; new.id = "new"; new.state = .queued
        new.account = "other"; XCTAssertTrue(ResourceReuse.evidence(for: new, history: [old]).isEmpty)
        new.account = old.account; new.resources[0].sha256 = "changed"
        XCTAssertTrue(ResourceReuse.evidence(for: new, history: [old]).isEmpty)
        new.resources = old.resources; new.resources[0].size = 101
        XCTAssertTrue(ResourceReuse.evidence(for: new, history: [old]).isEmpty)
        new.resources = old.resources
        var pending = old; pending.state = .confirming
        XCTAssertTrue(ResourceReuse.evidence(for: new, history: [pending]).isEmpty)
    }
    func testUnpairedLiveHistoryCannotProvideCompletedProof() {
        var old = completed(); old.isLive = true
        old.resources.append(MediaResource(role: "original.pairedVideo", path: "stage", name: "clip.mov", sha1: "v1", sha256: "v256", size: 200, remoteKey: "other-key", confirmed: true))
        var new = old; new.id = "new"; new.state = .queued
        XCTAssertTrue(ResourceReuse.evidence(for: new, history: [old]).isEmpty)
    }
}
