import XCTest
@testable import PicHarbor

final class QueueScalingTests: XCTestCase {
    func testBoundedSelectionForThousandToTenThousandTasks() {
        for size in [1_000, 5_000, 10_000] {
            let start = Date()
            let candidates = (0..<size).reversed().map {
                QueueCandidate(id: "task-\($0)", created: Date(timeIntervalSince1970: Double($0)), confirmation: $0 % 7 == 0)
            }
            var visits = 0
            let selected = QueueScaling.select(candidates.lazy.map { value in visits += 1; return value }, uploads: 2, confirmations: 1)
            XCTAssertEqual(selected, ["task-1", "task-2", "task-0"])
            XCTAssertEqual(visits, size, "Each task must be visited only once")
            print("Queue selection \(size): \(Date().timeIntervalSince(start)) seconds")
        }
    }

    func testFullLanesDoNotTraverseQueueAndConfirmationHasIndependentSlot() {
        var visits = 0
        let candidates = (0..<10_000).lazy.map { index in
            visits += 1
            return QueueCandidate(id: "\(index)", created: .distantPast, confirmation: index == 9_999)
        }
        XCTAssertEqual(QueueScaling.select(candidates, uploads: 0, confirmations: 0), [])
        XCTAssertEqual(visits, 0)
        XCTAssertEqual(QueueScaling.select(candidates, uploads: 0, confirmations: 1), ["9999"])
        XCTAssertEqual(visits, 10_000)
    }

    func testAdmissionAtScaleAndFreshCaptureRevisions() {
        for size in [1_000, 5_000, 10_000] {
            var index = QueueAdmissionIndex()
            let jobs = (0..<size).map { BackupJob(account: "a", assetID: "asset-\($0)", assetRevision: "v1", settings: BackupSettings()) }
            for job in jobs { index.remember(job, account: "a", origin: .manual) }
            for var job in jobs {
                XCTAssertFalse(index.accept(job, origin: .manual))
                job.assetRevision = "v2"
                XCTAssertFalse(index.accept(job, origin: .manual), "A settling capture must keep one preparation")
            }
            let new = BackupJob(account: "a", assetID: "new", assetRevision: "v1", settings: BackupSettings())
            XCTAssertTrue(index.accept(new, origin: .manual))
            XCTAssertFalse(index.accept(new, origin: .manual))
        }
    }

    func testAdmissionKeepsAccountAndPolicyBoundariesAndRemovedHistory() {
        var existing = BackupJob(account: "a", assetID: "same", assetRevision: "v1", settings: BackupSettings())
        var index = QueueAdmissionIndex()
        index.remember(existing, account: "b", origin: .automatic)
        var other = existing; other.account = "b"
        XCTAssertTrue(index.accept(other, origin: .automatic))
        existing.state = .completed
        var manual = QueueAdmissionIndex()
        manual.remember(existing, account: "a", origin: .manual)
        XCTAssertTrue(manual.accept(existing, origin: .manual), "Manual repeats must reach cloud dedup, not silently vanish")
        existing.state = .queued; existing.removeFromActivity()
        var automatic = QueueAdmissionIndex()
        automatic.remember(existing, account: "a", origin: .automatic)
        XCTAssertFalse(automatic.accept(existing, origin: .automatic))
    }

    func testRecoveryAcrossRestartAndAccountIsolation() throws {
        let suite = "queue-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let recovery = QueueRecovery(defaults: defaults)
        XCTAssertFalse(recovery.requiresReview(account: "a", unfinished: 499))
        XCTAssertTrue(recovery.requiresReview(account: "a", unfinished: 5_000))
        recovery.finish(account: "a")
        XCTAssertFalse(recovery.requiresReview(account: "a", unfinished: 10_000))
        recovery.begin(account: "a")
        let restarted = QueueRecovery(defaults: defaults)
        XCTAssertTrue(restarted.requiresReview(account: "a", unfinished: 100))
        XCTAssertFalse(restarted.requiresReview(account: "b", unfinished: 100))
        restarted.finish(account: "a")
        XCTAssertFalse(restarted.requiresReview(account: "a", unfinished: 10_000))
    }

    func testTenThousandPersistedTasksKeepCheckpointsAndRejectStaleWrites() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try BackupStore(url: folder.appendingPathComponent("queue.sqlite"))
        let start = Date()
        for chunk in 0..<100 {
            let jobs = (0..<100).map { item -> BackupJob in
                let index = chunk * 100 + item
                var job = BackupJob(account: index % 2 == 0 ? "a" : "b", assetID: "asset-\(index)", assetRevision: "v1", settings: BackupSettings())
                job.id = "task-\(index)"; job.generation = 2; job.state = .paused
                job.resources = [MediaResource(role: "original.photo", path: "retained-source", name: "test.heic", sha256: "synthetic-hash", remoteKey: "remote-\(index)", confirmed: true)]
                return job
            }
            try await store.saveJobs(jobs)
        }
        var restored = try await store.load(BackupJob.self, kind: "job")
        XCTAssertEqual(restored.count, 10_000)
        XCTAssertEqual(restored.filter { $0.account == "a" }.count, 5_000)
        XCTAssertTrue(restored.allSatisfy { $0.state == .paused && $0.resources[0].confirmed && $0.resources[0].sha256 == "synthetic-hash" })
        var stale = restored[0]; stale.generation = 1; stale.resources = []; stale.state = .queued
        try await store.saveJobs([stale])
        restored = try await store.load(BackupJob.self, kind: "job")
        XCTAssertEqual(restored.first { $0.id == stale.id }?.resources.count, 1)
        print("Persist/restore 10000 tasks with checkpoints: \(Date().timeIntervalSince(start)) seconds")
    }

    func testFailedChunkRollsBackWithoutDiscardingEarlierChunk() async throws {
        struct Document: Codable {
            var fail = false
            func encode(to encoder: Encoder) throws {
                if fail { throw HarborError("SYNTHETIC_WRITE_FAILURE") }
                var values = encoder.singleValueContainer(); try values.encode(false)
            }
            init(fail: Bool = false) { self.fail = fail }
            init(from decoder: Decoder) throws { fail = try decoder.singleValueContainer().decode(Bool.self) }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try BackupStore(url: folder.appendingPathComponent("queue.sqlite"))
        try await store.saveBatch([("prior", Document())], kind: "probe")
        do {
            try await store.saveBatch([("next", Document()), ("broken", Document(fail: true))], kind: "probe")
            XCTFail("Expected rollback")
        } catch { }
        let saved = try await store.load(Document.self, kind: "probe")
        XCTAssertEqual(saved.count, 1)
    }
}
