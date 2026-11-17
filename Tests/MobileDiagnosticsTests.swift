import XCTest
@testable import PicHarbor

final class MobileDiagnosticsTests: XCTestCase {
    func testZipHasKnownCRCAndCentralDirectory() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let zip = folder.appendingPathExtension("zip")
        defer { try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: zip) }
        try Data("hello".utf8).write(to: folder.appendingPathComponent("test.txt"))
        try DiagnosticZip.write(directory: folder, destination: zip)
        let bytes = [UInt8](try Data(contentsOf: zip))
        XCTAssertEqual(Array(bytes.prefix(4)), [0x50,0x4b,0x03,0x04])
        XCTAssertEqual(Array(bytes[14..<18]), [0x86,0xa6,0x10,0x36])
        XCTAssertEqual(Array(bytes.suffix(22).prefix(4)), [0x50,0x4b,0x05,0x06])
    }
    func testDiagnosticExportExcludesArbitrarySecrets() async throws {
        MobileDiagnostics.shared.record("test.event", task: "test-task", fields: ["state":"queued", "password":"do-not-export", "account":"private@example.org", "error_code":"https://secret"])
        let url = try await MobileDiagnostics.shared.export(from: nil, to: nil, summary: "{}")
        defer { try? FileManager.default.removeItem(at: url) }
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertTrue(text.contains("test.event"))
        XCTAssertFalse(text.contains("do-not-export")); XCTAssertFalse(text.contains("private@example.org"))
        XCTAssertFalse(text.contains("https://secret"))
    }
}
