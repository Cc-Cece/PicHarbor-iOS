import XCTest

final class HarborFlowTests: XCTestCase {
    func testNativeNavigationAndPreferenceScreens() {
        let app = XCUIApplication()
        app.launch()
        let later = app.buttons["稍后"]
        if later.waitForExistence(timeout: 30) { capture("welcome"); later.tap() }
        XCTAssertTrue(app.tabBars.buttons["照片"].waitForExistence(timeout: 10))
        capture("photos-permission")
        app.tabBars.buttons["备份"].tap(); capture("backup")
        app.buttons["备份偏好"].tap()
        XCTAssertTrue(app.staticTexts["不计配额原画质"].waitForExistence(timeout: 5))
        capture("backup-preferences")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["活动"].tap(); capture("activity-empty")
        app.tabBars.buttons["设置"].tap(); capture("settings")
        app.buttons["空间清理核验"].tap()
        XCTAssertTrue(app.staticTexts["完整核验"].waitForExistence(timeout: 5))
        capture("cleanup-policy")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["外观"].tap()
        app.buttons["深色"].tap()
        capture("appearance-dark")
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
