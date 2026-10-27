import Foundation

/// Supported loopback VPN applications for local lockdownd communication (`10.7.0.1`).
/// Defaults to `.localDevVPN` while remaining compatible with `.stosVPN` and `.wireGuard`.
public enum LoopbackVPNApp: String, CaseIterable, Codable, Identifiable, Sendable {
    case localDevVPN = "LocalDevVPN"
    case stosVPN = "StosVPN"
    case wireGuard = "WireGuard"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .localDevVPN: return "LocalDevVPN"
        case .stosVPN: return "StosVPN"
        case .wireGuard: return "WireGuard"
        }
    }

    public var urlScheme: URL? {
        switch self {
        case .localDevVPN: return URL(string: "localdevvpn://")
        case .stosVPN: return URL(string: "stosvpn://")
        case .wireGuard: return URL(string: "wireguard://")
        }
    }

    public var appStoreURL: URL? {
        switch self {
        case .localDevVPN: return URL(string: "https://apps.apple.com/app/localdevvpn/id6744003051")
        case .stosVPN: return URL(string: "https://apps.apple.com/app/stosvpn/id6744003051")
        case .wireGuard: return URL(string: "https://apps.apple.com/app/wireguard/id1441195209")
        }
    }
}

/// Configuration for `SelfRefreshKit`.
public struct SelfRefreshConfiguration: Sendable {
    public static let kitVersion = "0.1.0"
    public static let minimuxerEngineVersion = "minimuxer-bridge 0.4.x"
    public static let altSignEngineVersion = "AltSign-bridge 1.6.x"

    /// Custom URL scheme registered by the host application (e.g. `"picharbor"` -> `picharbor://refresh`).
    public var urlScheme: String
    /// Default preferred loopback VPN app (`.localDevVPN`).
    public var preferredVPN: LoopbackVPNApp
    /// Default Anisette V3 server endpoint.
    public var defaultAnisetteURL: String
    /// Optional GitHub repository slug (e.g. `"Cc-Cece/PicHarbor-iOS"`) for one-tap OTA update checks.
    public var githubRepository: String?
    /// Background task identifier suffix or full identifier if the host registers background refresh.
    public var backgroundTaskIdentifier: String?
    /// Optional custom localization function injected by the host app (e.g., PicHarbor's `L10n.text`).
    public var localizer: (@Sendable (String) -> String)?

    public init(
        urlScheme: String = "selfrefresh",
        preferredVPN: LoopbackVPNApp = .localDevVPN,
        defaultAnisetteURL: String = "https://ani.sidestore.io",
        githubRepository: String? = nil,
        backgroundTaskIdentifier: String? = nil,
        localizer: (@Sendable (String) -> String)? = nil
    ) {
        self.urlScheme = urlScheme
        self.preferredVPN = preferredVPN
        self.defaultAnisetteURL = defaultAnisetteURL
        self.githubRepository = githubRepository
        self.backgroundTaskIdentifier = backgroundTaskIdentifier
        self.localizer = localizer
    }

    public var refreshWakeupURLString: String {
        "\(urlScheme)://refresh"
    }
}

/// Parsed information from the application's `embedded.mobileprovision` file.
public struct ProvisioningProfileMetadata: Equatable, Sendable {
    public var uuid: String
    public var name: String
    public var appIDName: String
    public var bundleIdentifier: String
    public var teamIdentifier: String
    public var teamName: String
    public var creationDate: Date
    public var expirationDate: Date
    public var certificateSHA1Fingerprints: [String]

    public init(
        uuid: String,
        name: String,
        appIDName: String,
        bundleIdentifier: String,
        teamIdentifier: String,
        teamName: String,
        creationDate: Date,
        expirationDate: Date,
        certificateSHA1Fingerprints: [String] = []
    ) {
        self.uuid = uuid
        self.name = name
        self.appIDName = appIDName
        self.bundleIdentifier = bundleIdentifier
        self.teamIdentifier = teamIdentifier
        self.teamName = teamName
        self.creationDate = creationDate
        self.expirationDate = expirationDate
        self.certificateSHA1Fingerprints = certificateSHA1Fingerprints
    }

    public func remainingTimeInterval(from now: Date = Date()) -> TimeInterval {
        expirationDate.timeIntervalSince(now)
    }

    public func remainingDaysAndHours(from now: Date = Date()) -> (days: Int, hours: Int, isExpired: Bool) {
        let interval = remainingTimeInterval(from: now)
        if interval <= 0 {
            return (0, 0, true)
        }
        let totalHours = Int(interval / 3600)
        return (totalHours / 24, totalHours % 24, false)
    }

    public func isExpiringSoon(thresholdHours: Int = 48, from now: Date = Date()) -> Bool {
        let interval = remainingTimeInterval(from: now)
        return interval <= TimeInterval(thresholdHours * 3600)
    }
}

/// Protocol allowing custom or native `AltSign` + `Minimuxer` runtime bridges to be plugged in.
public protocol SelfRefreshBackendDriver: Sendable {
    var driverName: String { get }
    func testLoopbackTunnel(host: String, port: UInt16) async -> Bool
    func validatePairingFile(xmlContent: String) throws -> String
    func refreshProvisioningProfileOnly(
        appleID: String,
        password: String,
        anisetteURL: URL,
        pairingXML: String,
        bundleIdentifier: String
    ) async throws -> ProvisioningProfileMetadata
    func resignAndInstallIPA(
        ipaFileURL: URL,
        appleID: String,
        password: String,
        anisetteURL: URL,
        pairingXML: String,
        bundleIdentifier: String
    ) async throws -> ProvisioningProfileMetadata
}
