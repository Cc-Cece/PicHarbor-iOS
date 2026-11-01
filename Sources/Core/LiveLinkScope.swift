import Foundation
import Photos

extension LiveLinkScope {
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
        let selected: String
        switch mode {
        case "default": selected = L10n.text("默认范围：系统照片图库与截图")
        case "advanced": selected = L10n.text("已选相册 {0} 个", [String(albums.count)])
        default: selected = L10n.text("全部可访问媒体")
        }
        let type = photos && videos ? L10n.text("照片和视频") : photos ? L10n.text("照片（含实况）") : L10n.text("视频")
        let dates = dateEnabled ? L10n.text("日期：{0} 至 {1}", [from?.isEmpty == false ? from! : "…", to?.isEmpty == false ? to! : "…"]) : L10n.text("不限日期")
        return [selected, type, dates, ignoreSmallImages ? L10n.text("小图阈值 {0} KB，大小未知的原件仍保留", [String(minImageKb)]) : ""].filter { !$0.isEmpty }.joined(separator: " · ")
    }

}
struct LiveLinkAlbum: Codable { var id: String; var name: String; var count: Int; var bytes: Int64; var isDefault: Bool }
struct LiveLinkCatalogRequest: Codable { var revision: Int64; var scope: String }
struct LiveLinkCatalogReport: Codable {
    var revision: Int64; var timeZone: String; var albums: [LiveLinkAlbum]
    var count: Int; var bytes: Int64; var unknownSize: Int; var unknownDate: Int; var error: String?
}
