import XCTest
import Photos
import PhotosUI
import SwiftUI
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import CoreTransferable
import UIKit
@testable import PicHarbor

final class LivePhotoShareTests: XCTestCase {
    @MainActor
    func testOneItemOffersNativeLivePhotoAndStaticFallback() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try await fixture(folder)
        let live = try await AssetShareItems.livePhoto(files: files)
        let probe = NSItemProvider(); probe.register(live)
        print("Native Live Photo export types:", probe.registeredTypeIdentifiers)
        let provider = try AssetShareItems.provider(files: files, live: live)
        XCTAssertTrue(provider.registeredTypeIdentifiers.contains { $0.contains("live-photo") })
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.jpeg.identifier))
        let received: PHLivePhoto = try await withCheckedThrowingContinuation { continuation in
            provider.loadTransferable(type: PHLivePhoto.self) { continuation.resume(with: $0) }
        }
        XCTAssertEqual(received.size, live.size)
        let resources = PHAssetResource.assetResources(for: received)
        XCTAssertTrue(resources.contains { $0.type == .photo })
        XCTAssertTrue(resources.contains { $0.type == .pairedVideo })
        let configuration = UIActivityItemsConfiguration(itemProviders: [provider])
        XCTAssertEqual(configuration.itemProvidersForActivityItemsConfiguration.count, 1)
    }
    private func fixture(_ folder: URL) async throws -> [URL] {
        let identifier = UUID().uuidString
        let imageURL = folder.appendingPathComponent("Fixture.jpg"), movieURL = folder.appendingPathComponent("Fixture.mov")
        let context = try XCTUnwrap(CGContext(data: nil, width: 320, height: 320, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(UIColor.blue.cgColor); context.fill(CGRect(x: 0, y: 0, width: 320, height: 320))
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(imageURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), [kCGImagePropertyMakerAppleDictionary: ["17": identifier]] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let writer = try AVAssetWriter(outputURL: movieURL, fileType: .mov)
        let idMetadata = AVMutableMetadataItem(); idMetadata.identifier = .quickTimeMetadataContentIdentifier
        idMetadata.value = identifier as NSString; idMetadata.dataType = kCMMetadataBaseDataType_UTF8 as String
        writer.metadata = [idMetadata]
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 320])
        let pixels = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 320])
        writer.add(video)
        let key = "mdta/com.apple.quicktime.still-image-time"
        var format: CMFormatDescription?
        let specification: [String: Any] = [kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier as String: key, kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType as String: kCMMetadataBaseDataType_SInt8]
        XCTAssertEqual(CMMetadataFormatDescriptionCreateWithMetadataSpecifications(allocator: kCFAllocatorDefault, metadataType: kCMMetadataFormatType_Boxed, metadataSpecifications: [specification] as CFArray, formatDescriptionOut: &format), noErr)
        let metadata = AVAssetWriterInput(mediaType: .metadata, outputSettings: nil, sourceFormatHint: format)
        let adaptor = AVAssetWriterInputMetadataAdaptor(assetWriterInput: metadata); writer.add(metadata)
        XCTAssertTrue(writer.startWriting()); writer.startSession(atSourceTime: .zero)
        let item = AVMutableMetadataItem(); item.identifier = AVMetadataIdentifier(rawValue: key)
        item.value = NSNumber(value: Int8(0)); item.dataType = kCMMetadataBaseDataType_SInt8 as String
        XCTAssertTrue(adaptor.append(AVTimedMetadataGroup(items: [item], timeRange: CMTimeRange(start: CMTime(value: 45, timescale: 30), duration: CMTime(value: 1, timescale: 30)))))
        metadata.markAsFinished()
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 320, 320, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let pixel = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixel, [])
        if let pointer = CVPixelBufferGetBaseAddress(pixel) { memset(pointer, 0, CVPixelBufferGetDataSize(pixel)) }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        let deadline = Date(timeIntervalSinceNow: 20)
        for index in 0..<90 {
            while !video.isReadyForMoreMediaData && Date() < deadline { try await Task.sleep(for: .milliseconds(2)) }
            guard video.isReadyForMoreMediaData else { throw HarborError("FILE_ACCESS") }
            XCTAssertTrue(pixels.append(pixel, withPresentationTime: CMTime(value: Int64(index), timescale: 30)))
        }
        video.markAsFinished(); await writer.finishWriting(); XCTAssertEqual(writer.status, .completed)
        return [imageURL, movieURL]
    }
}
