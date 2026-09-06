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

        let primary = app.buttons["primary-control"]
        XCTAssertTrue(primary.waitForExistence(timeout: 10))
        XCTAssertEqual(primary.label, "界面演示")
        XCTAssertFalse(primary.isEnabled)
        XCTAssertTrue(primary.frame.intersects(app.frame))
        attach(app, name: "01-initial-preview")

        let red = app.buttons["preset-red"]
        reveal(red, in: app)
        red.tap()
        XCTAssertEqual(red.value as? String, "已选择")

        let brightness = app.sliders["brightness-slider"]
        reveal(brightness, in: app)
        brightness.adjust(toNormalizedSliderPosition: 0.5)
        XCTAssertTrue(app.staticTexts["brightness-value"].label.contains("%"))
        XCTAssertFalse(primary.isEnabled)
        attach(app, name: "02-red-controls-preview")
    }

    func testLargeTextKeepsPrimaryActionOnScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["--preview", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        let primary = app.buttons["primary-control"]
        XCTAssertTrue(primary.waitForExistence(timeout: 10))
        XCTAssertTrue(primary.frame.intersects(app.frame))
        XCTAssertFalse(primary.isEnabled)
        let blue = app.buttons["preset-blue"]
        reveal(blue, in: app)
        XCTAssertTrue(blue.isHittable)
        attach(app, name: "03-accessibility-preview")
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 {
            if element.isHittable { return }
            app.scrollViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(element.isHittable)
    }

    private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
