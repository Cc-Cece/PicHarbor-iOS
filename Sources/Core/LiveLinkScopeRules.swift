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
            guard parts.count == 3 else { throw LiveLinkScopeError.invalid }
            value.mode = "date"; value.dateEnabled = true; value.from = parts[1]; value.to = parts[2]
        } else if !["all", "library", "selected"].contains(wire) { throw LiveLinkScopeError.invalid }
        guard ["default", "all", "date", "advanced"].contains(value.mode), value.photos || value.videos,
              (value.mode != "advanced" || !value.albums.isEmpty), (10...1024).contains(value.minImageKb) else { throw LiveLinkScopeError.invalid }
        if value.dateEnabled {
            for date in [value.from, value.to].compactMap({ $0 }).filter({ !$0.isEmpty }) {
                guard let parsed = formatter.date(from: date), formatter.string(from: parsed) == date else { throw LiveLinkScopeError.invalid }
            }
            if let from = value.from, let to = value.to, !from.isEmpty, !to.isEmpty, from > to { throw LiveLinkScopeError.invalid }
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

    /// Scope as a shared-core `evaluate_scope` / `livelink_scope`
    /// dict — the same fields, the same meaning, on both ends.
    /// `version` is 2 (scope2): a core that does not know this scope
    /// version must error, and the caller must then exclude the asset
    /// — never fall back to the full library.
    var scopeDictionary: [String: Any] {
        var value: [String: Any] = [
            "version": 2,
            "mode": mode,
            "albums": albums,
            "dateEnabled": dateEnabled,
            "photos": photos,
            "videos": videos,
            "ignoreSmallImages": ignoreSmallImages,
            "minImageKb": minImageKb,
            "filterCache": filterCache,
        ]
        value["from"] = from ?? NSNull()
        value["to"] = to ?? NSNull()
        return value
    }

    /// One asset as a shared-core `evaluate_scope` / `livelink_scope`
    /// asset dict. `albums` are the asset's album memberships (the
    /// core needs them to judge `advanced` scopes); `size` is the
    /// known byte size when available — an unknown size stays included
    /// under `ignoreSmallImages`, per the core's semantics.
    static func assetDictionary(for asset: PHAsset, albumIDs: [String], size: Int64?) -> [String: Any] {
        var value: [String: Any] = [
            "local_id": asset.localIdentifier,
            "media_kind": asset.mediaType == .video ? "video"
                : asset.mediaSubtypes.contains(.photoLive) ? "live_photo" : "photo",
            "albums": albumIDs,
        ]
        if let created = asset.creationDate ?? asset.modificationDate {
            value["created_at"] = Self.formatter.string(from: created)
        }
        if asset.mediaType == .video { value["duration_seconds"] = asset.duration }
        if let size { value["size"] = size }
        return value
    }
}

enum LiveLinkScopeError: Error { case invalid }
