import Foundation
import Photos
import ImageIO

/// Counts streamed bytes without retaining media data or using private KVC keys.
final class AssetByteRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var count: Int64 = 0
    private var request: PHAssetResourceDataRequestID?
    private var cancelled = false
    func cancel() {
        let id = lock.withLock { cancelled = true; return request }
        if let id { PHAssetResourceManager.default().cancelDataRequest(id) }
    }
    func size(_ resource: PHAssetResource, network: Bool) async throws -> Int64 {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = network
                let id = PHAssetResourceManager.default().requestData(for: resource, options: options) { data in
                    self.lock.withLock { self.count += Int64(data.count) }
                } completionHandler: { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: self.lock.withLock { self.count }) }
                }
                let stop = lock.withLock { request = id; return cancelled }
                if stop { PHAssetResourceManager.default().cancelDataRequest(id) }
            }
        } onCancel: { self.cancel() }
    }
}

enum AssetInformation {
    static func resources(_ asset: PHAsset) -> [PHAssetResource] {
        let values = PHAssetResource.assetResources(for: asset)
        let video = asset.mediaType == .video
        guard let primary = values.first(where: { $0.type == (video ? .fullSizeVideo : .fullSizePhoto) }) ?? values.first(where: { $0.type == (video ? .video : .photo) }) else { return [] }
        if !asset.mediaSubtypes.contains(.photoLive) { return [primary] }
        let type: PHAssetResourceType = primary.type == .fullSizePhoto ? .fullSizePairedVideo : .pairedVideo
        guard let paired = values.first(where: { $0.type == type }) else { return [] }
        return [primary, paired]
    }
    static func camera(_ asset: PHAsset) async -> [String: String] {
        guard asset.mediaType == .image else { return [:] }
        return await withCheckedContinuation { continuation in
            let options = PHContentEditingInputRequestOptions(); options.isNetworkAccessAllowed = false
            asset.requestContentEditingInput(with: options) { input, _ in
                guard let url = input?.fullSizeImageURL,
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let values = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { continuation.resume(returning: [:]); return }
                let tiff = values[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
                let exif = values[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
                var result: [String: String] = [:]
                if let value = tiff[kCGImagePropertyTIFFModel] as? String { result["camera"] = value }
                if let value = exif[kCGImagePropertyExifLensModel] as? String { result["lens"] = value }
                for (key, property) in [("aperture", kCGImagePropertyExifFNumber), ("exposure", kCGImagePropertyExifExposureTime), ("focal", kCGImagePropertyExifFocalLength), ("bias", kCGImagePropertyExifExposureBiasValue)] {
                    if let number = exif[property] as? NSNumber { result[key] = number.stringValue }
                }
                if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first { result["iso"] = iso.stringValue }
                continuation.resume(returning: result)
            }
        }
    }
}
