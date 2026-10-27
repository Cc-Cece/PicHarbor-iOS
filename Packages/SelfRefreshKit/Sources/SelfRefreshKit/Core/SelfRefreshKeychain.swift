import Foundation
import Security

/// Error definitions for `SelfRefreshKit`.
public enum SelfRefreshError: LocalizedError, Equatable, Sendable {
    case invalidProvisioningProfile
    case missingPairingFile
    case invalidPairingFile(String)
    case tunnelDisconnected(LoopbackVPNApp)
    case missingAppleIDCredentials
    case invalidAnisetteURL
    case keychainFailure(OSStatus)
    case missingIPAFile
    case otaNoReleaseFound
    case backendOperationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidProvisioningProfile:
            return "无法解析描述文件（embedded.mobileprovision）。"
        case .missingPairingFile:
            return "未导入设备配对文件（.mobiledevicepairing）。"
        case .invalidPairingFile(let detail):
            return "设备配对文件无效：\(detail)"
        case .tunnelDisconnected(let vpn):
            return "未检测到本地回环隧道，请先开启 \(vpn.displayName)。"
        case .missingAppleIDCredentials:
            return "请先配置 Apple ID 账号与密码。"
        case .invalidAnisetteURL:
            return "Anisette 服务器地址格式无效。"
        case .keychainFailure(let status):
            return "钥匙串访问失败（状态码：\(status)）。"
        case .missingIPAFile:
            return "未找到用于重签名的 IPA 文件。"
        case .otaNoReleaseFound:
            return "未在云端仓库中找到可用的未签名 IPA 构建。"
        case .backendOperationFailed(let reason):
            return reason
        }
    }
}

/// Secure Keychain storage for Apple ID credentials and local certificate metadata.
public enum SelfRefreshKeychain {
    private static let service = "io.github.selfrefreshkit.credentials"

    public static func savePassword(_ password: String, for account: String) throws {
        let data = Data(password.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw SelfRefreshError.keychainFailure(addStatus)
            }
        } else if status != errSecSuccess {
            throw SelfRefreshError.keychainFailure(status)
        }
    }

    public static func loadPassword(for account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw SelfRefreshError.keychainFailure(status)
        }
        return password
    }

    public static func deletePassword(for account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SelfRefreshError.keychainFailure(status)
        }
    }
}
