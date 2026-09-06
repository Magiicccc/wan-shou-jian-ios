import XCTest
@testable import WanShouJian

final class AudioSettingsTests: XCTestCase {
    private func freshPreferences() -> UserDefaults {
        let name = "AudioSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    @MainActor
    func testEmptySettingsHaveProductDefaultsWithoutStartingResources() {
        let manager = LightstickManager(preview: true)
        let session = RhythmSession(manager: manager, preferences: freshPreferences())
        XCTAssertEqual(session.intensity, 1)
        XCTAssertEqual(session.brightnessLimit, 0.55)
        XCTAssertTrue(session.antiFlash)
        XCTAssertTrue(session.backgroundEnabled)
        XCTAssertFalse(session.isRunning)
        XCTAssertFalse(manager.hasCreatedCentralManager)
        XCTAssertNil(manager.lastRhythmColor)
    }

    @MainActor
    func testSettingsRoundTripAcrossSessionInstances() {
        let preferences = freshPreferences()
        let first = RhythmSession(manager: LightstickManager(preview: true), preview: true, preferences: preferences)
        first.intensity = 1.5
        first.brightnessLimit = 0.34
        first.antiFlash = false
        first.backgroundEnabled = false
        let second = RhythmSession(manager: LightstickManager(preview: true), preview: true, preferences: preferences)
        XCTAssertEqual(second.intensity, 1.5)
        XCTAssertEqual(second.brightnessLimit, 0.34)
        XCTAssertFalse(second.antiFlash)
        XCTAssertFalse(second.backgroundEnabled)
        XCTAssertEqual(second.phase, .idle)
    }

    @MainActor
    func testInvalidPersistedValuesFallBackToProductDefaults() {
        let preferences = freshPreferences()
        preferences.set(Double.infinity, forKey: "rhythm.intensity")
        preferences.set(-0.1, forKey: "rhythm.brightnessLimit")
        preferences.set("false", forKey: "rhythm.antiFlash")
        preferences.set(2, forKey: "rhythm.backgroundEnabled")
        let session = RhythmSession(manager: LightstickManager(preview: true), preferences: preferences)
        XCTAssertEqual(session.intensity, 1)
        XCTAssertEqual(session.brightnessLimit, 0.55)
        XCTAssertTrue(session.antiFlash)
        XCTAssertTrue(session.backgroundEnabled)
    }

    @MainActor
    func testBooleanCannotBecomeNumericSettingAndNaNIsRejected() {
        let preferences = freshPreferences()
        preferences.set(true, forKey: "rhythm.intensity")
        preferences.set(Double.nan, forKey: "rhythm.brightnessLimit")
        let session = RhythmSession(manager: LightstickManager(preview: true), preferences: preferences)
        XCTAssertEqual(session.intensity, 1)
        XCTAssertEqual(session.brightnessLimit, 0.55)
        preferences.set(2.5, forKey: "rhythm.intensity")
        preferences.set("0.5", forKey: "rhythm.brightnessLimit")
        let next = RhythmSession(manager: LightstickManager(preview: true), preferences: preferences)
        XCTAssertEqual(next.intensity, 1)
        XCTAssertEqual(next.brightnessLimit, 0.55)
    }

    @MainActor
    func testLiveAssignmentsAreFiniteAndBoundedBeforePersistence() {
        let preferences = freshPreferences()
        let session = RhythmSession(manager: LightstickManager(preview: true), preferences: preferences)
        session.intensity = .nan
        session.brightnessLimit = .infinity
        XCTAssertEqual(session.intensity, 1)
        XCTAssertEqual(session.brightnessLimit, 0.55)
        session.intensity = 8
        session.brightnessLimit = -4
        XCTAssertEqual(session.intensity, 2)
        XCTAssertEqual(session.brightnessLimit, 0)
        XCTAssertEqual(preferences.double(forKey: "rhythm.intensity"), 2)
        XCTAssertEqual(preferences.double(forKey: "rhythm.brightnessLimit"), 0)
        session.intensity = -1
        session.brightnessLimit = 3
        XCTAssertEqual(session.intensity, 0.3)
        XCTAssertEqual(session.brightnessLimit, 1)
    }
}
