import XCTest
@testable import PicHarbor
import SelfRefreshKit

final class PicHarborTests: XCTestCase {
    @MainActor
    func testSelfRefreshKitIntegrationConfiguredForPicHarbor() throws {
        SelfRefreshManager.shared.configure(
            SelfRefreshConfiguration(
                urlScheme: "picharbor",
                preferredVPN: .localDevVPN,
                defaultAnisetteURL: "https://ani.sidestore.io",
                githubRepository: "Cc-Cece/PicHarbor-iOS"
            )
        )
        XCTAssertEqual(SelfRefreshManager.shared.configuration.urlScheme, "picharbor")
        XCTAssertEqual(SelfRefreshManager.shared.configuration.preferredVPN, .localDevVPN)
        XCTAssertEqual(SelfRefreshManager.shared.configuration.refreshWakeupURLString, "picharbor://refresh")
        XCTAssertEqual(SelfRefreshManager.shared.configuration.githubRepository, "Cc-Cece/PicHarbor-iOS")
    }
    @MainActor
    func testLoginRejectedWhileBusyIsNotReportedAsSuccess() async {
        let engine = Engine()
        engine.ready = true; engine.busy = true; engine.account = "existing@example.com"
        let success = await engine.login("unused")
        XCTAssertFalse(success)
        XCTAssertEqual(engine.account, "existing@example.com")
        XCTAssertEqual(engine.message, HarborError("ACCOUNT_BUSY").localizedDescription)
    }

    @MainActor
    func testLoginWithoutRuntimeHasActionableFailure() async {
        let engine = Engine()
        let success = await engine.login("unused")
        XCTAssertFalse(success)
        XCTAssertEqual(engine.message, HarborError("RUNTIME_UNAVAILABLE").localizedDescription)
        XCTAssertFalse(engine.busy)
    }

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
        XCTAssertEqual(record.stateLabel, L10n.text("待云端确认"))
    }
}
