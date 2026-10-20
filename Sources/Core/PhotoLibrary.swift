import Photos
import PhotosUI
import SwiftUI
import CryptoKit

struct LibraryAlbum: Identifiable {
    var id: String
    var title: String
    var count: Int
}

@MainActor
final class PhotoLibrary: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published var assets: [PHAsset] = []
    @Published var albums: [LibraryAlbum] = []
    @Published var status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @Published var revision = 0
    @Published var refreshing = false
    @Published private(set) var changedIdentifiers = Set<String>()
    @Published private(set) var historyAvailable = false
    let images = PHCachingImageManager()
    private var registered = false
    private var refreshingAgain = false
    private var cachedScope: (ids: [String], revision: Int, assets: [PHAsset])?
    private struct FilterKey: Equatable {
        var libraryRevision: Int
        var account: String
        var completedRevision: Int
        var album: String
        var media: String
        var backup: LibraryBackupFilter
    }
    private var cachedFilter: (key: FilterKey, assets: [PHAsset])?
    func filteredAssets(album: String, media: String, backup: LibraryBackupFilter, account: String, completed: CompletedAssetIndex) -> [PHAsset] {
        let key = FilterKey(libraryRevision: revision, account: account, completedRevision: backup == .all ? 0 : completed.revision, album: album, media: media, backup: backup)
        if let cachedFilter, cachedFilter.key == key { return cachedFilter.assets }
        var settings = BackupSettings(); settings.selectedAlbums = album.isEmpty ? [] : [album]
        let values = scope(settings).filter { asset in
            guard media == "all" || (media == "video" ? asset.mediaType == .video : media == "live" ? asset.mediaSubtypes.contains(.photoLive) : asset.mediaType == .image) else { return false }
            return backup == .all || backup.includes(backedUp: completed.contains(assetID: asset.localIdentifier, revision: Self.stamp(asset), account: account))
        }
        cachedFilter = (key, values)
        return values
    }
    func authorize() async {
        status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        await refresh()
    }
    func refresh() async {
        status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { assets = []; albums = []; return }
        if refreshing { refreshingAgain = true; return }
        refreshing = true
        let historyToken = PHPhotoLibrary.shared().currentChangeToken
        changedIdentifiers = []
        historyAvailable = false
        if let data = UserDefaults.standard.data(forKey: "photoChangeToken"),
           let previous = try? NSKeyedUnarchiver.unarchivedObject(ofClass: PHPersistentChangeToken.self, from: data) {
            do {
                let history = try PHPhotoLibrary.shared().fetchPersistentChanges(since: previous)
                for change in history {
                    let details = try change.changeDetails(for: .asset)
                    changedIdentifiers.formUnion(details.insertedLocalIdentifiers)
                    changedIdentifiers.formUnion(details.updatedLocalIdentifiers)
                }
                historyAvailable = true
            } catch { /* Expired/unavailable history uses the complete reconciliation below. */ }
        }
        if !registered { PHPhotoLibrary.shared().register(self); registered = true }
        let snapshot = await Task.detached(priority: .userInitiated) { () -> ([PHAsset], [LibraryAlbum]) in
            let options = PHFetchOptions()
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
            var values: [PHAsset] = []
            PHAsset.fetchAssets(with: options).enumerateObjects { asset, _, _ in values.append(asset) }
            var groups: [LibraryAlbum] = []
            PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil).enumerateObjects { collection, _, _ in
                groups.append(LibraryAlbum(id: collection.localIdentifier, title: collection.localizedTitle ?? L10n.text("相簿"), count: PHAsset.fetchAssets(in: collection, options: nil).count))
            }
            return (values, groups.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
        }.value
        assets = snapshot.0; albums = snapshot.1; revision += 1; refreshing = false
        if let encoded = try? NSKeyedArchiver.archivedData(withRootObject: historyToken, requiringSecureCoding: true) {
            UserDefaults.standard.set(encoded, forKey: "photoChangeToken")
        }
        // Reconciliation at every launch also covers expired history and permission changes.
        if refreshingAgain { refreshingAgain = false; await refresh() }
    }
    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in await self?.refresh() }
    }
    func scope(_ settings: BackupSettings) -> [PHAsset] {
        guard !settings.selectedAlbums.isEmpty else { return assets }
        if let cachedScope, cachedScope.ids == settings.selectedAlbums, cachedScope.revision == revision { return cachedScope.assets }
        var ids = Set<String>()
        for id in settings.selectedAlbums {
            if let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject {
                PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
            }
        }
        let values = assets.filter { ids.contains($0.localIdentifier) }
        cachedScope = (settings.selectedAlbums, revision, values)
        return values
    }
    func memberships(for ids: Set<String>) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for album in albums {
            guard let group = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [album.id], options: nil).firstObject else { continue }
            PHAsset.fetchAssets(in: group, options: nil).enumerateObjects { asset, _, _ in
                if ids.contains(asset.localIdentifier) { result[asset.localIdentifier, default: []].append(album.id) }
            }
        }
        return result
    }
    func membershipsAsync(for ids: Set<String>) async -> [String: [String]] {
        let albumIDs = albums.map(\.id)
        return await Task.detached(priority: .utility) {
            var result: [String: [String]] = [:]
            for id in albumIDs {
                guard let group = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject else { continue }
                PHAsset.fetchAssets(in: group, options: nil).enumerateObjects { asset, _, _ in
                    if ids.contains(asset.localIdentifier) { result[asset.localIdentifier, default: []].append(id) }
                }
            }
            return result
        }.value
    }
    static func stamp(_ asset: PHAsset) -> String {
        "\(asset.modificationDate?.timeIntervalSince1970 ?? 0):\(asset.pixelWidth):\(asset.pixelHeight):\(asset.duration):\(asset.mediaSubtypes.rawValue)"
    }
    static func preparationStamp(_ asset: PHAsset) -> String {
        let manifest = PHAssetResource.assetResources(for: asset).map {
            "\($0.type.rawValue):\($0.uniformTypeIdentifier):\($0.originalFilename)"
        }.sorted().joined(separator: "|")
        return stamp(asset) + "|" + manifest
    }
    func manageLimited() {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              var controller = scene.windows.first(where: \.isKeyWindow)?.rootViewController else { return }
        while let presented = controller.presentedViewController { controller = presented }
        PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller)
    }
}

