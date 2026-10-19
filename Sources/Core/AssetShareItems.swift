import Photos
import PhotosUI
import SwiftUI
import CoreTransferable
import UniformTypeIdentifiers
import ImageIO

enum AssetShareItems {
    static func livePhoto(files: [URL]) async throws -> PHLivePhoto {
        try await withCheckedThrowingContinuation { continuation in
            PHLivePhoto.request(withResourceFileURLs: files, placeholderImage: nil, targetSize: .zero, contentMode: .aspectFit) { photo, info in
                guard info[PHLivePhotoInfoIsDegradedKey] as? Bool != true else { return }
                if let photo { continuation.resume(returning: photo) }
                else { continuation.resume(throwing: HarborError("LIVE_PAIR_MISSING")) }
            }
        }
    }
    /// Exactly one logical item. Native Live Photo representation comes first;
    /// receivers that accept only a still image can request that representation.
    static func provider(files: [URL], live: PHLivePhoto?) throws -> NSItemProvider {
        guard let still = files.first else { throw HarborError("RESOURCE_MISSING") }
        let provider = NSItemProvider()
        if let live {
            provider.register(live)
            guard provider.registeredTypeIdentifiers.contains(where: { $0.contains("live-photo") }) else {
                throw HarborError("LIVE_SHARE_UNAVAILABLE")
            }
        }
        let type = UTType(filenameExtension: still.pathExtension) ?? .data
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { completion in
            completion(still, false, nil); return nil
        }
        if live != nil && type != .jpeg {
            let fallback = JPEGShareFallback(source: still)
            provider.registerFileRepresentation(forTypeIdentifier: UTType.jpeg.identifier, fileOptions: [], visibility: .all) { completion in
                do { completion(try fallback.file(), false, nil) } catch { completion(nil, false, error) }
                return nil
            }
        }
        provider.suggestedName = still.deletingPathExtension().lastPathComponent
        return provider
    }
}

private final class JPEGShareFallback: @unchecked Sendable {
    let source: URL
    private let lock = NSLock()
    init(source: URL) { self.source = source }
    func file() throws -> URL {
        try lock.withLock {
            let output = source.deletingLastPathComponent().appendingPathComponent("StaticFallback.jpg")
            if FileManager.default.fileExists(atPath: output.path) { return output }
            guard let input = CGImageSourceCreateWithURL(source as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(input, 0, nil),
                  let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { throw HarborError("FILE_ACCESS") }
            let properties = CGImageSourceCopyPropertiesAtIndex(input, 0, nil)
            CGImageDestinationAddImage(destination, image, properties)
            guard CGImageDestinationFinalize(destination) else { throw HarborError("FILE_ACCESS") }
            return output
        }
    }
}
