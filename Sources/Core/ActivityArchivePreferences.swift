import Foundation
import Combine

@MainActor
final class ActivityArchivePreferences: ObservableObject {
    static let shared = ActivityArchivePreferences()
    private let defaults: UserDefaults
    @Published var enabled: Bool { didSet { defaults.set(enabled, forKey: "activity.archive.enabled") } }
    @Published private(set) var days: Int
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        enabled = defaults.object(forKey: "activity.archive.enabled") as? Bool ?? true
        let stored = defaults.integer(forKey: "activity.archive.days")
        days = (1...90).contains(stored) ? stored : 14
    }
    @discardableResult
    func setDays(_ text: String) -> Bool {
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let value = Int(text), (1...90).contains(value) else { return false }
        days = value; defaults.set(value, forKey: "activity.archive.days"); return true
    }
}
