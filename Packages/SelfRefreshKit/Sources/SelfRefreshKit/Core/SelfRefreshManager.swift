import Foundation
import Combine
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppIntents)
import AppIntents
#endif

/// Central state and operation coordinator for `SelfRefreshKit`.
@MainActor
public final class SelfRefreshManager: ObservableObject {
    public static let shared = SelfRefreshManager()

    @Published public private(set) var configuration = SelfRefreshConfiguration()
    @Published public private(set) var profileMetadata: ProvisioningProfileMetadata?
    @Published public private(set) var isLocalCertificateTakenOver: Bool = false
    @Published public private(set) var isTunnelConnected: Bool = false
    @Published public private(set) var pairedDeviceIdentifier: String?
    @Published public var appleID: String = ""
    @Published public var anisetteURLString: String = "https://ani.sidestore.io"
    @Published public var selectedVPN: LoopbackVPNApp = .localDevVPN {
        didSet {
            defaults.set(selectedVPN.rawValue, forKey: Keys.selectedVPN)
        }
    }
    @Published public private(set) var isRefreshing: Bool = false
    @Published public private(set) var lastRefreshDate: Date?
    @Published public var statusMessage: String = ""
    @Published public var lastError: String = ""
    @Published public private(set) var latestOTATag: String?
    @Published public private(set) var latestOTADownloadURL: URL?

    private var driver: SelfRefreshBackendDriver
    private let defaults: UserDefaults
    private let storageDirectory: URL

    private enum Keys {
        static let appleID = "selfrefreshkit.appleID"
        static let anisetteURL = "selfrefreshkit.anisetteURL"
        static let selectedVPN = "selfrefreshkit.selectedVPN"
        static let takenOver = "selfrefreshkit.takenOver"
        static let lastRefreshDate = "selfrefreshkit.lastRefreshDate"
        static let cachedExpirationDate = "selfrefreshkit.cachedExpirationDate"
        static let pairedDeviceID = "selfrefreshkit.pairedDeviceID"
    }

    public init(
        driver: SelfRefreshBackendDriver = DefaultSelfRefreshDriver(),
        defaults: UserDefaults = .standard,
        storageDirectory: URL? = nil
    ) {
        self.driver = driver
        self.defaults = defaults
        let baseDir = storageDirectory ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SelfRefreshKit", isDirectory: true)
        self.storageDirectory = baseDir
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)

        self.appleID = defaults.string(forKey: Keys.appleID) ?? ""
        self.anisetteURLString = defaults.string(forKey: Keys.anisetteURL) ?? "https://ani.sidestore.io"
        if let rawVPN = defaults.string(forKey: Keys.selectedVPN),
           let vpn = LoopbackVPNApp(rawValue: rawVPN) {
            self.selectedVPN = vpn
        }
        self.isLocalCertificateTakenOver = defaults.bool(forKey: Keys.takenOver)
        self.lastRefreshDate = defaults.object(forKey: Keys.lastRefreshDate) as? Date
        self.pairedDeviceIdentifier = defaults.string(forKey: Keys.pairedDeviceID)

