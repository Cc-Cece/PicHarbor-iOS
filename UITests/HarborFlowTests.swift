import XCTest

final class HarborFlowTests: XCTestCase {
    func testAdvancedBackupChecksDefaultOffAndPersist() {
        let app = XCUIApplication(); app.launch()
        if app.buttons["稍后"].waitForExistence(timeout: 30) { app.buttons["稍后"].tap() }
        app.tabBars.buttons["设置"].tap(); app.buttons["高级备份检查"].tap()
        let toggle = app.switches["backup.strict"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); XCTAssertEqual(toggle.value as? String, "0")
        toggle.tap(); capture("advanced-backup-checks")
        app.terminate(); app.launch()
        if app.buttons["稍后"].waitForExistence(timeout: 30) { app.buttons["稍后"].tap() }
        app.tabBars.buttons["设置"].tap(); app.buttons["高级备份检查"].tap()
        XCTAssertEqual(app.switches["backup.strict"].value as? String, "1")
        app.switches["backup.strict"].tap()
    }
    func testOriginalPairStrategiesCanBeSelectedAndPersisted() {
        let app = XCUIApplication()
        app.launch()
        if app.buttons["稍后"].waitForExistence(timeout: 30) { app.buttons["稍后"].tap() }
        app.tabBars.buttons["设置"].tap(); app.buttons["备份偏好"].tap()
        let joint = app.buttons["原始配对 · 联合提交（测试）"]
        if !joint.isHittable { app.swipeUp() }
        XCTAssertTrue(joint.waitForExistence(timeout: 5)); joint.tap()
        capture("live-pair-joint-preference")
        let repair = app.buttons["原始配对 · 先照片后视频（测试）"]
        if !repair.isHittable { app.swipeUp() }
        repair.tap()
        app.terminate(); app.launch()
        if app.buttons["稍后"].waitForExistence(timeout: 30) { app.buttons["稍后"].tap() }
        app.tabBars.buttons["设置"].tap(); app.buttons["备份偏好"].tap()
        if !app.buttons["原始配对 · 先照片后视频（测试）"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.buttons["原始配对 · 先照片后视频（测试）"].isSelected)
        capture("live-pair-reconcile-preference")
        let motion = app.buttons["Motion Photo"]
        if !motion.isHittable { app.swipeDown() }
        motion.tap()
    }
    func testActivityGroupingOptions() {
        let app = XCUIApplication()
        app.launch()
        if app.buttons["稍后"].waitForExistence(timeout: 30) { app.buttons["稍后"].tap() }
        app.tabBars.buttons["活动"].tap()
        XCTAssertTrue(app.segmentedControls["activity.source"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.segmentedControls["activity.status"].exists)
        app.segmentedControls["activity.source"].buttons["手动"].tap()
        app.segmentedControls["activity.status"].buttons["未完成"].tap()
        capture("activity-source-status-filters")
        app.segmentedControls["activity.source"].buttons["全部来源"].tap()
        app.segmentedControls["activity.status"].buttons["全部"].tap()
        let menu = app.buttons["activity.menu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        XCTAssertTrue(app.buttons["暂停当前结果"].waitForExistence(timeout: 5))
        capture("activity-filtered-actions")
        app.navigationBars["活动"].staticTexts["活动"].tap()
        XCTAssertTrue(app.navigationBars["活动"].exists)
    }
    func testPhotoKitExportAfterSystemAuthorization() {
        let app = XCUIApplication()
        app.launchArguments.append("--verify-photo-export")
        app.launch()
        if app.buttons["稍后"].waitForExistence(timeout: 30) { app.buttons["稍后"].tap() }
        authorizePhotosIfNeeded(in: app)
        let report = app.staticTexts["photokit.export.result"]
        let success = NSPredicate(format: "label == %@", "相册资源导出与读取校验通过")
        expectation(for: success, evaluatedWith: report)
        waitForExpectations(timeout: 20)
        capture("photokit-export-verified")
    }

    func testAddGoogleAccountCanBeOpenedRepeatedly() {
        let app = XCUIApplication()
        app.launch()
        let later = app.buttons["稍后"]
        if later.waitForExistence(timeout: 30) { later.tap() }
        app.tabBars.buttons["设置"].tap()
        app.buttons["settings.account"].tap()
        XCTAssertTrue(app.navigationBars["账号"].waitForExistence(timeout: 5))
        for _ in 0..<2 {
            let add = app.buttons["添加 Google 账号"]
            XCTAssertTrue(add.waitForExistence(timeout: 5))
            XCTAssertTrue(add.isEnabled)
            add.tap()
            guard app.navigationBars["欢迎使用 PicHarbor"].waitForExistence(timeout: 5) else {
                capture("account-add-failed")
                XCTFail("添加账号没有打开登录入口")
                return
            }
            capture("account-connection")
            let field = app.secureTextFields["粘贴登录凭据"]
            field.tap(); field.typeText("androidId=invalid-test-fixture")
            app.buttons["导入并连接"].tap()
            XCTAssertTrue(app.staticTexts["connection.error"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.navigationBars["欢迎使用 PicHarbor"].exists)
            XCTAssertEqual(app.staticTexts["connection.error"].label, "登录凭据无效。")
            XCTAssertFalse(app.alerts.firstMatch.exists, "登录失败应在当前页面显示，不应被额外账号读取错误覆盖")
            capture("account-invalid-credential")
            let google = app.buttons["connection.google"]
            if !google.isHittable { app.swipeDown() }
            google.tap()
            XCTAssertTrue(app.navigationBars["连接 Google"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
            capture("account-google-web")
            app.buttons["取消"].tap()
            app.buttons["稍后"].tap()
            XCTAssertTrue(app.navigationBars["账号"].waitForExistence(timeout: 5))
        }
    }

    func testPreferencesPersistWithoutAccount() {
        let app = XCUIApplication()
        app.launch()
        if app.buttons["稍后"].waitForExistence(timeout: 30) { app.buttons["稍后"].tap() }
        app.tabBars.buttons["设置"].tap()
        app.buttons["备份偏好"].tap()
        app.buttons["计配额原画质"].tap()
        app.terminate(); app.launch()
        if app.buttons["稍后"].waitForExistence(timeout: 30) { app.buttons["稍后"].tap() }
        app.tabBars.buttons["设置"].tap()
        app.buttons["备份偏好"].tap()
        XCTAssertTrue(app.buttons["计配额原画质"].isSelected)
        app.buttons["不计配额原画质"].tap()
    }

    func testNativeNavigationAndPreferenceScreens() {
        let app = XCUIApplication()
        app.launch()
        let later = app.buttons["稍后"]
        if later.waitForExistence(timeout: 30) { capture("welcome"); later.tap() }
        XCTAssertTrue(app.tabBars.buttons["照片"].waitForExistence(timeout: 10))
        capture("photos-permission")
        authorizePhotosIfNeeded(in: app)
        XCTAssertTrue(app.collectionViews.cells.firstMatch.waitForExistence(timeout: 10))
        capture("photos-authorized")
        app.collectionViews.cells.firstMatch.tap()
        XCTAssertTrue(app.navigationBars["照片详情"].waitForExistence(timeout: 5))
        capture("photo-detail")
        app.buttons["关闭"].tap()
        app.tabBars.buttons["备份"].tap()
        XCTAssertTrue(app.navigationBars["备份"].waitForExistence(timeout: 5)); capture("backup")
        app.buttons["备份偏好"].tap()
        XCTAssertTrue(app.buttons["不计配额原画质"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["不计配额原画质"].isSelected)
        capture("backup-preferences")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["活动"].tap()
        XCTAssertTrue(app.navigationBars["活动"].waitForExistence(timeout: 5)); capture("activity-empty")
        app.tabBars.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5)); capture("settings")
        app.buttons["空间清理核验"].tap()
        XCTAssertTrue(app.staticTexts["完整核验"].waitForExistence(timeout: 5))
        capture("cleanup-policy")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["外观"].tap()
        app.buttons["深色"].tap()
        capture("appearance-dark")
        app.tabBars.buttons["备份"].tap()
        app.buttons["释放 iPhone 空间"].tap()
        app.buttons["开始检查"].tap()
        XCTAssertTrue(app.alerts.staticTexts["请先在设置中连接 Google 账号。"].waitForExistence(timeout: 5))
        capture("cleanup-account-required")
        app.alerts.buttons["好"].tap()
    }
    private func authorizePhotosIfNeeded(in app: XCUIApplication) {
        let authorize = app.buttons["允许访问相册"]
        let appGrant = app.buttons["Allow Full Access"]
        let systemGrant = XCUIApplication(bundleIdentifier: "com.apple.springboard").buttons["Allow Full Access"]
        guard authorize.exists || appGrant.exists || systemGrant.exists else { return }
        if authorize.exists { authorize.tap() }
        // Depending on the simulator's OS, this system alert is exposed under
        // the requesting app or SpringBoard. Exercise the real consent UI.
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in appGrant.exists || systemGrant.exists }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 10), .completed)
        if appGrant.exists { appGrant.tap() }
        else if systemGrant.exists { systemGrant.tap() }
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
