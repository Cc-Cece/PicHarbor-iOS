import Foundation
import Vision
import ImageIO

enum SubscriptionQRCode {
    static func subscription(_ payload: String) throws -> String {
        let value = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.utf8.count <= 16 * 1024 else { throw HarborError("QR_UNSUPPORTED") }
        let scheme = URLComponents(string: value)?.scheme?.lowercased() ?? ""
        if ["ss", "ssr", "vmess", "vless", "trojan", "hysteria", "hysteria2", "hy2", "tuic", "anytls", "wireguard"].contains(scheme) {
            throw HarborError("QR_SINGLE_NODE")
        }
        guard let url = try? ProxySubscription.url(value) else { throw HarborError("QR_UNSUPPORTED") }
        return url.absoluteString
    }
    nonisolated static func messages(in data: Data) throws -> [String] {
        guard data.count <= 32 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 4096] as CFDictionary) else { throw HarborError("QR_IMAGE_UNAVAILABLE") }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try VNImageRequestHandler(cgImage: image).perform([request])
        var seen = Set<String>()
        return (request.results ?? []).compactMap(\.payloadStringValue).filter { seen.insert($0).inserted }
    }
}
