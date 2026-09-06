import XCTest

final class ManualControlUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func tearDownWithError() throws {
        let app = XCUIApplication()
        if app.state == .runningForeground {
            attach(app, name: "final-ui-state")
            let hierarchy = app.debugDescription
            let attachment = XCTAttachment(string: hierarchy)
            attachment.name = "accessibility-hierarchy"
            attachment.lifetime = .keepAlways
            add(attachment)
            if testRun?.hasSucceeded == false { print(hierarchy) }
        }
    }

    func testPreviewHasReachableControlsAndChangesColorWithoutConnecting() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview"]
        app.launch()

        XCTAssertTrue(app.buttons["wake-rhythm"].waitForExistence(timeout: 10))
        attach(app, name: "01-rhythm-home")
        app.buttons["tab-1"].tap()
        app.buttons["open-manual"].tap()

        let primary = app.buttons["primary-control"]
        XCTAssertTrue(primary.waitForExistence(timeout: 10))
        XCTAssertEqual(primary.label, "界面演示")
        XCTAssertFalse(primary.isEnabled)
        XCTAssertTrue(primary.frame.intersects(app.frame))
        attach(app, name: "02-manual-preview")

        let red = app.buttons["preset-red"]
        reveal(red, in: app)
        red.tap()
        XCTAssertEqual(red.value as? String, "已选择")

        let brightness = app.sliders["brightness-slider"]
        reveal(brightness, in: app)
        brightness.adjust(toNormalizedSliderPosition: 0.5)
        XCTAssertTrue(app.staticTexts["brightness-value"].label.contains("%"))
        XCTAssertFalse(primary.isEnabled)
        attach(app, name: "03-red-controls-preview")
    }

    func testLargeTextKeepsPrimaryActionOnScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let primary = app.buttons["wake-rhythm"]
        XCTAssertTrue(primary.waitForExistence(timeout: 10))
        XCTAssertTrue(primary.frame.intersects(app.frame))
        XCTAssertTrue(primary.isEnabled)
        XCTAssertTrue(app.buttons["tab-2"].isHittable)
        attach(app, name: "04-accessibility-home")
    }

    func testSyntheticRhythmStartsAndStopsFromImmersiveView() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview"]
        app.launch()
        let wake = app.buttons["wake-rhythm"]
        XCTAssertTrue(wake.waitForExistence(timeout: 10))
        wake.tap()
        let stop = app.buttons["stop-rhythm"]
        XCTAssertTrue(stop.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["合成音乐预览"].exists)
        attach(app, name: "05-immersive-preview")
        stop.tap()
        XCTAssertTrue(wake.waitForExistence(timeout: 5))
        XCTAssertEqual(wake.label, "预览律动")
    }

    func testBackgroundSettingIsInteractive() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview"]
        app.launch()
        XCTAssertTrue(app.buttons["tab-2"].waitForExistence(timeout: 10))
        app.buttons["tab-2"].tap()
        let toggle = app.switches["background-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        let original = toggle.value as? String
        toggle.tap()
        XCTAssertNotEqual(toggle.value as? String, original)
        toggle.tap()
        XCTAssertEqual(toggle.value as? String, original)
        attach(app, name: "06-background-settings")
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let scroll = app.scrollViews.firstMatch
        let primary = app.buttons["primary-control"]
        for _ in 0..<8 {
            guard element.exists else {
                scroll.swipeUp(velocity: .slow)
                continue
            }
            let frame = element.frame
            let top = max(scroll.frame.minY, app.frame.minY) + 44
            let bottom = min(scroll.frame.maxY, primary.frame.minY - 12)
            // SwiftUI can report a partially clipped control as hittable behind the fixed footer.
            if frame.height > 0 && frame.minY >= top && frame.maxY <= bottom && element.isHittable {
                return
            }
            if frame.minY < top {
                scroll.swipeDown(velocity: .slow)
            } else {
                scroll.swipeUp(velocity: .slow)
            }
        }
        XCTFail("The requested control must be fully visible above the fixed footer before interaction.")
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
