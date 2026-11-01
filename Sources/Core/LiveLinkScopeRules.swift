import Foundation

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
}

enum LiveLinkScopeError: Error { case invalid }
