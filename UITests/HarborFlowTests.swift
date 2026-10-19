import XCTest

final class HarborFlowTests: XCTestCase {
    private func localizedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        return app
    }
    func testLanguageSwitchingPersistsWithoutLeavingSettings() {
        let app = localizedApp(); app.launch()
        if app.buttons["稍后"].waitForExistence(timeout: 30) { app.buttons["稍后"].tap() }
        app.tabBars.buttons["设置"].tap(); app.buttons["settings.language"].tap()
        app.buttons["English"].tap()
        XCTAssertTrue(app.navigationBars["Language"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Photos"].exists); capture("language-english")
        app.buttons["粵語（香港）"].tap()
        XCTAssertTrue(app.navigationBars["語言"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["相片"].exists); capture("language-hong-kong")
        app.terminate(); app.launch()
        if app.buttons["稍後"].waitForExistence(timeout: 30) { app.buttons["稍後"].tap() }
        app.tabBars.buttons["設定"].tap(); app.buttons["settings.language"].tap()
        XCTAssertTrue(app.buttons["粵語（香港）"].isSelected)
        app.buttons["跟隨系統"].tap()
        XCTAssertTrue(app.navigationBars["语言"].waitForExistence(timeout: 5))
    }
    func testRestoreDefaultsRequiresConfirmationAndRestoresPairing() {
        let app = localizedApp(); app.launch()
        if app.buttons["稍后"].waitForExistence(timeout: 30) { app.buttons["稍后"].tap() }
        app.tabBars.buttons["设置"].tap(); app.buttons["备份偏好"].tap()
        app.buttons["节省空间"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let restore = app.buttons["settings.restore"]
        for _ in 0..<3 { if restore.isHittable { break }; app.swipeUp() }
        restore.tap(); app.alerts.buttons["取消"].tap()
        app.swipeDown(); app.buttons["备份偏好"].tap()
        XCTAssertTrue(app.buttons["节省空间"].isSelected)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        for _ in 0..<3 { if restore.isHittable { break }; app.swipeUp() }
        restore.tap(); app.alerts.buttons["恢复默认设置"].tap()
        XCTAssertTrue(app.alerts.staticTexts["已恢复默认设置。自动备份已关闭，请重新确认备份范围。"].waitForExistence(timeout: 10))
        app.alerts.buttons["好"].tap(); app.swipeDown(); app.buttons["备份偏好"].tap()
        XCTAssertTrue(app.buttons["不计配额原画质"].isSelected)
        XCTAssertTrue(app.buttons["原始照片配对"].isSelected); capture("restored-defaults")
    }
    func testQueueNoticeHidesAfterThirtySeconds() {
        let app = localizedApp(); app.launchArguments += ["--task-review-fixture", "--queue-notice-fixture"]; app.launch()
        XCTAssertTrue(app.buttons["关闭备份提示"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["已加入备份队列 · 2 项"].exists)
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["关闭备份提示"])
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 35), .completed)
        XCTAssertTrue(app.navigationBars["活动"].exists)
    }
    func testLiveCleanupRequiresConsentAndPersistsIt() {
        let app = localizedApp(); app.launch()
        if app.buttons["稍后"].waitForExistence(timeout: 30) { app.buttons["稍后"].tap() }
        app.tabBars.buttons["设置"].tap(); app.buttons["空间清理核验"].tap()
        let toggle = app.switches["cleanup.allowLive"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(app.alerts["可能影响动态照片的完整取回"].waitForExistence(timeout: 5))
        app.alerts.buttons["暂不开启"].tap(); XCTAssertEqual(toggle.value as? String, "0")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        app.alerts.buttons["了解风险并开启"].tap(); XCTAssertEqual(toggle.value as? String, "1")
        capture("cleanup-live-consent")
        app.terminate(); app.launch()
        if app.buttons["稍后"].waitForExistence(timeout: 30) { app.buttons["稍后"].tap() }
        app.tabBars.buttons["设置"].tap(); app.buttons["空间清理核验"].tap()
        XCTAssertEqual(app.switches["cleanup.allowLive"].value as? String, "1")
        setSwitch(app.switches["cleanup.allowLive"], on: false)
    }
    func testBatchNavigationTaskFlowAndAdvancedInformationSheet() {
        let app = localizedApp(); app.launchArguments.append("--task-review-fixture"); app.launch()
        let batch = app.buttons["activity.batch"].firstMatch
        XCTAssertTrue(batch.waitForExistence(timeout: 30)); capture("activity-batch-card")
        batch.tap()
        XCTAssertTrue(app.navigationBars["备份批次"].waitForExistence(timeout: 5)); capture("activity-batch-list")
        app.buttons["activity.task.ui-live"].tap()
        XCTAssertTrue(app.navigationBars["任务详情"].waitForExistence(timeout: 5))
        app.buttons["task.filename"].tap()
        XCTAssertTrue(app.navigationBars["完整文件名"].waitForExistence(timeout: 5))
        app.buttons["完成"].tap()
        app.buttons["photo.preview.ui-only-asset"].tap()
        XCTAssertTrue(app.navigationBars["照片详情"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["无法查看照片"].exists)
        app.buttons["关闭"].tap()
        XCTAssertTrue(app.staticTexts["备份流程"].exists)
        XCTAssertFalse(app.staticTexts["REMOTE_MOTION_NOT_DYNAMIC"].exists)
        capture("task-main-flow")
        let advanced = app.buttons["task.advanced"]
        for _ in 0..<3 { if advanced.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(advanced.isHittable); advanced.tap()
        XCTAssertTrue(app.navigationBars["高级信息"].waitForExistence(timeout: 5))
        app.swipeUp(); capture("task-advanced-sheet")
        app.navigationBars["高级信息"].buttons["完成"].tap()
        XCTAssertTrue(app.navigationBars["任务详情"].exists)
    }
    func testAdvancedBackupChecksDefaultOffAndPersist() {
        let app = localizedApp(); app.launch()
        if app.buttons["稍后"].waitForExistence(timeout: 30) { app.buttons["稍后"].tap() }
        openAdvancedChecks(app)
        let toggle = app.switches["backup.strict"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); XCTAssertEqual(toggle.value as? String, "0")
        setSwitch(toggle, on: true); capture("advanced-backup-checks")
        app.terminate(); app.launch()
        if app.buttons["稍后"].waitForExistence(timeout: 30) { app.buttons["稍后"].tap() }
        openAdvancedChecks(app)
        XCTAssertEqual(app.switches["backup.strict"].value as? String, "1")
        setSwitch(app.switches["backup.strict"], on: false)
    }
    func testOriginalPairStrategiesCanBeSelectedAndPersisted() {
        let app = localizedApp()
        app.launch()
        if app.buttons["稍后"].waitForExistence(timeout: 30) { app.buttons["稍后"].tap() }
        app.tabBars.buttons["设置"].tap(); app.buttons["备份偏好"].tap()
        let joint = app.buttons["原始照片配对"]
        if !joint.isHittable { app.swipeUp() }
        XCTAssertTrue(joint.waitForExistence(timeout: 5)); joint.tap()
        capture("live-pair-joint-preference")
        let repair = app.buttons["原始照片配对（分步上传）"]
        if !repair.isHittable { app.swipeUp() }
        repair.tap()
        app.terminate(); app.launch()
        if app.buttons["稍后"].waitForExistence(timeout: 30) { app.buttons["稍后"].tap() }
        app.tabBars.buttons["设置"].tap(); app.buttons["备份偏好"].tap()
        if !app.buttons["原始照片配对（分步上传）"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.buttons["原始照片配对（分步上传）"].isSelected)
        capture("live-pair-reconcile-preference")
        let motion = app.buttons["动态照片封装"]
        if !motion.isHittable { app.swipeDown() }
        motion.tap()
    }
    func testActivityGroupingOptions() {
        let app = localizedApp()
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
        let app = localizedApp()
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
        let app = localizedApp()
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
        let app = localizedApp()
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
        let app = localizedApp()
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
    private func setSwitch(_ element: XCUIElement, on: Bool) {
        // SwiftUI exposes the label and control as one wide Switch element.
        // Tap the trailing native control, then assert the actual UI value.
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let value = NSPredicate(format: "value == %@", on ? "1" : "0")
        expectation(for: value, evaluatedWith: element)
        waitForExpectations(timeout: 5)
    }
    private func openAdvancedChecks(_ app: XCUIApplication) {
        app.tabBars.buttons["设置"].tap()
        XCTAssertFalse(app.buttons["高级备份检查"].exists)
        app.buttons["备份偏好"].tap()
        for _ in 0..<4 { if app.buttons["高级备份检查"].isHittable { break }; app.swipeUp() }
        app.buttons["高级备份检查"].tap()
    }
    private func authorizePhotosIfNeeded(in app: XCUIApplication) {
        let authorize = app.buttons["允许访问相册"]
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let names = ["Allow Full Access", "允许完全访问", "允许访问所有照片", "允许访问所有照片和视频"]
        let grants = names.flatMap { [app.buttons[$0], springboard.buttons[$0]] }
        guard authorize.exists || grants.contains(where: { $0.exists }) else { return }
        if authorize.exists { authorize.tap() }
        // Depending on the simulator's OS, this system alert is exposed under
        // the requesting app or SpringBoard. Exercise the real consent UI.
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in grants.contains(where: { $0.exists }) }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 10), .completed)
        grants.first(where: { $0.exists })?.tap()
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
