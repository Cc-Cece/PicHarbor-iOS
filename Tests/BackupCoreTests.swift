import XCTest
import ImageIO
import UIKit
@testable import PicHarbor

final class BackupCoreTests: XCTestCase {
    func testStoreSurvivesReopenAndKeepsAccountAndPolicySnapshots() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("jobs.sqlite")
        let store = try BackupStore(url: url)
        var settings = BackupSettings()
        let job = BackupJob(account: "a", assetID: "asset", assetRevision: "1", settings: settings)
        try await store.save(job, kind: "job", id: job.id)
        settings.quality = .saver
        let other = BackupJob(account: "b", assetID: "asset", assetRevision: "1", settings: settings)
        try await store.save(other, kind: "job", id: other.id)
        let reopened = try BackupStore(url: url)
        let loaded = try await reopened.load(BackupJob.self, kind: "job")
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded.first { $0.account == "a" }?.settings.quality, .original)
        XCTAssertNotEqual(job.dedupKey, other.dedupKey)
    }
    func testCleanupEvidenceExpiresAndIsBoundToAccountRevisionPolicyAndSourceSet() {
        var job = BackupJob(account: "a", assetID: "asset", assetRevision: "1", settings: BackupSettings())
        job.state = .completed
        job.sources = [MediaResource(role: "original.photo", path: "", name: "", sha256: "abc")]
        let evidence = CleanupEvidence(account: "a", revision: "1", policy: "11", manifest: ["original.photo:abc"])
        XCTAssertTrue(evidence.valid(job: job, settings: BackupSettings()))
        XCTAssertFalse(evidence.valid(job: job, settings: BackupSettings(), now: evidence.checked.addingTimeInterval(300)))
        XCTAssertFalse(evidence.valid(job: job, settings: BackupSettings(), now: evidence.checked.addingTimeInterval(-1)))
        job.account = "b"; XCTAssertFalse(evidence.valid(job: job, settings: BackupSettings()))
        job.account = "a"; job.sources[0].sha256 = "changed"
        XCTAssertFalse(evidence.valid(job: job, settings: BackupSettings()))
        job.sources[0].sha256 = "abc"
        var weakened = BackupSettings(); weakened.originalAccess = false
        XCTAssertFalse(evidence.valid(job: job, settings: weakened))
    }
    func testDefaultSettingsAndVersionedMediaIdentity() {
        var settings = BackupSettings()
        XCTAssertEqual(settings.quality, .original)
        XCTAssertEqual(settings.live, .motion)
        XCTAssertEqual(settings.edits, .both)
        XCTAssertFalse(settings.automatic)
        let media = settings.mediaPolicy
        settings.wifiOnly = false
        XCTAssertEqual(media, settings.mediaPolicy)
        settings.live = .applePair
        XCTAssertNotEqual(media, settings.mediaPolicy)
    }
    func testNativeJPEGContainerHasMetadataAndExactVideoTail() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let still = directory.appendingPathComponent("source.jpg"), video = directory.appendingPathComponent("source.mov")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8)) }
        try XCTUnwrap(image.jpegData(compressionQuality: 1)).write(to: still)
        let clip = Data("fake-video-for-container-test".utf8); try clip.write(to: video)
        let output = try MotionPhoto.mux(still: still, video: video, timestamp: 1200000, directory: directory)
        XCTAssertEqual(try Data(contentsOf: output).suffix(clip.count), clip)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        let metadata = try XCTUnwrap(CGImageSourceCopyMetadataAtIndex(source, 0, nil))
        XCTAssertEqual(CGImageMetadataCopyStringValueWithPath(metadata, nil, "Camera:MotionPhoto" as CFString) as String?, "1")
        XCTAssertEqual(CGImageMetadataCopyStringValueWithPath(metadata, nil, "Camera:MotionPhotoPresentationTimestampUs" as CFString) as String?, "1200000")
        XCTAssertNotNil(CGImageMetadataCopyTagWithPath(metadata, nil, "Container:Directory" as CFString))
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
    }
    func testDigestIsStreamingAndChangesWithContent() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        let digest = try ResourceExporter.hash(file)
        XCTAssertEqual(digest.0, "a9993e364706816aba3e25717850c26c9cd0d89d")
        XCTAssertEqual(digest.1, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(digest.2, 3)
    }
    func testResourceSizeRetainsValuesBeyondFourGiB() throws {
        let resource = MediaResource(role: "video", path: "", name: "", size: 5 * 1024 * 1024 * 1024)
        let decoded = try JSONDecoder().decode(MediaResource.self, from: JSONEncoder().encode(resource))
        XCTAssertEqual(decoded.size, 5_368_709_120)
    }
    func testTenThousandAssetIndexBatchRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try BackupStore(url: directory.appendingPathComponent("index.sqlite"))
        let values = (0..<10_000).map { index in
            (String(index), AssetSnapshot(id: String(index), revision: "v1", mediaType: 1, accessible: true))
        }
        try await store.saveBatch(values, kind: "asset")
        let read = try await store.load(AssetSnapshot.self, kind: "asset")
        XCTAssertEqual(read.count, 10_000)
        XCTAssertTrue(read.allSatisfy(\.accessible))
    }
}