enum ResourceExporter {
    static func export(assetID: String, settings: BackupSettings, directory: URL, control: ExportControl? = nil) async throws -> [MediaResource] {
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil).firstObject else { throw HarborError("PHOTO_PERMISSION") }
        let resources = PHAssetResource.assetResources(for: asset)
        let live = asset.mediaSubtypes.contains(.photoLive)
        let video = asset.mediaType == .video
        guard asset.mediaType == .image || video else { throw HarborError("UNSUPPORTED_MEDIA") }
        var result: [MediaResource] = []
        let versions = settings.edits == .both ? ["original", "current"] : [settings.edits.rawValue]
        for version in versions {
            let current = version == "current"
            let originalType: PHAssetResourceType = video ? .video : .photo
            let currentType: PHAssetResourceType = video ? .fullSizeVideo : .fullSizePhoto
            guard let image = resources.first(where: { $0.type == (current ? currentType : originalType) }) ?? resources.first(where: { $0.type == originalType }) else { throw HarborError("RESOURCE_MISSING") }
            var pair = [(image, "\(version).\(video ? "video" : "photo")")]
            if live {
                // Never mix edited stills with an original paired video.
                let desired: PHAssetResourceType = current && image.type == .fullSizePhoto ? .fullSizePairedVideo : .pairedVideo
                guard let clip = resources.first(where: { $0.type == desired }) else { throw HarborError("LIVE_PAIR_MISSING") }
                pair.append((clip, "\(version).pairedVideo"))
            }
            for (resource, role) in pair {
                try Task.checkCancellation()
                let name = (resource.originalFilename as NSString).lastPathComponent
                let path = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension((name as NSString).pathExtension)
                try await PhotoResourceWriter.write(resource: resource, url: path, control: control)
                let digest = try await hashAsync(path)
                result.append(MediaResource(role: role, path: path.path, name: name, sha1: digest.0, sha256: digest.1, size: digest.2))
            }
        }
        // Keep one representation only when the complete version resource set matches.
        if settings.edits == .both {
            let original = result.filter { $0.role.hasPrefix("original.") }.map { $0.sha256 }.sorted()
            let current = result.filter { $0.role.hasPrefix("current.") }.map { $0.sha256 }.sorted()
            if original == current {
                for resource in result where resource.role.hasPrefix("current.") { try? FileManager.default.removeItem(atPath: resource.path) }
                result.removeAll { $0.role.hasPrefix("current.") }
            }
        }
        return result
    }
    static func hashAsync(_ url: URL) async throws -> (String, String, Int64) {
        let lease = BackupExecutionContext.lease
        return try await Task.detached { try hash(url, lease: lease) }.value
    }
    static func hash(_ url: URL, lease: BackupExecutionLease? = nil) throws -> (String, String, Int64) {
        let before = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        var sha1 = Insecure.SHA1(), sha256 = SHA256(), size: Int64 = 0
        while true {
            let count = try autoreleasepool { () throws -> Int in
                try Task.checkCancellation()
                try lease?.check()
                guard let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty else { return 0 }
                sha1.update(data: data); sha256.update(data: data); size += Int64(data.count)
                lease?.progress()
                return data.count
            }
            if count == 0 { break }
        }
        let after = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate, size == Int64(before.fileSize ?? -1), size > 0 else { throw HarborError("SOURCE_CHANGED") }
        return (sha1.finalize().map { String(format: "%02x", $0) }.joined(), sha256.finalize().map { String(format: "%02x", $0) }.joined(), size)
    }
}
