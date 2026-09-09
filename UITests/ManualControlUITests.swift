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
        let homeBrightness = app.sliders["rhythm-brightness"]
        XCTAssertTrue(homeBrightness.isHittable)
        XCTAssertLessThan(homeBrightness.frame.maxY, app.buttons["wake-rhythm"].frame.minY)
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
        XCTAssertLessThan(app.staticTexts["immersive-stage"].frame.maxY,
                          app.sliders["immersive-brightness"].frame.minY)
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

    func testKaraokeDemoAndAISettingsAreReachable() {
        let app=XCUIApplication()
        app.launchArguments=["--preview"]
        app.launch()
        XCTAssertTrue(app.buttons["tab-3"].waitForExistence(timeout:10))
        app.buttons["tab-3"].tap()
        let play=app.buttons["stage-play"]
        XCTAssertTrue(play.waitForExistence(timeout:5))
        XCTAssertTrue(play.isHittable)
        play.tap()
        XCTAssertEqual(play.label,"暂停舞台")
        let progress=app.sliders["stage-progress"]
        progress.adjust(toNormalizedSliderPosition:0.55)
        attach(app,name:"07-kinetic-stage")
        play.tap()
        app.buttons["stage-menu"].tap()
        app.buttons["AI 接口设置"].tap()
        XCTAssertTrue(app.secureTextFields["API Key"].waitForExistence(timeout:5))
        attach(app,name:"08-ai-settings")
    }

    func testExternalMusicEntryAndReviewWorkWithoutImport() {
        let app=XCUIApplication()
        app.launchArguments=["--preview"]
        app.launch()
        XCTAssertTrue(app.buttons["tab-3"].waitForExistence(timeout:10))
        app.buttons["tab-3"].tap()
        app.buttons["external-music"].tap()
        let start=app.buttons["external-start"]
        XCTAssertTrue(start.waitForExistence(timeout:5))
        XCTAssertTrue(start.isHittable)
        attach(app,name:"09-external-music-setup")
        start.tap()
        XCTAssertTrue(app.staticTexts["external-elapsed"].waitForExistence(timeout:5))
        XCTAssertFalse(app.sliders["stage-progress"].exists)
        XCTAssertEqual(app.buttons["stage-play"].label,"暂停舞台")
        attach(app,name:"10-external-stage")
        app.buttons["stage-play"].tap()
        XCTAssertEqual(app.buttons["stage-play"].label,"开始舞台")
        XCTAssertTrue(app.staticTexts["stage-status"].label.contains("已跳过系统媒体请求"))
        attach(app,name:"10b-external-media-pause")
        app.buttons["stage-finish"].tap()
        XCTAssertTrue(app.staticTexts["这一段，听见自己"].waitForExistence(timeout:5))
        attach(app,name:"11-external-review")
    }

    func testExternalLyricsCanBeAlignedWithoutImportOrNetwork() {
        let app=XCUIApplication()
        app.launchArguments=["--preview"]
        app.launch()
        XCTAssertTrue(app.buttons["tab-3"].waitForExistence(timeout:10))
        app.buttons["tab-3"].tap()
        app.buttons["external-music"].tap()
        app.buttons["external-start"].tap()
        let lyrics=app.buttons["open-lyrics"]
        XCTAssertTrue(lyrics.waitForExistence(timeout:5))
        lyrics.tap()
        let demo=app.buttons["lyrics-preview"]
        for _ in 0..<5 { if demo.isHittable { break };app.swipeUp() }
        XCTAssertTrue(demo.isHittable);demo.tap()
        let line=app.buttons["lyric-line-1"]
        for _ in 0..<6 {
            if line.isHittable { break }
            if line.exists && line.frame.minY<100 { app.swipeDown() }
            else { app.swipeUp() }
        }
        XCTAssertTrue(line.isHittable)
        attach(app,name:"12-lyrics-alignment")
        line.tap()
        XCTAssertTrue(app.otherElements["stage-current-lyric"].waitForExistence(timeout:5) || app.staticTexts["stage-current-lyric"].exists)
        XCTAssertTrue(app.buttons["open-lyrics"].label.contains("手动对齐"))
        attach(app,name:"13-external-synced-lyrics")
        app.buttons["stage-play"].tap()
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
