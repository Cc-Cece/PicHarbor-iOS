import Foundation
import UIKit
import Combine

struct GooglePhotosLink: Identifiable {
    let id: String
    let address: String
    let isLaunch: Bool
    var url: URL { URL(string: address)! }
    var title: String {
        switch id {
        case "launch": return L10n.text("启动应用")
        case "settings": return L10n.text("设置入口候选")
        case "devices": return L10n.text("设备设置候选")
        case "freeupspace": return L10n.text("释放空间候选 A")
        case "free-up-space": return L10n.text("释放空间候选 B")
        case "settings-freeupspace": return L10n.text("释放空间候选 C")
        default: return L10n.text("释放空间候选 D")
        }
    }
    // Only the root scheme is publicly listed. All paths below are hypotheses,
    // deliberately kept out of the product's main Open button.
    static let candidates: [GooglePhotosLink] = [
        .init(id: "launch", address: "googlephotos://", isLaunch: true),
        .init(id: "settings", address: "googlephotos://settings", isLaunch: false),
        .init(id: "devices", address: "googlephotos://settings/apps-and-devices", isLaunch: false),
        .init(id: "freeupspace", address: "googlephotos://freeupspace", isLaunch: false),
        .init(id: "free-up-space", address: "googlephotos://free-up-space", isLaunch: false),
        .init(id: "settings-freeupspace", address: "googlephotos://settings/freeupspace", isLaunch: false),
        .init(id: "settings-free-up-space", address: "googlephotos://settings/free-up-space", isLaunch: false)
    ]
    static var launch: GooglePhotosLink { candidates[0] }
}

enum LinkTestDestination: String, Codable, CaseIterable, Identifiable {
    case unrecorded, cleanup, home, other, failed
    var id: String { rawValue }
    var title: String {
        switch self {
        case .unrecorded: return L10n.text("尚未记录")
        case .cleanup: return L10n.text("到达释放空间页")
        case .home: return L10n.text("只打开首页")
        case .other: return L10n.text("打开其他页面")
        case .failed: return L10n.text("未能打开应用")
        }
    }
}

struct LinkTestRecord: Codable {
    var attempt = UUID()
    var date = Date()
    var accepted: Bool?
    var destination = LinkTestDestination.unrecorded
    var context = ""
    var appVersion: String
}

@MainActor
final class GooglePhotosLinkTestStore: ObservableObject {
    static let storageKey = "picharbor.googlephotos.link-tests.v1"
    @Published private(set) var records: [String: LinkTestRecord]
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.storageKey)
        records = saved.flatMap { try? JSONDecoder().decode([String: LinkTestRecord].self, from: $0) } ?? [:]
        records = records.filter { key, _ in GooglePhotosLink.candidates.contains { $0.id == key } }
    }
    @discardableResult
    func begin(_ link: GooglePhotosLink, context: String) -> UUID {
        let info = Bundle.main.infoDictionary ?? [:]
        let record = LinkTestRecord(context: context,
            appVersion: "\(info["CFBundleShortVersionString"] ?? "") (\(info["CFBundleVersion"] ?? ""))")
        records[link.id] = record; save(); return record.attempt
    }
    func finish(_ link: GooglePhotosLink, attempt: UUID, accepted: Bool) {
        guard records[link.id]?.attempt == attempt else { return }
        records[link.id]?.accepted = accepted; save()
    }
    func record(_ destination: LinkTestDestination, for link: GooglePhotosLink) {
        guard records[link.id] != nil else { return }
        records[link.id]?.destination = destination; save()
    }
    func clear() { records = [:]; defaults.removeObject(forKey: Self.storageKey) }
    private func save() { if let data = try? JSONEncoder().encode(records) { defaults.set(data, forKey: Self.storageKey) } }
    var report: String {
        var lines = ["PicHarbor Google Photos link tests v1", "iOS: \(UIDevice.current.systemVersion)",
                     "Google Photos version / backup setting / cold or warm launch: please add manually."]
        for link in GooglePhotosLink.candidates {
            guard let record = records[link.id] else { continue }
            lines.append("\(link.id): \(link.address) | app=\(record.appVersion) | context=\(record.context) | time=\(ISO8601DateFormatter().string(from: record.date)) | systemAccepted=\(record.accepted.map { String($0) } ?? "unknown") | destination=\(record.destination.rawValue)")
        }
        return lines.joined(separator: "\n")
    }
}

@MainActor
enum GooglePhotosLauncher {
    static let appStore = URL(string: "https://apps.apple.com/app/id962194608")!
    static func open(_ url: URL, completion: @escaping (Bool) -> Void) {
        guard GooglePhotosLink.candidates.contains(where: { $0.url == url }), UIApplication.shared.canOpenURL(url) else {
            completion(false); return
        }
        UIApplication.shared.open(url, options: [:], completionHandler: completion)
    }
}