        reloadEmbeddedProfile()
        loadExistingPairingFileIfPresent()
    }

    /// Configures `SelfRefreshKit` on app startup.
    public func configure(_ config: SelfRefreshConfiguration, customDriver: SelfRefreshBackendDriver? = nil) {
        self.configuration = config
        if let customDriver {
            self.driver = customDriver
        }
        if defaults.string(forKey: Keys.selectedVPN) == nil {
            self.selectedVPN = config.preferredVPN
        }
        if defaults.string(forKey: Keys.anisetteURL) == nil {
            self.anisetteURLString = config.defaultAnisetteURL
        }
        reloadEmbeddedProfile()
        loadExistingPairingFileIfPresent()
    }

    /// Translates a user-facing string using the host app's localizer if provided, or falls back to `SelfRefreshStrings`.
    public func localized(_ key: String) -> String {
        if let localizer = configuration.localizer {
            let result = localizer(key)
            if result != key {
                return result
            }
        }
        return SelfRefreshStrings.translate(key)
    }

    public var pairingFileURL: URL {
        storageDirectory.appendingPathComponent("pairing.mobiledevicepairing")
    }

    public var hasSavedCredentials: Bool {
        guard !appleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let saved = try? SelfRefreshKeychain.loadPassword(for: appleID)
        return (saved?.isEmpty == false)
    }

    // MARK: - Profile & Environment Inspection

    public func reloadEmbeddedProfile(in bundleURL: URL = Bundle.main.bundleURL) {
        if let parsed = ProfileInspector.inspectEmbeddedProfile(in: bundleURL) {
            self.profileMetadata = parsed
            defaults.set(parsed.expirationDate, forKey: Keys.cachedExpirationDate)
        } else if let cachedExp = defaults.object(forKey: Keys.cachedExpirationDate) as? Date {
            let bundleID = Bundle.main.bundleIdentifier ?? "com.app.sideloaded"
            self.profileMetadata = ProvisioningProfileMetadata(
                uuid: "CACHED-PROFILE",
                name: bundleID,
                appIDName: bundleID,
                bundleIdentifier: bundleID,
                teamIdentifier: "PERSONAL",
                teamName: appleID.isEmpty ? "Personal Team" : appleID,
                creationDate: lastRefreshDate ?? Date(),
                expirationDate: cachedExp
            )
        }
    }

    public func loadExistingPairingFileIfPresent() {
        guard FileManager.default.fileExists(atPath: pairingFileURL.path),
              let content = try? String(contentsOf: pairingFileURL, encoding: .utf8),
              let udid = try? driver.validatePairingFile(xmlContent: content) else {
            return
        }
        self.pairedDeviceIdentifier = udid
        defaults.set(udid, forKey: Keys.pairedDeviceID)
    }

    public func importPairingFile(from sourceURL: URL) throws {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { sourceURL.stopAccessingSecurityScopedResource() }
        }
        let xmlContent = try String(contentsOf: sourceURL, encoding: .utf8)
        try importPairingXMLContent(xmlContent)
    }

    public func importPairingXMLContent(_ xmlContent: String) throws {
        let udid = try driver.validatePairingFile(xmlContent: xmlContent)
        try xmlContent.write(to: pairingFileURL, atomically: true, encoding: .utf8)
        self.pairedDeviceIdentifier = udid
        defaults.set(udid, forKey: Keys.pairedDeviceID)
        self.lastError = ""
        self.statusMessage = localized("设备配对文件导入成功。")
    }

    public func saveCredentials(appleID: String, password: String, anisetteURL: String) throws {
        let trimmedID = appleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = anisetteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty, !password.isEmpty else {
            throw SelfRefreshError.missingAppleIDCredentials
        }
        guard let parsedURL = URL(string: trimmedURL),
              let scheme = parsedURL.scheme,
              ["http", "https"].contains(scheme.lowercased()) else {
            throw SelfRefreshError.invalidAnisetteURL
        }
        try SelfRefreshKeychain.savePassword(password, for: trimmedID)
        self.appleID = trimmedID
        self.anisetteURLString = trimmedURL
        defaults.set(trimmedID, forKey: Keys.appleID)
        defaults.set(trimmedURL, forKey: Keys.anisetteURL)
        self.lastError = ""
        self.statusMessage = localized("Apple ID 凭据已保存到本机钥匙串。")
    }

    @discardableResult
    public func checkTunnelConnection() async -> Bool {
        let connected = await driver.testLoopbackTunnel(host: "10.7.0.1", port: 62078)
        self.isTunnelConnected = connected
        return connected
    }

    public func openPreferredVPNApp() {
        #if canImport(UIKit)
        if let schemeURL = selectedVPN.urlScheme, UIApplication.shared.canOpenURL(schemeURL) {
            UIApplication.shared.open(schemeURL)
        } else if let storeURL = selectedVPN.appStoreURL {
            UIApplication.shared.open(storeURL)
        }
        #endif
    }

    // MARK: - Mode A: 1-Second Profile-Only Refresh (No Crash / No IPA Needed)

    public func refreshProfileOnly() async throws {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastError = ""
        statusMessage = localized("正在刷新描述文件…")
        defer { isRefreshing = false }

        #if canImport(UIKit)
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "SelfRefreshKit.ProfileRefresh") {
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
                bgTask = .invalid
            }
        }
        defer {
            if bgTask != .invalid {
                UIApplication.shared.endBackgroundTask(bgTask)
            }
        }
        #endif

        guard FileManager.default.fileExists(atPath: pairingFileURL.path),
              let pairingXML = try? String(contentsOf: pairingFileURL, encoding: .utf8) else {
            let err = SelfRefreshError.missingPairingFile
            lastError = localized(err.localizedDescription)
            throw err
        }

        let tunnelReady = await checkTunnelConnection()
        guard tunnelReady else {
            let err = SelfRefreshError.tunnelDisconnected(selectedVPN)
            lastError = localized(err.localizedDescription)
            throw err
        }

        let trimmedID = appleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty,
              let password = try SelfRefreshKeychain.loadPassword(for: trimmedID),
              !password.isEmpty else {
            let err = SelfRefreshError.missingAppleIDCredentials
            lastError = localized(err.localizedDescription)
            throw err
        }

        guard let anisetteURL = URL(string: anisetteURLString) else {
            let err = SelfRefreshError.invalidAnisetteURL
            lastError = localized(err.localizedDescription)
            throw err
        }

        let bundleID = Bundle.main.bundleIdentifier ?? "com.cccece.picharbor"
        let updatedProfile = try await driver.refreshProvisioningProfileOnly(
            appleID: trimmedID,
            password: password,
            anisetteURL: anisetteURL,
            pairingXML: pairingXML,
            bundleIdentifier: bundleID
        )

        self.profileMetadata = updatedProfile
        let now = Date()
        self.lastRefreshDate = now
        defaults.set(now, forKey: Keys.lastRefreshDate)
        defaults.set(updatedProfile.expirationDate, forKey: Keys.cachedExpirationDate)
        self.statusMessage = localized("描述文件已刷新，有效期已重置为 7 天。")
    }

    // MARK: - Mode B: Full IPA Resign & Self-Install (Initial Takeover & Cloud OTA Update)

    public func resignAndInstall(ipaURL: URL) async throws {
        guard !isRefreshing else { return }
        isRefreshing = true
        lastError = ""
        statusMessage = localized("正在本地重签名并覆盖安装…")
        defer { isRefreshing = false }

        let accessed = ipaURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { ipaURL.stopAccessingSecurityScopedResource() }
        }

        guard FileManager.default.fileExists(atPath: pairingFileURL.path),
              let pairingXML = try? String(contentsOf: pairingFileURL, encoding: .utf8) else {
            let err = SelfRefreshError.missingPairingFile
            lastError = localized(err.localizedDescription)
            throw err
        }

        let tunnelReady = await checkTunnelConnection()
        guard tunnelReady else {
            let err = SelfRefreshError.tunnelDisconnected(selectedVPN)
            lastError = localized(err.localizedDescription)
            throw err
        }

        let trimmedID = appleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedID.isEmpty,
              let password = try SelfRefreshKeychain.loadPassword(for: trimmedID),
              !password.isEmpty else {
            let err = SelfRefreshError.missingAppleIDCredentials
            lastError = localized(err.localizedDescription)
            throw err
        }

        guard let anisetteURL = URL(string: anisetteURLString) else {
            let err = SelfRefreshError.invalidAnisetteURL
            lastError = localized(err.localizedDescription)
            throw err
        }

        let bundleID = Bundle.main.bundleIdentifier ?? "com.cccece.picharbor"
        let updatedProfile = try await driver.resignAndInstallIPA(
            ipaFileURL: ipaURL,
            appleID: trimmedID,
            password: password,
            anisetteURL: anisetteURL,
            pairingXML: pairingXML,
            bundleIdentifier: bundleID
        )

        self.profileMetadata = updatedProfile
        self.isLocalCertificateTakenOver = true
        let now = Date()
        self.lastRefreshDate = now
        defaults.set(true, forKey: Keys.takenOver)
        defaults.set(now, forKey: Keys.lastRefreshDate)
        defaults.set(updatedProfile.expirationDate, forKey: Keys.cachedExpirationDate)
        self.statusMessage = localized("已完成本机签名接管与覆盖安装。")
    }

    // MARK: - Cloud OTA Check (GitHub Releases)

    public func checkGitHubOTAUpdate() async throws -> (tag: String, ipaURL: URL) {
        guard let repo = configuration.githubRepository, !repo.isEmpty,
              let apiURL = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else {
            throw SelfRefreshError.otaNoReleaseFound
        }
        var request = URLRequest(url: apiURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 12

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let assets = json["assets"] as? [[String: Any]] else {
            throw SelfRefreshError.otaNoReleaseFound
        }

        for asset in assets {
            if let name = asset["name"] as? String, name.lowercased().hasSuffix(".ipa"),
               let urlString = asset["browser_download_url"] as? String,
               let downloadURL = URL(string: urlString) {
                self.latestOTATag = tag
                self.latestOTADownloadURL = downloadURL
                return (tag, downloadURL)
            }
        }
        throw SelfRefreshError.otaNoReleaseFound
    }

    public func downloadAndInstallOTA(from remoteIPAURL: URL) async throws {
        statusMessage = localized("正在下载云端未签名 IPA…")
        let (tempURL, response) = try await URLSession.shared.download(from: remoteIPAURL)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SelfRefreshError.otaNoReleaseFound
        }
        let targetURL = FileManager.default.temporaryDirectory.appendingPathComponent("OTAUpdate-\(UUID().uuidString).ipa")
        try? FileManager.default.removeItem(at: targetURL)
        try FileManager.default.moveItem(at: tempURL, to: targetURL)
        defer { try? FileManager.default.removeItem(at: targetURL) }
        try await resignAndInstall(ipaURL: targetURL)
    }

    // MARK: - URL Scheme Automation Handler (`myapp://refresh`)

    @discardableResult
    public func handleOpenURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == configuration.urlScheme.lowercased() else {
            return false
        }
        let host = url.host?.lowercased() ?? ""
        if host == "refresh" || url.path.lowercased().contains("refresh") {
            Task {
                try? await refreshProfileOnly()
            }
            return true
        }
        return false
    }

    // MARK: - Summary Text Helper for Host Settings Row

    public var summaryBadgeText: String {
        guard let meta = profileMetadata else {
            return isLocalCertificateTakenOver ? localized("已接管") : localized("待激活")
        }
        let remaining = meta.remainingDaysAndHours()
        if remaining.isExpired {
            return localized("已过期")
        }
        return "\(remaining.days)d \(remaining.hours)h"
    }
}

#if canImport(AppIntents)
/// Built-in iOS Shortcuts `AppIntent` so users can add "Refresh App Provisioning Profile"
/// directly inside the Apple Shortcuts app (`LocalDevVPN -> Refresh -> Disconnect`).
@available(iOS 17.0, macOS 14.0, *)
public struct SelfRefreshProfileIntent: AppIntent {
    public static var title: LocalizedStringResource = "刷新应用签名描述文件"
    public static var description = IntentDescription("通过 LocalDevVPN 本地回环隧道，1 秒无感刷新当前应用的 7 天描述文件有效期。")
    public static var openAppWhenRun: Bool = true

    public init() {}

    @MainActor
    public func perform() async throws -> some IntentResult & ProvidesDialog {
        try await SelfRefreshManager.shared.refreshProfileOnly()
        return .result(dialog: "描述文件已成功刷新，重置为 7 天有效期。")
    }
}
#endif
