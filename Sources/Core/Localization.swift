import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, simplified = "zh-Hans", english = "en", cantonese = "yue-Hant-HK"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return L10n.text("跟随系统")
        case .simplified: return "简体中文"
        case .english: return "English"
        case .cantonese: return "粵語（香港）"
        }
    }
    static func resolved(_ selection: String, preferred: [String] = Locale.preferredLanguages) -> AppLanguage {
        if let explicit = AppLanguage(rawValue: selection), explicit != .system { return explicit }
        for language in preferred {
            let value = language.lowercased()
            if value.hasPrefix("yue") || value.hasPrefix("zh-hant") || value.hasPrefix("zh-hk") || value.hasPrefix("zh-mo") || value.hasPrefix("zh-tw") { return .cantonese }
            if value.hasPrefix("zh") { return .simplified }
            if value.hasPrefix("en") { return .english }
        }
        return .english
    }
    var resource: String { self == .cantonese ? "zh-Hant-HK" : rawValue }
    var locale: Locale { Locale(identifier: self == .cantonese ? "zh_Hant_HK" : rawValue) }
}

@MainActor final class LanguagePreferences: ObservableObject {
    static let shared = LanguagePreferences()
    @Published var selection: String {
        didSet { UserDefaults.standard.set(selection, forKey: "picharbor.language") }
    }
    init() { selection = UserDefaults.standard.string(forKey: "picharbor.language") ?? "system" }
}

enum L10n {
    private static let messageKeys: [String: String] = {
        guard let url = Bundle.main.url(forResource: "MessageKeys", withExtension: "json"),
              let data = try? Data(contentsOf: url), let keys = try? JSONDecoder().decode([String].self, from: data) else { return [:] }
        var result: [String: String] = [:]
        for key in keys where !key.contains("{0}") {
            for language in [AppLanguage.simplified, .english, .cantonese] { result[text(key, language: language)] = key }
        }
        return result
    }()
    static func message(_ value: String) -> String { messageKeys[value].map { text($0) } ?? value }
    static var language: AppLanguage { AppLanguage.resolved(UserDefaults.standard.string(forKey: "picharbor.language") ?? "system") }
    static var locale: Locale { language.locale }
    static func text(_ key: String, _ values: [String] = [], language: AppLanguage? = nil) -> String {
        let selected = language ?? self.language
        let bundle = Bundle.main.path(forResource: selected.resource, ofType: "lproj").flatMap(Bundle.init(path:))
        let format = bundle?.localizedString(forKey: key, value: key, table: nil) ?? key
        // Substitute once: user filenames/album names containing {0} remain literal.
        guard let pattern = try? NSRegularExpression(pattern: #"\{(\d+)\}"#) else { return format }
        let output = NSMutableString(string: format)
        for match in pattern.matches(in: format, range: NSRange(format.startIndex..., in: format)).reversed() {
            let index = Int((format as NSString).substring(with: match.range(at: 1))) ?? -1
            if values.indices.contains(index) { output.replaceCharacters(in: match.range, with: values[index]) }
        }
        return output as String
    }
    static func date(_ value: Date, date: DateFormatter.Style = .medium, time: DateFormatter.Style = .none, locale: Locale? = nil) -> String {
        let formatter = DateFormatter(); formatter.locale = locale ?? self.locale
        formatter.timeZone = .autoupdatingCurrent; formatter.dateStyle = date; formatter.timeStyle = .none
        let day = date == .none ? "" : formatter.string(from: value)
        guard time != .none else { return day }
        // Preserve the device's 12/24-hour preference while localizing AM/PM.
        formatter.dateStyle = .none
        formatter.dateFormat = DateFormatter.dateFormat(fromTemplate: time == .long ? "jmmss" : "jmm", options: 0, locale: .autoupdatingCurrent)
        return [day, formatter.string(from: value)].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

struct LanguagePreferencesView: View {
    @ObservedObject private var language = LanguagePreferences.shared
    var body: some View {
        Form {
            Picker(L10n.text("语言"), selection: $language.selection) {
                ForEach(AppLanguage.allCases) { Text($0.title).tag($0.rawValue).accessibilityIdentifier("language.\($0.rawValue)") }
            }.pickerStyle(.inline).labelsHidden()
        }.navigationTitle(L10n.text("语言")).navigationBarTitleDisplayMode(.inline)
    }
}
