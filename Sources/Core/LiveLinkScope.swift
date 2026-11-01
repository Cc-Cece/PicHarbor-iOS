import Foundation
import Photos

struct LiveLinkScope: Codable {
    var mode: String = "all"
    var albums: [String] = []
    var dateEnabled: Bool = false
    var from: String?
    var to: String?
    var photos: Bool = true
    var videos: Bool = true
    var ignoreSmallImages: Bool = false
    var minImageKb: Int = 100
    var filterCache: Bool = false

    static func parse(_ wire: String) throws -> LiveLinkScope {
        var value = LiveLinkScope()
        if wire.hasPrefix("scope2:") {
            value = try JSONDecoder().decode(Self.self, from: Data(wire.dropFirst(7).utf8))
        } else if wire.hasPrefix("range:") {
            let parts = wire.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3 else { throw LiveLinkFailure.form }
            value.mode = "date"; value.dateEnabled = true; value.from = parts[1]; value.to = parts[2]
        } else if !["all", "library", "selected"].contains(wire) { throw LiveLinkFailure.form }
        guard ["default", "all", "date", "advanced"].contains(value.mode), value.photos || value.videos,
              (value.mode != "advanced" || !value.albums.isEmpty), (10...1024).contains(value.minImageKb) else { throw LiveLinkFailure.form }
        if value.dateEnabled {
            for date in [value.from, value.to].compactMap({ $0 }).filter({ !$0.isEmpty }) {
                guard let parsed = formatter.date(from: date), formatter.string(from: parsed) == date else { throw LiveLinkFailure.form }
            }
            if let from = value.from, let to = value.to, !from.isEmpty, !to.isEmpty, from > to { throw LiveLinkFailure.form }
        }
        return value
    }
    static var formatter: DateFormatter {
        let value = DateFormatter(); value.calendar = Calendar(identifier: .gregorian)
        value.locale = Locale(identifier: "en_US_POSIX"); value.timeZone = .current
        value.dateFormat = "yyyy-MM-dd"; value.isLenient = false
        return value
    }
    func includesDate(_ value: Date?) -> Bool {
        if !dateEnabled { return true }
        guard let value else { return false }
        if let from, let start = Self.formatter.date(from: from), value < start { return false }
        if let to, let date = Self.formatter.date(from: to), let end = Calendar.current.date(byAdding: .day, value: 1, to: date), value >= end { return false }
        return true
    }
    static func resourceKey(_ asset: PHAsset, role: String) -> String {
        let stamp = asset.modificationDate.map { $0.timeIntervalSince1970.bitPattern } ?? 0
        return asset.localIdentifier + "\n" + String(stamp) + "\n" + role
    }
    static func knownSizes(_ assets: [PHAsset]) -> [String: Int64] {
        struct Entry: Decodable { var size: Int64 }
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PicHarbor/LiveLink/hashes.json")
        guard let data = try? Data(contentsOf: url), let cache = try? JSONDecoder().decode([String: Entry].self, from: data) else { return [:] }
        var result: [String: Int64] = [:]
        for asset in assets {
            let parts = LiveLinkFiles.parts(asset)
            let sizes = parts.compactMap { cache[resourceKey(asset, role: $0.1)]?.size }
            if !parts.isEmpty && sizes.count == parts.count && sizes.allSatisfy({ $0 > 0 }) { result[asset.localIdentifier] = sizes.reduce(0, +) }
        }
        return result
    }
    static func groups() -> [(album: LiveLinkAlbum, ids: Set<String>)] {
        var result: [(LiveLinkAlbum, Set<String>)] = []
        for type in [PHAssetCollectionType.smartAlbum, .album] {
            PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil).enumerateObjects { collection, _, _ in
                let options = PHFetchOptions()
                options.predicate = NSPredicate(format: "mediaType == %d OR mediaType == %d", PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue)
                var ids = Set<String>()
                PHAsset.fetchAssets(in: collection, options: options).enumerateObjects { asset, _, _ in ids.insert(asset.localIdentifier) }
                guard !ids.isEmpty else { return }
                let preferred = collection.assetCollectionSubtype == .smartAlbumUserLibrary || collection.assetCollectionSubtype == .smartAlbumScreenshots
                result.append((LiveLinkAlbum(id: collection.localIdentifier, name: collection.localizedTitle ?? "Photos", count: ids.count, bytes: 0, isDefault: preferred), ids))
            }
        }
        return result
    }
    func select(_ assets: [PHAsset], groups: [(album: LiveLinkAlbum, ids: Set<String>)]) -> [PHAsset] {
        let chosen = groups.filter { mode == "default" ? $0.album.isDefault : albums.contains($0.album.id) }
        let ids = chosen.reduce(into: Set<String>()) { $0.formUnion($1.ids) }
        let known = Self.knownSizes(assets)
        return assets.filter { asset in
            if mode == "advanced" && !ids.contains(asset.localIdentifier) { return false }
            if mode == "default" && !ids.isEmpty && !ids.contains(asset.localIdentifier) { return false }
            if asset.mediaType == .image && !photos || asset.mediaType == .video && !videos { return false }
            if !includesDate(asset.creationDate ?? asset.modificationDate) { return false }
            if ignoreSmallImages, asset.mediaType == .image, !asset.mediaSubtypes.contains(.photoLive),
               let size = known[asset.localIdentifier], size < Int64(minImageKb) * 1024 { return false }
            // Only revision-matched public export history supplies byte sizes. Unknown originals stay included.
            return true
        }
    }
    var summary: String {
        let type = photos && videos ? "Photos and videos" : photos ? "Photos (including Live Photos)" : "Videos"
        return "\(mode) · \(type)" + (dateEnabled ? " · \(from ?? "") – \(to ?? "")" : "")
    }
}
struct LiveLinkAlbum: Codable { var id: String; var name: String; var count: Int; var bytes: Int64; var isDefault: Bool }
struct LiveLinkCatalogRequest: Codable { var revision: Int64; var scope: String }
struct LiveLinkCatalogReport: Codable {
    var revision: Int64; var timeZone: String; var albums: [LiveLinkAlbum]
    var count: Int; var bytes: Int64; var unknownSize: Int; var unknownDate: Int; var error: String?
}
