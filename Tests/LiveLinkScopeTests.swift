import XCTest
#if !LINK_SCOPE_STANDALONE
@testable import PicHarbor
#endif
final class LiveLinkScopeTests: XCTestCase {
    func testVersionedScopeRoundtripAndUnknownVersionsFailClosed() throws {
        var scope = LiveLinkScope(); scope.mode = "advanced"; scope.albums = ["stable-id"]
        scope.videos = false; scope.ignoreSmallImages = true
        let json = String(decoding: try JSONEncoder().encode(scope), as: UTF8.self)
        let decoded = try LiveLinkScope.parse("scope2:" + json)
        XCTAssertEqual(decoded.albums, ["stable-id"]); XCTAssertFalse(decoded.videos)
        XCTAssertThrowsError(try LiveLinkScope.parse("scope3:{}"))
        scope.albums = []
        XCTAssertThrowsError(try LiveLinkScope.parse("scope2:" + String(decoding: JSONEncoder().encode(scope), as: UTF8.self)))
    }
    func testOpenDatesAndInclusiveEndRespectCalendarDays() throws {
        let scope = try LiveLinkScope.parse("range::2026-11-01")
        let day = try XCTUnwrap(LiveLinkScope.formatter.date(from: "2026-11-01"))
        XCTAssertTrue(scope.includesDate(day.addingTimeInterval(86399)))
        XCTAssertFalse(scope.includesDate(day.addingTimeInterval(86400)))
        XCTAssertFalse(scope.includesDate(nil))
        XCTAssertTrue(try LiveLinkScope.parse("all").includesDate(nil))
        XCTAssertThrowsError(try LiveLinkScope.parse("range:2026-02-30:"))
    }
    func testPhoneSelectedScopeHasNoComputerFilters() throws {
        let scope = try LiveLinkScope.parse("selected")
        XCTAssertEqual(scope.mode, "all"); XCTAssertFalse(scope.dateEnabled)
        XCTAssertFalse(scope.ignoreSmallImages); XCTAssertTrue(scope.photos); XCTAssertTrue(scope.videos)
    }
}
