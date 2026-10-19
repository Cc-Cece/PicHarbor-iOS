import XCTest
import ImageIO
import UIKit
import Darwin
import AVFoundation
import UniformTypeIdentifiers
import Photos
@testable import PicHarbor

final class BackupCoreTests: XCTestCase {
    func testSourceWaitingIsBoundedAndDoesNotConsumeNetworkRetries() {
        var job = BackupJob(account: "a", assetID: "asset", assetRevision: "old", settings: BackupSettings())
        let now = Date(timeIntervalSince1970: 100)
        for round in 1...7 {
            job.attempts += 1; job.error = "SOURCE_SETTLING"
            job.waitForSource(now: now)
            XCTAssertEqual(job.attempts, 0)
            XCTAssertEqual(job.sourceWaits, round)
            if round <= 6 {
                XCTAssertEqual(job.state, .waiting)
                XCTAssertEqual(job.retryAt, now.addingTimeInterval(Double(round) * 5))
            } else {
                XCTAssertEqual(job.state, .attention); XCTAssertNil(job.retryAt)
                XCTAssertEqual(job.error, "SOURCE_SETTLING_LIMIT")
            }
        }
    }

    @MainActor
    func testPreparationReturnsFreshSnapshotAndStopsAfterBoundedChanges() async throws {
        var reads = 0
        let latest = try await SourceStabilityProbe.wait(read: {
            reads += 1
            return (reads, reads == 1 ? "old" : "new")
        }, pause: {})
        XCTAssertEqual(latest, 4)
        reads = 0
        do {
            _ = try await SourceStabilityProbe.wait(read: { reads += 1; return (reads, String(reads)) }, pause: {})
            XCTFail("Continuously changing assets must leave the preparation worker")
        } catch { XCTAssertEqual((error as? HarborError)?.code, "SOURCE_SETTLING") }
        XCTAssertEqual(reads, 6)
    }

