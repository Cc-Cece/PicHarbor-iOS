import XCTest
@testable import PicHarbor

final class PicHarborTests: XCTestCase {
    @MainActor
    func testEmbeddedRuntimeImportsGpmcAndNativeExtensions() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(PythonBridge.start(home.path))
        let raw = PythonBridge.call("probe", payload: "{}", event: { _ in })
        let result = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        XCTAssertEqual(result["ok"] as? Bool, true)
        XCTAssertEqual(result["gpmc_imported"] as? Bool, true)
        XCTAssertTrue((result["python"] as? String ?? "").hasPrefix("3.13."))
        XCTAssertNotNil(result["tls"])
        XCTAssertNotNil(result["sqlite"])
    }

    func testPendingSubmissionIsNotPresentedAsConfirmed() throws {
        let raw = #"{"id":"1","account":"test@example.com","name":"photo.jpg","sha1":"a","sha256":"b","size":42,"remote_key":"submitted","state":"confirmation_pending","origin":"uploaded","error":"REMOTE_NOT_VISIBLE","updated":1}"#
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let record = try decoder.decode(BackupObservation.self, from: Data(raw.utf8))
        XCTAssertEqual(record.remoteKey, "submitted")
        XCTAssertEqual(record.stateLabel, "待云端确认")
    }
}
