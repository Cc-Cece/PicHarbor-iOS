import Foundation
import ImageIO
import AVFoundation
import UniformTypeIdentifiers

/// Format implementation; MotionPhoto2 is a read-only reference, not a runtime dependency.
enum MotionPhoto {
    static let version = 1
    static func package(_ resources: [MediaResource], directory: URL) async throws -> [MediaResource] {
        let lease = BackupExecutionContext.lease
        var result: [MediaResource] = []
        for version in ["original", "current"] {
            guard let still = resources.first(where: { $0.role == "\(version).photo" }) else { continue }
            guard let clip = resources.first(where: { $0.role == "\(version).pairedVideo" }) else { throw HarborError("LIVE_PAIR_MISSING") }
            let timestamp = try await presentationTime(URL(fileURLWithPath: clip.path), lease: lease)
            let output = try await Task.detached(priority: .userInitiated) {
                try mux(still: URL(fileURLWithPath: still.path), video: URL(fileURLWithPath: clip.path), timestamp: timestamp, directory: directory, lease: lease)
            }.value
            let hash = try await ResourceExporter.hashAsync(output)
            let base = (still.name as NSString).deletingPathExtension
            result.append(MediaResource(role: "\(version).motion", path: output.path,
                name: "\(base)_\(version)_MP.\(output.pathExtension)", sha1: hash.0, sha256: hash.1, size: hash.2))
        }
        guard !result.isEmpty else { throw HarborError("LIVE_PAIR_MISSING") }
        return result
    }
    static func presentationTime(_ url: URL, lease: BackupExecutionLease? = nil) async throws -> Int64 {
        let asset = AVURLAsset(url: url)
        let request = UUID().uuidString
        lease?.register(request) { _ in asset.cancelLoading() }
        defer { lease?.unregister(request) }
        for track in try await asset.loadTracks(withMediaType: .metadata) {
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
            guard reader.canAdd(output) else { continue }
            reader.add(output)
            let adaptor = AVAssetReaderOutputMetadataAdaptor(assetReaderTrackOutput: output)
            guard reader.startReading() else { continue }
            while let group = adaptor.nextTimedMetadataGroup() {
                do { try lease?.check() } catch { reader.cancelReading(); throw error }
                if group.items.contains(where: { $0.identifier?.rawValue.contains("still-image-time") == true || ($0.key as? String)?.contains("still-image-time") == true }) {
                    reader.cancelReading()
                    let seconds = CMTimeGetSeconds(group.timeRange.start)
                    guard seconds.isFinite && seconds >= 0 else { throw HarborError("LIVE_KEYFRAME_INVALID") }
                    return Int64((seconds * 1_000_000).rounded())
                }
            }
            reader.cancelReading()
        }
        // A missing Apple keyframe must be visible; choosing the midpoint silently loses semantics.
        throw HarborError("LIVE_KEYFRAME_MISSING")
    }
    static func mux(still: URL, video: URL, timestamp: Int64, directory: URL, lease: BackupExecutionLease? = nil) throws -> URL {
        try lease?.check()
        guard timestamp >= 0, let source = CGImageSourceCreateWithURL(still as CFURL, nil),
              let type = CGImageSourceGetType(source) else { throw HarborError("MOTION_FORMAT_UNSUPPORTED") }
        let isJPEG = UTType(type as String)?.conforms(to: .jpeg) == true
        let isHEIC = UTType(type as String)?.conforms(to: .heic) == true
        guard isJPEG || isHEIC else { throw HarborError("MOTION_FORMAT_UNSUPPORTED") }
        let length = Int64(try video.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard length > 0, !isHEIC || length <= Int64(UInt32.max) - 8 else { throw HarborError("MOTION_FORMAT_UNSUPPORTED") }
        let mime = isJPEG ? "image/jpeg" : "image/heic"
        let videoMime = video.pathExtension.lowercased() == "mp4" ? "video/mp4" : "video/quicktime"
        let packet = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description xmlns:Camera="http://ns.google.com/photos/1.0/camera/" xmlns:Container="http://ns.google.com/photos/1.0/container/" xmlns:Item="http://ns.google.com/photos/1.0/container/item/" Camera:MotionPhoto="1" Camera:MotionPhotoVersion="1" Camera:MotionPhotoPresentationTimestampUs="\(timestamp)"><Container:Directory><rdf:Seq><rdf:li rdf:parseType="Resource"><Container:Item Item:Mime="\(mime)" Item:Semantic="Primary" Item:Padding="\(isHEIC ? 8 : 0)"/></rdf:li><rdf:li rdf:parseType="Resource"><Container:Item Item:Mime="\(videoMime)" Item:Semantic="MotionPhoto" Item:Length="\(length)"/></rdf:li></rdf:Seq></Container:Directory></rdf:Description></rdf:RDF></x:xmpmeta>
        """
        guard let additions = CGImageMetadataCreateFromXMPData(Data(packet.utf8) as CFData),
              let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil).flatMap({ CGImageMetadataCreateMutableCopy($0) }) ?? CGImageMetadataCreateMutable() as CGMutableImageMetadata? else { throw HarborError("MOTION_METADATA_ERROR") }
        var registrationError: Unmanaged<CFError>?
        guard CGImageMetadataRegisterNamespaceForPrefix(metadata, "http://ns.google.com/photos/1.0/camera/" as CFString, "Camera" as CFString, &registrationError),
              CGImageMetadataRegisterNamespaceForPrefix(metadata, "http://ns.google.com/photos/1.0/container/" as CFString, "Container" as CFString, &registrationError),
              CGImageMetadataRegisterNamespaceForPrefix(metadata, "http://ns.google.com/photos/1.0/container/item/" as CFString, "Item" as CFString, &registrationError) else { throw HarborError("MOTION_METADATA_ERROR") }
        var mergeOK = true
        CGImageMetadataEnumerateTagsUsingBlock(additions, nil, nil) { path, tag in
            if !CGImageMetadataSetTagWithPath(metadata, nil, path, tag) { mergeOK = false }
            return true
        }
        guard mergeOK else { throw HarborError("MOTION_METADATA_ERROR") }
        let url = directory.appendingPathComponent(UUID().uuidString + "_MP").appendingPathExtension(isJPEG ? "jpg" : "heic")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type, 1, nil) else { throw HarborError("FILE_ACCESS") }
        var copyError: Unmanaged<CFError>?
        // ImageIO copies encoded image data and merges metadata; no JPEG conversion/re-encoding.
        guard CGImageDestinationCopyImageSource(destination, source, [kCGImageDestinationMetadata: metadata, kCGImageDestinationMergeMetadata: true] as CFDictionary, &copyError) else { throw HarborError("MOTION_METADATA_ERROR") }
        let output = try FileHandle(forWritingTo: url); defer { try? output.close() }
        try output.seekToEnd()
        if isHEIC {
            var size = UInt32(length + 8).bigEndian
            try output.write(contentsOf: withUnsafeBytes(of: &size) { Data($0) })
            try output.write(contentsOf: Data("mpvd".utf8))
        }
        let input = try FileHandle(forReadingFrom: video); defer { try? input.close() }
        var copied: Int64 = 0
        while true {
            let count = try autoreleasepool { () throws -> Int in
                try Task.checkCancellation()
                try lease?.check()
                guard let block = try input.read(upToCount: 1024 * 1024), !block.isEmpty else { return 0 }
                try output.write(contentsOf: block); copied += Int64(block.count)
                lease?.progress()
                return block.count
            }
            if count == 0 { break }
        }
        guard copied == length else { throw HarborError("SOURCE_CHANGED") }
        try output.synchronize()
        return url
    }
}
