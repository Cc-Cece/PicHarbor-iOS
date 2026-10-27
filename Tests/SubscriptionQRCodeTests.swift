import XCTest
import CoreImage
import ImageIO
import UniformTypeIdentifiers
@testable import PicHarbor

final class SubscriptionQRCodeTests: XCTestCase {
    func testOnlyWebSubscriptionsAreAcceptedAndRequireNoDownload() throws {
        XCTAssertEqual(try SubscriptionQRCode.subscription(" https://example.invalid/subscribe?token=synthetic \n"), "https://example.invalid/subscribe?token=synthetic")
        XCTAssertEqual(try SubscriptionQRCode.subscription("http://example.invalid/config").prefix(7), "http://")
        for value in ["vless://synthetic@example.invalid", "ss://synthetic", "tuic://synthetic"] {
            XCTAssertThrowsError(try SubscriptionQRCode.subscription(value)) { XCTAssertEqual(($0 as? HarborError)?.code, "QR_SINGLE_NODE") }
        }
        for value in ["file:///private/config", "javascript:alert(1)", "clash://install-config", "ordinary text", "https://user:password@example.invalid"] {
            XCTAssertThrowsError(try SubscriptionQRCode.subscription(value)) { XCTAssertEqual(($0 as? HarborError)?.code, "QR_UNSUPPORTED") }
        }
    }
    func testPhotoQRCodeIsRecognizedLocally() throws {
        let value = "https://example.invalid/subscribe?token=synthetic"
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data(value.utf8), forKey: "inputMessage")
        let image = try XCTUnwrap(filter.outputImage).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let cgImage = try XCTUnwrap(CIContext().createCGImage(image, from: image.extent))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, cgImage, [kCGImagePropertyOrientation: 6] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        XCTAssertEqual(try SubscriptionQRCode.messages(in: data as Data), [value])
    }
    func testMalformedImageAndOversizedPayloadFailWithoutNetwork() {
        XCTAssertThrowsError(try SubscriptionQRCode.messages(in: Data("not-an-image".utf8)))
        XCTAssertThrowsError(try SubscriptionQRCode.subscription(String(repeating: "x", count: 16 * 1024 + 1)))
    }
}
