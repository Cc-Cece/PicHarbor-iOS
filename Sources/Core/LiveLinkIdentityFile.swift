import Foundation

/// The archive identity the iPhone app can read. The cable UDID is written here by the app
/// after the computer hands it over an already paired connection.
enum LiveLinkIdentityFile {
    private static let placeholders: Set<String> = [
        "0123456789", "0123456789abcdef", "1234567890", "0000000000000000", "ffffffffffffffff",
        "unknown", "none", "null", "n/a", "na", "default"
    ]

    static var directory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PicHarbor", isDirectory: true)
    }

    static var file: URL { directory.appendingPathComponent(".picharbor-serial") }

    /// Create the sandbox folder on first launch and keep it out of iCloud backup.
    static func prepare() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var folder = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
        } catch {
            // A later check-in reports the folder as unreadable. Photo backup is not involved.
        }
    }

    static func report() -> (value: String?, directoryReady: Bool, unreadable: Bool, usable: Bool) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return (nil, false, false, false)
        }
        if !FileManager.default.fileExists(atPath: file.path) {
            return (nil, true, false, false)
        }
        do {
            let text = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty { return (nil, true, false, false) }
            return (text, true, false, usable(text))
        } catch {
            return (nil, true, true, false)
        }
    }

    static func write(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard usable(trimmed) else { return false }
        prepare()
        do {
            try Data(trimmed.utf8).write(to: file, options: .atomic)
            var url = file
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? url.setResourceValues(values)
            return true
        } catch {
            return false
        }
    }

    /// Same single-value rules the computer uses. A real UDID from another phone still passes.
    static func usable(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (4...64).contains(trimmed.count), !trimmed.contains("&"),
              !trimmed.lowercased().hasPrefix("android:") else { return false }
        guard Set(trimmed).count > 1, !placeholders.contains(trimmed.lowercased()) else { return false }
        return true
    }

    /// What to tell the user before any file is sent.
    static func block(paired: Bool) -> String? {
        guard !report().usable else { return nil }
        if paired { return L10n.text("用数据线连接，并打开电脑上的 PicHarbor。") }
        return L10n.text("请先配对这台电脑，再用数据线连接一次。")
    }
}
