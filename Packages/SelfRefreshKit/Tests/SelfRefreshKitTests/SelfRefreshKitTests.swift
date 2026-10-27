import XCTest
@testable import SelfRefreshKit

final class SelfRefreshKitTests: XCTestCase {
    func testExtractAndParseCMSWrappedMobileProvision() throws {
        let now = Date(timeIntervalSince1970: 1_760_000_000)
        let exp = now.addingTimeInterval(6 * 86400 + 5 * 3600)
        let formatter = ISO8601DateFormatter()
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>UUID</key>
            <string>12345678-ABCD-EF00-1122-334455667788</string>
            <key>Name</key>
            <string>iOS Team Provisioning Profile: com.cccece.picharbor</string>
            <key>AppIDName</key>
            <string>PicHarbor</string>
            <key>TeamName</key>
            <string>Kanbara Personal</string>
            <key>TeamIdentifier</key>
            <array><string>8X92TEAMID</string></array>
            <key>CreationDate</key>
            <date>\(formatter.string(from: now))</date>
            <key>ExpirationDate</key>
            <date>\(formatter.string(from: exp))</date>
            <key>Entitlements</key>
            <dict>
                <key>application-identifier</key>
                <string>8X92TEAMID.com.cccece.picharbor</string>
            </dict>
        </dict>
        </plist>
        """
        var cmsWrapped = Data([0x30, 0x82, 0x05, 0x00, 0x06, 0x09])
        cmsWrapped.append(Data(xml.utf8))
        cmsWrapped.append(Data([0x00, 0x00, 0xFF]))

        let parsed = try ProfileInspector.parseMobileProvisionData(cmsWrapped)
        XCTAssertEqual(parsed.uuid, "12345678-ABCD-EF00-1122-334455667788")
        XCTAssertEqual(parsed.bundleIdentifier, "com.cccece.picharbor")
        XCTAssertEqual(parsed.teamIdentifier, "8X92TEAMID")
        let remaining = parsed.remainingDaysAndHours(from: now)
        XCTAssertFalse(remaining.isExpired)
        XCTAssertEqual(remaining.days, 6)
        XCTAssertEqual(remaining.hours, 5)
        XCTAssertFalse(parsed.isExpiringSoon(from: now))
    }

    func testPairingFileValidationAcceptsValidAndRejectsInvalidXML() throws {
        let driver = DefaultSelfRefreshDriver()
        let validPairing = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>UDID</key><string>00008110-00112233445566</string>
            <key>DeviceCertificate</key><data>AA==</data>
            <key>HostCertificate</key><data>AA==</data>
            <key>HostPrivateKey</key><data>AA==</data>
        </dict>
        </plist>
        """
        let udid = try driver.validatePairingFile(xmlContent: validPairing)
        XCTAssertEqual(udid, "00008110-00112233445566")

        let invalidPairing = "<plist><dict><key>UDID</key><string>123</string></dict></plist>"
        XCTAssertThrowsError(try driver.validatePairingFile(xmlContent: invalidPairing))
    }

    @MainActor
    func testDefaultVPNIsLocalDevVPNAndCompatibleWithOthers() {
        let config = SelfRefreshConfiguration(urlScheme: "picharbor")
        XCTAssertEqual(config.preferredVPN, .localDevVPN)
        XCTAssertEqual(config.refreshWakeupURLString, "picharbor://refresh")
        XCTAssertEqual(LoopbackVPNApp.localDevVPN.urlScheme?.absoluteString, "localdevvpn://")
        XCTAssertEqual(LoopbackVPNApp.stosVPN.urlScheme?.absoluteString, "stosvpn://")
        XCTAssertEqual(LoopbackVPNApp.wireGuard.urlScheme?.absoluteString, "wireguard://")
    }
}