    @MainActor
    func testPreparationHonorsPauseAndPermissionLoss() async {
        for code in ["JOB_PAUSED", "PHOTO_PERMISSION", "WAITING_NETWORK"] {
            do {
                _ = try await SourceStabilityProbe.wait(read: { () throws -> (Int, String) in throw HarborError(code) }, pause: {})
                XCTFail("Must preserve the actionable failure")
            } catch { XCTAssertEqual((error as? HarborError)?.code, code) }
        }
        do {
            _ = try await SourceStabilityProbe.wait(read: { (1, "same") }, pause: { throw CancellationError() })
            XCTFail("Cancellation must stop preparation")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testFreshSourceDebounceRestartsWhenManifestChanges() {
        var probe = SourceStabilityProbe()
        XCTAssertFalse(probe.observe("revision1|photo"))
        XCTAssertFalse(probe.observe("revision1|photo"))
        XCTAssertFalse(probe.observe("revision1|photo|pairedVideo"))
        XCTAssertFalse(probe.observe("revision2|photo|pairedVideo"))
        XCTAssertFalse(probe.observe("revision2|photo|pairedVideo"))
        XCTAssertTrue(probe.observe("revision2|photo|pairedVideo"))
    }

    func testUnpreparedTaskCanRefreshWithoutChangingUserPolicyOrBatch() throws {
        var policy = BackupSettings(); policy.live = .applePair; policy.quality = .quota
        var job = BackupJob(account: "a", assetID: "asset", assetRevision: "old", settings: policy)
        job.batchID = "batch"; job.origin = .manual; job.error = "SOURCE_CHANGED"; job.state = .attention
        let identity = job.id
        let oldKey = job.dedupKey
        try job.refreshSource(revision: "new", live: true, created: Date(timeIntervalSince1970: 1), modified: Date(timeIntervalSince1970: 2))
        let saved = try JSONDecoder().decode(BackupJob.self, from: JSONEncoder().encode(job))
        XCTAssertEqual(saved.id, identity); XCTAssertEqual(saved.account, "a")
        XCTAssertEqual(saved.batchID, "batch"); XCTAssertEqual(saved.settings, policy)
        XCTAssertNotEqual(saved.dedupKey, oldKey); XCTAssertTrue(saved.isLive)
        XCTAssertEqual(saved.assetRevision, "new")
    }

    func testSourceRefreshRejectsExportedOrSubmittedSnapshots() throws {
        let original = BackupJob(account: "a", assetID: "asset", assetRevision: "old", settings: BackupSettings())
        let resource = MediaResource(role: "original.photo", path: "still", name: "image.heic")
        var exported = original; exported.sources = [resource]
        var transferred = original; transferred.resources = [resource]; transferred.resources[0].submitted = true
        var paired = original; paired.livePairs = [LivePairRecord(id: "original", photoID: "p", videoID: "v", submitted: true)]
        var complete = original; complete.state = .completed
        for var locked in [exported, transferred, paired, complete] {
            XCTAssertThrowsError(try locked.refreshSource(revision: "new", live: true, created: nil, modified: nil))
            XCTAssertEqual(locked.assetRevision, "old")
        }
    }

    func testOriginalPairResourcesRetainVersionAndRejectIncompleteSets() throws {
        let originals = [MediaResource(role: "original.photo", path: "still", name: "original.heic", sha256: "photo-original"),
                         MediaResource(role: "original.pairedVideo", path: "video", name: "original.mov", sha256: "video-original")]
        let edited = [MediaResource(role: "current.photo", path: "edit", name: "edit.heic", sha256: "photo-edited"),
                      MediaResource(role: "current.pairedVideo", path: "edit-video", name: "edit.mov", sha256: "video-edited")]
        let pairs = try LivePairRecord.make(originals + edited)
        XCTAssertEqual(pairs.count, 2)
        XCTAssertEqual(pairs[0].photoID, originals[0].id)
        XCTAssertEqual(pairs[0].videoID, originals[1].id)
        XCTAssertEqual(pairs[1].photoID, edited[0].id)
        XCTAssertEqual(pairs[1].videoID, edited[1].id)
        XCTAssertThrowsError(try LivePairRecord.make([originals[0], edited[1]]))
        XCTAssertThrowsError(try LivePairRecord.make(originals + [originals[0]]))
        XCTAssertThrowsError(try LivePairRecord.make([]))
    }

    func testUncertainPairSubmissionSurvivesStoreAndNetworkChangeAsQueryOnly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var settings = BackupSettings(); settings.live = .applePair
        var job = BackupJob(account: "a", assetID: "asset", assetRevision: "1", settings: settings)
        job.resources = [MediaResource(role: "original.photo", path: "photo", name: "original.heic"),
                         MediaResource(role: "original.pairedVideo", path: "video", name: "original.mov")]
        job.resources[0].responsePath = "photo-response"; job.resources[1].responsePath = "video-response"
        job.livePairs = try LivePairRecord.make(job.resources)
        job.livePairs?[0].route = "joint"; job.livePairs?[0].submitted = true
        job.state = .paused; job.updateNetwork(wifiOnly: false)
        let store = try BackupStore(url: root.appendingPathComponent("pair.sqlite"))
        try await store.save(job, kind: "job", id: job.id)
        let reopened = try BackupStore(url: root.appendingPathComponent("pair.sqlite"))
        let restored = try await reopened.load(BackupJob.self, kind: "job")
        let pair = try XCTUnwrap(restored.first?.livePairs?.first)
        XCTAssertTrue(pair.queryOnly)
        XCTAssertEqual(pair.route, "joint")
        XCTAssertEqual(restored.first?.state, .paused)
        XCTAssertEqual(restored.first?.resources[1].responsePath, "video-response")
        XCTAssertFalse(restored.first?.settings.wifiOnly ?? true)
    }

    func testStrategyChangesRequireExplicitRebackupRatherThanAutomaticRediscovery() {
        let first = BackupJob(account: "a", assetID: "asset", assetRevision: "1", settings: BackupSettings())
        var other = first; other.settings.live = .applePair; other.settings.quality = .quota
        XCTAssertNotEqual(first.discoveryKey(origin: .manual), other.discoveryKey(origin: .manual))
        XCTAssertEqual(first.discoveryKey(origin: .automatic), other.discoveryKey(origin: .automatic))
        other.assetRevision = "2"
        XCTAssertNotEqual(first.discoveryKey(origin: .automatic), other.discoveryKey(origin: .automatic))
        other = first; other.account = "b"
        XCTAssertNotEqual(first.discoveryKey(origin: .automatic), other.discoveryKey(origin: .automatic))
        XCTAssertEqual(try? JSONDecoder().decode(LiveStrategy.self, from: Data("\"applePair\"".utf8)), .applePair)
        XCTAssertEqual(Set(LiveStrategy.allCases.map(\.rawValue)), ["motion", "applePair", "appleReconcile"])
    }
    func testNetworkPolicyRebuildsTransportWithoutChangingMediaOrCommitEvidence() {
        var job = BackupJob(account: "a", assetID: "asset", assetRevision: "1", settings: BackupSettings())
        job.state = .transferring; job.error = "WAITING_NETWORK"; job.attempts = 2; job.retryAt = .distantFuture
        var resource = MediaResource(role: "original.motion", path: "source", name: "motion.heic")
        resource.transportID = 7; resource.responsePath = "response"; resource.remoteKey = "cloud"; resource.submitted = true
        job.resources = [resource]
        let identity = job.dedupKey
        XCTAssertEqual(job.updateNetwork(wifiOnly: false), [7])
        XCTAssertEqual(job.dedupKey, identity)
        XCTAssertEqual(job.state, .queued)
        XCTAssertFalse(job.settings.wifiOnly)
        XCTAssertNil(job.resources[0].transportID)
        XCTAssertEqual(job.resources[0].responsePath, "response")
        XCTAssertEqual(job.resources[0].remoteKey, "cloud")
        XCTAssertTrue(job.resources[0].submitted)
        XCTAssertNil(job.retryAt); XCTAssertEqual(job.error, "")
        job.state = .paused
        job.updateNetwork(wifiOnly: true)
        XCTAssertEqual(job.state, .paused)
        job.state = .completed
        job.updateNetwork(wifiOnly: false)
        XCTAssertTrue(job.settings.wifiOnly, "Completed history retains its settings")
    }

    func testLegacyJobsDecodeWithoutInventingBatchOrOrigin() throws {
        let job = BackupJob(account: "a", assetID: "asset", assetRevision: "1", settings: BackupSettings())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(job)) as? [String: Any])
        for key in ["origin", "batchID", "activityHidden"] { json.removeValue(forKey: key) }
        let decoded = try JSONDecoder().decode(BackupJob.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.origin); XCTAssertNil(decoded.batchID); XCTAssertNil(decoded.activityHidden)
        XCTAssertEqual(decoded.dedupKey, job.dedupKey)
    }

    func testActivityBatchAndOriginGroupingPreserveMembershipAndExcludeRemovedTasks() throws {
        var first = BackupJob(account: "a", assetID: "1", assetRevision: "1", settings: BackupSettings())
        first.origin = .manual; first.batchID = "batch1"; first.created = Date(timeIntervalSince1970: 1)
        var second = first; second.id = "2"; second.assetID = "2"; second.state = .completed
        var automatic = first; automatic.id = "3"; automatic.origin = .automatic; automatic.batchID = "batch2"; automatic.created = Date(timeIntervalSince1970: 2)
        let legacy = BackupJob(account: "a", assetID: "4", assetRevision: "1", settings: BackupSettings())
        var hidden = first; hidden.id = "5"; hidden.removeFromActivity()
        let jobs = [first, second, automatic, legacy, hidden]
        let batches = ActivityGroup.groups(jobs, byBatch: true)
        XCTAssertEqual(batches.count, 3)
        XCTAssertEqual(batches.first { $0.jobs.contains { $0.id == first.id } }?.jobs.count, 2)
        XCTAssertEqual(ActivityGroup.groups(jobs, byBatch: false).count, 3)
        XCTAssertEqual(batches.flatMap(\.jobs).count, 4)
        XCTAssertEqual(hidden.transferDisposition(activeAccount: "a"), .cancel)
        XCTAssertFalse(hidden.unfinished)
        second.removeFromActivity()
        XCTAssertNil(second.activityHidden)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try JSONEncoder().encode(hidden).write(to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let reopened = try JSONDecoder().decode(BackupJob.self, from: Data(contentsOf: root))
        XCTAssertTrue(reopened.activityHidden == true)
        XCTAssertEqual(reopened.state, .cancelled)
    }
    func testUploadResponseDataWithoutHeadersSurvivesHeaderCallbackAndRelaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UploadResponseStore(root: root)
        try store.append(Data([8]), id: 7)
        try store.prepare(7)
        let relaunched = UploadResponseStore(root: root)
        try relaunched.prepare(7)
        try relaunched.append(Data([7]), id: 7)
        try relaunched.validate(7)
        XCTAssertEqual(try Data(contentsOf: store.url(7)), Data([8, 7]))
        XCTAssertThrowsError(try store.validate(8)) { XCTAssertEqual(($0 as? HarborError)?.code, "UPLOAD_RESPONSE_MISSING") }
        try store.prepare(8)
        XCTAssertThrowsError(try store.validate(8)) { XCTAssertEqual(($0 as? HarborError)?.code, "UPLOAD_RESPONSE_EMPTY") }
    }

    func testOnlyProvenPrecommitResponseFailureClearsTheMatchingSubmission() {
        var job = BackupJob(account: "test", assetID: "asset", assetRevision: "1", settings: BackupSettings())
        var first = MediaResource(role: "original.photo", path: "", name: "")
        first.submitted = true; first.responsePath = "response"
        var second = MediaResource(role: "current.photo", path: "", name: "")
        second.submitted = true; second.responsePath = "other-response"
        job.resources = [first, second]
        job.recordFailure("NETWORK_ERROR", stage: "commit_response", committingResourceID: first.id)
        XCTAssertTrue(job.resources[0].submitted)
        job.recordFailure("FILE_ACCESS", stage: "commit_response", committingResourceID: first.id)
        XCTAssertTrue(job.resources[0].submitted, "Legacy ambiguous errors must still query the cloud first")
        job.recordFailure("UPLOAD_RESPONSE_MISSING", stage: "commit_response", committingResourceID: first.id)
        XCTAssertFalse(job.resources[0].submitted)
        XCTAssertNil(job.resources[0].responsePath)
        XCTAssertTrue(job.resources[1].submitted)
        XCTAssertEqual(job.resources[1].responsePath, "other-response")
    }

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
    func testLateWriteCannotUndoPersistedPause() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try BackupStore(url: directory.appendingPathComponent("race.sqlite"))
        var job = BackupJob(account: "a", assetID: "asset", assetRevision: "1", settings: BackupSettings())
        job.state = .paused
        try await store.save(job, kind: "job", id: job.id, revision: 10)
        job.state = .transferring
        try await store.save(job, kind: "job", id: job.id, revision: 9)
        let values = try await store.load(BackupJob.self, kind: "job")
        XCTAssertEqual(values.first?.state, .paused)
    }
    func testActualFileBeyondFourGiBHashesWithBoundedMemory() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: nil))
        let handle = try FileHandle(forWritingTo: file)
        let length: UInt64 = 4 * 1024 * 1024 * 1024 + 17
        try handle.truncate(atOffset: length) // Sparse fixture: no multi-GB repo or artifact.
        try handle.seek(toOffset: length - 1); try handle.write(contentsOf: Data([1])); try handle.close()
        var before = rusage(); getrusage(RUSAGE_SELF, &before)
        let digest = try ResourceExporter.hash(file)
        var after = rusage(); getrusage(RUSAGE_SELF, &after)
        XCTAssertEqual(digest.2, Int64(length))
        XCTAssertEqual(digest.0.count, 40); XCTAssertEqual(digest.1.count, 64)
        XCTAssertLessThan(after.ru_maxrss - before.ru_maxrss, 256 * 1024 * 1024)
    }
    func testHEICContainerRetainsImageAndUsesMpvdHeader() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let still = directory.appendingPathComponent("source.heic"), video = directory.appendingPathComponent("source.mov")
        let image = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64)).image { context in UIColor.blue.setFill(); context.fill(CGRect(x: 0, y: 0, width: 64, height: 64)) }
        guard let destination = CGImageDestinationCreateWithURL(still as CFURL, UTType.heic.identifier as CFString, 1, nil) else { throw XCTSkip("HEIC encoder unavailable in this simulator") }
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), nil)
        guard CGImageDestinationFinalize(destination) else { throw XCTSkip("HEIC encoding unsupported in this simulator") }
        let clip = Data("video-tail".utf8); try clip.write(to: video)
        let output = try MotionPhoto.mux(still: still, video: video, timestamp: 0, directory: directory)
        let data = try Data(contentsOf: output)
        XCTAssertEqual(data.suffix(clip.count), clip)
        XCTAssertEqual(String(decoding: data.dropLast(clip.count).suffix(4), as: UTF8.self), "mpvd")
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(output as CFURL, nil))
        XCTAssertNotNil(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let metadata = try XCTUnwrap(CGImageSourceCopyMetadataAtIndex(source, 0, nil))
        XCTAssertEqual(CGImageMetadataCopyStringValueWithPath(metadata, nil, "Camera:MotionPhoto" as CFString) as String?, "1")
    }
    func testKeyframeIsReadFromRealQuickTimeTimedMetadata() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mov")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
        let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
        writer.add(video)
        let identifier = "mdta/com.apple.quicktime.still-image-time"
        var format: CMFormatDescription?
        let specification: [String: Any] = [kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: identifier,
            kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_SInt8]
        XCTAssertEqual(CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed, metadataSpecifications: [specification] as CFArray, formatDescriptionOut: &format), noErr)
        let metadata = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: format)
        let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadata)
        writer.add(metadata)
        XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        let item = AVMutableMetadataItem(); item.identifier = AVMetadataIdentifier(rawValue: identifier)
        item.value = NSNumber(value: Int8(0)); item.dataType = kCMMetadataBaseDataType_SInt8 as String
        XCTAssertTrue(adaptor.append(AVTimedMetadataGroup(items: [item], timeRange: CMTimeRange(start: CMTime(value: 6, timescale: 24), duration: CMTime(value: 1, timescale: 24)))))
        metadata.markAsFinished()
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let pixel = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixel, [])
        if let pointer = CVPixelBufferGetBaseAddress(pixel) { memset(pointer, 0, CVPixelBufferGetDataSize(pixel)) }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        let deadline = Date(timeIntervalSinceNow: 20)
        for index in 0..<24 {
            while !video.isReadyForMoreMediaData && Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
            XCTAssertTrue(video.isReadyForMoreMediaData)
            XCTAssertTrue(pixels.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 24)))
        }
        video.markAsFinished(); await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed)
        let timestamp = try await MotionPhoto.presentationTime(url)
        XCTAssertEqual(timestamp, 250000)
    }
    func testRelaunchCannotResumeOtherAccountsOrManuallyPausedTransfers() {
        var job = BackupJob(account: "a", assetID: "asset", assetRevision: "1", settings: BackupSettings())
        job.state = .transferring
        XCTAssertEqual(job.transferDisposition(activeAccount: "a"), .run)
        XCTAssertEqual(job.transferDisposition(activeAccount: "b"), .pause)
        XCTAssertEqual(job.transferDisposition(activeAccount: ""), .pause)
        job.state = .paused
        XCTAssertEqual(job.transferDisposition(activeAccount: "a"), .pause)
        job.state = .cancelled
        XCTAssertEqual(job.transferDisposition(activeAccount: "a"), .cancel)
    }

}
