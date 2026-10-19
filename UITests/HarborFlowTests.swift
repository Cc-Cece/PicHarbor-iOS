import XCTest

final class HarborFlowTests: XCTestCase {
    func testExternalCleanupGuideHasNoDeletionControls() {
        let app = localizedApp(); app.launch()
        if app.buttons["稍后"].waitForExistence(timeout: 30) { app.buttons["稍后"].tap() }
        app.tabBars.buttons["备份"].tap()
        let guide = app.buttons["释放 iPhone 空间"]
        for _ in 0..<4 { if guide.isHittable { break }; app.swipeUp() }
        guide.tap()
        XCTAssertTrue(app.buttons["googlePhotos.open"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["googlePhotos.openApp"].exists)
        app.buttons["googlePhotos.alternatives"].tap()
        XCTAssertTrue(app.buttons["googlePhotos.openApp"].waitForExistence(timeout: 5))
        app.buttons["googlePhotos.alternatives"].tap()
        XCTAssertFalse(app.buttons["googlePhotos.openApp"].exists)
        XCTAssertFalse(app.buttons["googlePhotos.linkTests"].exists)
        XCTAssertFalse(app.buttons["开始检查"].exists)
        XCTAssertFalse(app.switches["cleanup.allowLive"].exists)
        capture("google-photos-cleanup-guide")
        app.buttons["googlePhotos.open"].tap()
        XCTAssertTrue(app.alerts["暂时无法直达释放空间"].waitForExistence(timeout: 5))
        app.alerts.buttons["好"].tap()
        XCTAssertTrue(app.buttons["googlePhotos.openApp"].waitForExistence(timeout: 5))
    }
    private func localizedApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-AppleLocale", "zh_CN"]
        return app
    }
    func testArchiveSettingsValidateInputAndArchiveEntryOpens() {
        let app = localizedApp(); app.launch()
        if app.buttons["稍后"].waitForExistence(timeout: 30) { app.buttons["稍后"].tap() }
        app.tabBars.buttons["设置"].tap(); app.buttons["活动记录"].tap()
        let days = app.textFields["archive.days"]
        XCTAssertTrue(days.waitForExistence(timeout: 5)); XCTAssertEqual(days.value as? String, "14")
        days.tap(); days.typeText(XCUIKeyboardKey.delete.rawValue + XCUIKeyboardKey.delete.rawValue + "91")
        app.buttons["archive.save"].tap()
        XCTAssertTrue(app.staticTexts["请输入 1–90 的整数。"].exists)
        days.tap(); days.typeText(XCUIKeyboardKey.delete.rawValue + XCUIKeyboardKey.delete.rawValue + "14")
        app.buttons["archive.save"].tap()
        XCTAssertFalse(app.staticTexts["请输入 1–90 的整数。"].exists)
        app.buttons["归档记录"].tap()
        XCTAssertTrue(app.navigationBars["归档记录"].waitForExistence(timeout: 5)); capture("archive-empty")
    }
    func testLanguageSwitchingPersistsWithoutLeavingSettings() {
        let app = localizedApp(); app.launch()
        if app.buttons["稍后"].waitForExistence(timeout: 30) { app.buttons["稍后"].tap() }
        app.tabBars.buttons["设置"].tap(); app.buttons["settings.interface"].tap()
        app.buttons["English"].tap()
        XCTAssertTrue(app.navigationBars["Interface"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Photos"].exists); capture("language-english")
        app.buttons["粵語（香港）"].tap()
        XCTAssertTrue(app.navigationBars["介面"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["相片"].exists); capture("language-hong-kong")
        app.terminate(); app.launch()
        if app.buttons["稍後"].waitForExistence(timeout: 30) { app.buttons["稍後"].tap() }
        app.tabBars.buttons["設定"].tap(); app.buttons["settings.interface"].tap()
        XCTAssertTrue(app.buttons["粵語（香港）"].isSelected)
        app.buttons["跟隨系統"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["界面"].waitForExistence(timeout: 5))
    }
    func testRestoreDefaultsRequiresConfirmationAndRestoresPairing() {
        let app = localizedApp(); app.launch()
        if app.buttons["稍后"].waitForExistence(timeout: 30) { app.buttons["稍后"].tap() }
        app.tabBars.buttons["设置"].tap(); app.buttons["备份偏好"].tap()
        choosePreference(app, "preferences.quality", "节省空间")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let restore = app.buttons["settings.restore"]
        for _ in 0..<3 { if restore.isHittable { break }; app.swipeUp() }
        restore.tap(); app.alerts.buttons["取消"].tap()
        app.swipeDown(); app.buttons["备份偏好"].tap()
        assertPreference(app, "preferences.quality", "节省空间")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        for _ in 0..<3 { if restore.isHittable { break }; app.swipeUp() }
        restore.tap(); app.alerts.buttons["恢复默认设置"].tap()
        XCTAssertTrue(app.alerts.staticTexts["已恢复默认设置。自动备份已关闭，请重新确认备份范围。"].waitForExistence(timeout: 10))
        app.alerts.buttons["好"].tap(); app.swipeDown(); app.buttons["备份偏好"].tap()
        assertPreference(app, "preferences.quality", "不计配额原画质")
        assertPreference(app, "preferences.live", "原始照片配对"); capture("restored-defaults")
    }
    func testQueueNoticeHidesAfterTenSeconds() {
        let app = localizedApp(); app.launchArguments += ["--task-review-fixture", "--queue-notice-fixture"]; app.launch()
        XCTAssertTrue(app.buttons["关闭备份提示"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts["已加入备份队列 · 2 项"].exists)
        let hidden = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.buttons["关闭备份提示"])
        XCTAssertEqual(XCTWaiter.wait(for: [hidden], timeout: 15), .completed)
        XCTAssertTrue(app.navigationBars["活动"].exists)
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
        choosePreference(app, "preferences.live", "原始照片配对")
        capture("live-pair-joint-preference")
        choosePreference(app, "preferences.live", "原始照片配对（分步上传）")
        app.terminate(); app.launch()
        if app.buttons["稍后"].waitForExistence(timeout: 30) { app.buttons["稍后"].tap() }
        app.tabBars.buttons["设置"].tap(); app.buttons["备份偏好"].tap()
        assertPreference(app, "preferences.live", "原始照片配对（分步上传）")
        capture("live-pair-reconcile-preference")
        choosePreference(app, "preferences.live", "动态照片封装")
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
        choosePreference(app, "preferences.quality", "计配额原画质")
        app.terminate(); app.launch()
        if app.buttons["稍后"].waitForExistence(timeout: 30) { app.buttons["稍后"].tap() }
        app.tabBars.buttons["设置"].tap()
        app.buttons["备份偏好"].tap()
        assertPreference(app, "preferences.quality", "计配额原画质")
        choosePreference(app, "preferences.quality", "不计配额原画质")
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
        app.buttons["photo.info"].tap()
        XCTAssertTrue(app.navigationBars["详情"].waitForExistence(timeout: 5)); capture("photo-information")
        app.navigationBars["详情"].buttons["完成"].tap()
        XCTAssertTrue(app.buttons["photo.share"].exists)
        app.buttons["关闭"].tap()
        app.tabBars.buttons["备份"].tap()
        XCTAssertTrue(app.navigationBars["备份"].waitForExistence(timeout: 5)); capture("backup")
        app.buttons["备份偏好"].tap()
        assertPreference(app, "preferences.quality", "不计配额原画质")
        capture("backup-preferences")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.tabBars.buttons["活动"].tap()
        XCTAssertTrue(app.navigationBars["活动"].waitForExistence(timeout: 5)); capture("activity-empty")
        app.tabBars.buttons["设置"].tap()
        XCTAssertTrue(app.navigationBars["设置"].waitForExistence(timeout: 5)); capture("settings")
        XCTAssertFalse(app.buttons["空间清理核验"].exists)
        XCTAssertFalse(app.buttons["settings.linkTests"].exists)
        app.buttons["settings.interface"].tap()
        app.buttons["深色"].tap()
        capture("appearance-dark")
        app.tabBars.buttons["备份"].tap()
        let guide = app.buttons["释放 iPhone 空间"]
        for _ in 0..<4 { if guide.isHittable { break }; app.swipeUp() }
        guide.tap()
        XCTAssertTrue(app.buttons["googlePhotos.open"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["开始检查"].exists)
        capture("cleanup-official-handoff")
    }
    private func setSwitch(_ element: XCUIElement, on: Bool) {
        // SwiftUI exposes the label and control as one wide Switch element.
        // Tap the trailing native control, then assert the actual UI value.
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        let value = NSPredicate(format: "value == %@", on ? "1" : "0")
        expectation(for: value, evaluatedWith: element)
        waitForExpectations(timeout: 5)
    }
    private func choosePreference(_ app: XCUIApplication, _ identifier: String, _ title: String) {
        let picker = app.buttons[identifier]
        XCTAssertTrue(picker.waitForExistence(timeout: 5)); picker.tap()
        let option = app.buttons.matching(identifier: title).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5)); option.tap()
        assertPreference(app, identifier, title)
    }
    private func assertPreference(_ app: XCUIApplication, _ identifier: String, _ title: String) {
        let picker = app.buttons[identifier]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertTrue((picker.label + " " + (picker.value as? String ?? "")).contains(title))
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
