import Foundation
import CryptoKit

enum LiveLinkFailure: Error, LocalizedError {
    case pin
    case qr
    case form
    case network
    case rejected
    case identity
    case file

    var errorDescription: String? {
        switch self {
        case .pin: return L10n.text("配对码或证书不一致")
        case .qr: return L10n.text("这不是连接电脑的二维码。")
        case .form: return L10n.text("请填写局域网地址、端口、证书前 16 位和 6 位配对码。")
        case .network: return L10n.text("网络请求失败，请检查网络后重试。")
        case .rejected: return L10n.text("电脑拒绝了这次传输。")
        case .identity: return L10n.text("无法访问安全凭据存储。")
        case .file: return L10n.text("无法读取原件或写入暂存文件，请检查空间与照片权限。")
        }
    }
}

enum LiveLinkPin: Equatable {
    case full(String)
    case prefix(String)

    func accepts(_ fingerprint: String) -> Bool {
        let value = fingerprint.lowercased()
        guard LiveLinkCheck.isHex(value, count: 64) else { return false }
        switch self {
        case .full(let expected): return value == expected.lowercased()
        case .prefix(let prefix):
            let needle = prefix.lowercased()
            return needle.count == 16 && LiveLinkCheck.isHex(needle) && value.hasPrefix(needle)
        }
    }
}

struct LiveLinkTarget: Equatable {
    var host: String
    var port: Int
    var pin: LiveLinkPin
    var code: String
}

enum LiveLinkCheck {
    static func isHex(_ value: String, count: Int? = nil) -> Bool {
        if let count, value.count != count { return false }
        return !value.isEmpty && value.allSatisfy(\.isHexDigit)
    }

    static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        for part in parts {
            guard (1...3).contains(part.count), part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(part), (0...255).contains(number) else { return false }
            if part.count > 1, part.hasPrefix("0") { return false }
        }
        return true
    }

    static func port(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...5).contains(trimmed.count), trimmed.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = Int(trimmed), (1...65535).contains(number) else { return nil }
        return number
    }

    static func pairingCode(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 6, trimmed.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return trimmed
    }

    static func isDeviceID(_ value: String) -> Bool {
        guard (1...80).contains(value.count) else { return false }
        return value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") }
    }

    /// `picharbor://link?v=1&host=<ipv4>&port=<tcp>&fp=<64 hex>&code=<6 digits>`
    static func parseQR(_ raw: String) -> LiveLinkTarget? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 2048,
              let components = URLComponents(string: trimmed),
              components.scheme?.lowercased() == "picharbor",
              components.host?.lowercased() == "link" else { return nil }
        let path = components.path
        guard path.isEmpty || path == "/" else { return nil }
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value ?? "" }
        guard query["v"] == "1",
              let host = query["host"], isIPv4(host),
              let port = port(query["port"] ?? ""),
              let fingerprint = query["fp"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              isHex(fingerprint, count: 64),
              let code = pairingCode(query["code"] ?? "") else { return nil }
        return LiveLinkTarget(host: host, port: port, pin: .full(fingerprint), code: code)
    }
}

enum LiveLinkCrypto {
    /// HMAC key is the trimmed code. Message uses the full certificate fingerprint, never the 16-character prefix.
    static func pairMAC(deviceID: String, nonce: String, fingerprint: String, code: String) -> String {
        let message = ["picharbor-link-v1", "pair", deviceID, nonce, fingerprint.lowercased()].joined(separator: "\n")
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: Data(code.utf8)))
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    static func sessionPlaintext(nonce: String, fingerprint: String) -> String {
        ["picharbor-link-v1", "session", nonce, fingerprint.lowercased()].joined(separator: "\n")
    }

    /// PHAsset.localIdentifier contains slashes, so it cannot be a blob id.
    static func itemID(localIdentifier: String, role: String) -> String {
        let digest = SHA256.hash(data: Data((localIdentifier + "\n" + role).utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func pairID(_ localIdentifier: String) -> String {
        let mapped = String(localIdentifier.map { character -> Character in
            if character.isASCII, character.isLetter || character.isNumber || character == "." || character == "_" || character == "-" {
                return character
            }
            return "_"
        })
        let trimmed = String(mapped.prefix(120))
        return trimmed.isEmpty ? "asset" : trimmed
    }

    static func headerFileName(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        let cleaned = base.isEmpty ? "file" : base
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._")
        return cleaned.addingPercentEncoding(withAllowedCharacters: allowed) ?? "file"
    }

    static func blobPath(_ id: String) -> String? {
        guard LiveLinkCheck.isDeviceID(id) else { return nil }
        return "/v1/blobs/" + id
    }
}

enum LiveLinkBlobStep: Equatable {
    case done
    case advance(Int64)
    case retry
    case restart
}

enum LiveLinkBlob {
    struct Body: Decodable {
        var received: Int64?
        var complete: Bool?
        var error: String?
    }

    static func step(status: Int, data: Data, fileSize: Int64) -> LiveLinkBlobStep? {
        let body = try? JSONDecoder().decode(Body.self, from: data)
        switch status {
        case 200:
            if body?.complete == true { return .done }
            guard let received = body?.received, (0...fileSize).contains(received) else { return nil }
            return received >= fileSize ? .done : .advance(received)
        case 409:
            guard let received = body?.received, (0...fileSize).contains(received) else { return nil }
            return received >= fileSize ? .done : .advance(received)
        case 400 where body?.error == "hash":
            return .restart
        case 500 where body?.error == "import":
            return .retry
        default:
            return nil
        }
    }
}
