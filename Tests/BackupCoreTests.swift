import XCTest
import ImageIO
import UIKit
import Darwin
import AVFoundation
import UniformTypeIdentifiers
import Photos
@testable import PicHarbor

final class BackupCoreTests: XCTestCase {
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

    func testPhotoKitExportKeepsReadableOriginalAfterVersionDeduplication() async throws {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let asset = try XCTUnwrap(PHAsset.fetchAssets(with: options).firstObject, "CI photo authorization: \(PHPhotoLibrary.authorizationStatus(for: .readWrite).rawValue)")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let resources = try await ResourceExporter.export(assetID: asset.localIdentifier, settings: BackupSettings(), directory: directory)
        XCTAssertFalse(resources.isEmpty)
        for resource in resources {
            let digest = try ResourceExporter.hash(URL(fileURLWithPath: resource.path))
            XCTAssertEqual(digest.1, resource.sha256)
            XCTAssertEqual(digest.2, resource.size)
        }
    }
}
