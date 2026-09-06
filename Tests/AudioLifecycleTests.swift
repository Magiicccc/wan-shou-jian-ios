import XCTest
@testable import WanShouJian

@MainActor
private final class FakeAudioSource: RhythmAudioSource {
    var permissions: [@MainActor (Bool) -> Void] = []
    var deliveries: [@MainActor (AudioFeatures, Double) -> Void] = []
    var events: [@MainActor (AudioCaptureEvent) -> Void] = []
    var activeEvent: (@MainActor (AudioCaptureEvent) -> Void)?
    var starts = 0
    var pauses = 0
    var stops = 0
    var shouldFail = false

    func requestPermission(_ completion: @escaping @MainActor (Bool) -> Void) { permissions.append(completion) }
    func start(onFeatures: @escaping @MainActor (AudioFeatures, Double) -> Void,
               onEvent: @escaping @MainActor (AudioCaptureEvent) -> Void) throws {
        if shouldFail { throw NSError(domain: "SyntheticAudio", code: 1) }
        starts += 1; deliveries.append(onFeatures); events.append(onEvent); activeEvent = onEvent
    }
    func pause(deactivateSession: Bool) { pauses += 1 }
    func stop() { stops += 1; activeEvent = nil }
    func emit(_ event: AudioCaptureEvent) { activeEvent?(event) }
}

final class AudioLifecycleTests: XCTestCase {
    private func freshPreferences() -> UserDefaults {
        let name = "AudioLifecycleTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return defaults
    }

    @MainActor
    private func waitForStarts(_ count: Int, source: FakeAudioSource) async {
        for _ in 0..<100 {
            if source.starts == count { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(source.starts, count)
    }

    func testLifecycleRejectsLateFramesAndResumeAfterStop() {
        var gate = RhythmLifecycle()
        XCTAssertFalse(gate.canRun)
        let first = gate.begin()
        XCTAssertTrue(gate.accepts(first))
        gate.interrupt()
        XCTAssertFalse(gate.accepts(first))
        gate.endInterruption(shouldResume: true)
        XCTAssertTrue(gate.canRun)
        gate.stop()
        gate.endInterruption(shouldResume: true)
        XCTAssertFalse(gate.canRun)
        XCTAssertFalse(gate.accepts(first))
    }

    func testLifecycleBackgroundAndMediaRecoveryRequireIntent() {
        var gate = RhythmLifecycle()
        gate.begin(); gate.isBackground = true
        XCTAssertTrue(gate.canRun)
        gate.backgroundEnabled = false
        XCTAssertFalse(gate.canRun)
        gate.isBackground = false
        XCTAssertTrue(gate.canRun)
        gate.mediaLost(); XCTAssertFalse(gate.canRun)
        gate.mediaReset(); XCTAssertFalse(gate.canRun)
        gate.begin(); XCTAssertTrue(gate.canRun)
        gate.endInterruption(shouldResume: false)
        XCTAssertFalse(gate.canRun)
        gate.begin(); XCTAssertTrue(gate.canRun)
        gate.stop(); gate.mediaReset(); XCTAssertFalse(gate.canRun)
    }

    @MainActor
    func testStoppingPermissionRequestBlocksLateGrant() {
        let manager = LightstickManager(preview: true)
        let source = FakeAudioSource()
        let session = RhythmSession(manager: manager, source: source, preferences: freshPreferences())
        session.start()
        XCTAssertEqual(session.phase, .requestingPermission)
        session.stop()
        source.permissions[0](true)
        XCTAssertEqual(source.starts, 0)
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.phase, .idle)
        XCTAssertFalse(manager.hasCreatedCentralManager)
    }

    @MainActor
    func testExplicitStopClearsExistingManagerIntentBeforeFirstAudioFrame() {
        let manager = LightstickManager(preview: true)
        manager.submitRhythmColor(LightRGB(red: 10, green: 20, blue: 30))
        XCTAssertNotNil(manager.lastRhythmColor)
        let session = RhythmSession(manager: manager, source: FakeAudioSource(), preferences: freshPreferences())
        session.stop()
        XCTAssertEqual(manager.lastRhythmColor, LightState.idle.color)
        XCTAssertEqual(session.light, .idle)
        XCTAssertFalse(session.isRunning)
    }

    @MainActor
    func testOldFramesAndOldEventsCannotAffectNewStart() {
        let source = FakeAudioSource()
        let session = RhythmSession(manager: LightstickManager(preview: true), source: source, preferences: freshPreferences())
        session.start(); source.permissions[0](true)
        let oldFrame = source.deliveries[0], oldEvent = source.events[0]
        session.stop()
        oldFrame(AudioFeatures(fastEnergy: 1, slowEnergy: 1, calibrationProgress: 1, hasSound: true), 0.05)
        XCTAssertEqual(session.light, .idle)
        session.start(); source.permissions[1](true)
        oldEvent(.interruptionBegan)
        XCTAssertTrue(session.isRunning)
        XCTAssertEqual(session.phase, .calibrating)
        session.stop()
    }

    @MainActor
    func testRecoverableInterruptionResumesAndStopCancelsRecovery() async {
        let source = FakeAudioSource()
        let session = RhythmSession(manager: LightstickManager(preview: true), source: source, recoveryDelayNanoseconds: 1, preferences: freshPreferences())
        session.start(); source.permissions[0](true)
        source.events[0](.interruptionBegan)
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.phase, .interrupted)
        source.events[0](.interruptionEnded(shouldResume: true))
        await waitForStarts(2, source: source)
        XCTAssertEqual(source.starts, 2)
        XCTAssertTrue(session.isRunning)
        source.events[1](.routeChanged)
        session.stop()
        try? await Task.sleep(nanoseconds: 2_000_000)
        XCTAssertEqual(source.starts, 2)
        XCTAssertFalse(session.isRunning)
    }

    @MainActor
    func testInterruptionWithoutResumeNeedsNewUserStart() async {
        let source = FakeAudioSource()
        let session = RhythmSession(manager: LightstickManager(preview: true), source: source, recoveryDelayNanoseconds: 1, preferences: freshPreferences())
        session.start(); source.permissions[0](true)
        source.events[0](.interruptionBegan)
        source.events[0](.interruptionEnded(shouldResume: false))
        source.events[0](.routeChanged)
        try? await Task.sleep(nanoseconds: 2_000_000)
        XCTAssertEqual(source.starts, 1)
        XCTAssertEqual(session.phase, .paused)
        session.start(); source.permissions[1](true)
        XCTAssertEqual(source.starts, 2)
        session.stop()
    }

    @MainActor
    func testPreviewIsExplicitAndCreatesNoAudioOrBluetooth() async {
        let manager = LightstickManager(preview: true)
        let source = FakeAudioSource()
        let session = RhythmSession(manager: manager, preview: true, source: source, preferences: freshPreferences())
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.phase, .idle)
        session.startPreview()
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertTrue(session.isRunning)
        XCTAssertTrue(source.permissions.isEmpty)
        XCTAssertEqual(source.starts, 0)
        XCTAssertFalse(manager.hasCreatedCentralManager)
        session.stop()
        XCTAssertEqual(session.light, .idle)
    }

    @MainActor
    func testMicrophoneFailureClearsIntentAndBackgroundDoesNotRestart() {
        let source = FakeAudioSource()
        source.shouldFail = true
        let session = RhythmSession(manager: LightstickManager(preview: true), source: source, preferences: freshPreferences())
        session.start(); source.permissions[0](true)
        XCTAssertEqual(session.phase, .failed)
        XCTAssertFalse(session.isRunning)
        session.sceneChanged(isBackground: true)
        session.sceneChanged(isBackground: false)
        XCTAssertEqual(source.starts, 0)
        session.stop()
    }

    @MainActor
    func testRouteRebuildDiscardsOldFramesAndMediaResetRequiresStart() async {
        let source = FakeAudioSource()
        let session = RhythmSession(manager: LightstickManager(preview: true), source: source, recoveryDelayNanoseconds: 1, preferences: freshPreferences())
        session.start(); source.permissions[0](true)
        let oldFrame = source.deliveries[0]
        source.events[0](.configurationChanged)
        await waitForStarts(2, source: source)
        XCTAssertEqual(source.starts, 2)
        oldFrame(AudioFeatures(fastEnergy: 1, slowEnergy: 1, calibrationProgress: 1, hasSound: true), 0.05)
        XCTAssertEqual(session.features.calibrationProgress, 0)
        source.events[1](.mediaServicesLost)
        source.events[1](.mediaServicesReset)
        source.events[1](.interruptionEnded(shouldResume: true))
        try? await Task.sleep(nanoseconds: 2_000_000)
        XCTAssertEqual(source.starts, 2)
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.phase, .paused)
        session.start(); source.permissions[1](true)
        XCTAssertEqual(source.starts, 3)
        session.stop()
    }

    @MainActor
    func testBluetoothDisconnectDimsPreviewWhileAudioContinues() {
        let manager = LightstickManager(preview: true)
        let source = FakeAudioSource()
        let session = RhythmSession(manager: manager, source: source, preferences: freshPreferences())
        session.start(); source.permissions[0](true)
        let frame = AudioFeatures(fastEnergy: 0.8, slowEnergy: 0.8, calibrationProgress: 1, hasSound: true)
        for _ in 0..<30 { source.deliveries[0](frame, 0.05) }
        let active = session.light.energy
        manager.disconnect()
        XCTAssertTrue(session.isRunning)
        XCTAssertLessThan(session.light.energy, active)
        XCTAssertGreaterThan(session.features.slowEnergy, 0)
        session.stop()
        XCTAssertNil(manager.lastRhythmColor)
        XCTAssertEqual(session.light, .idle)
    }

    @MainActor
    func testBackgroundKeepsStartedAudioAndDisabledBackgroundResumesForeground() async {
        let source = FakeAudioSource()
        let session = RhythmSession(manager: LightstickManager(preview: true), source: source, recoveryDelayNanoseconds: 1, preferences: freshPreferences())
        session.start(); source.permissions[0](true)
        session.sceneChanged(isBackground: true)
        XCTAssertTrue(session.isRunning)
        XCTAssertEqual(source.starts, 1)
        session.backgroundEnabled = false
        XCTAssertFalse(session.isRunning)
        session.sceneChanged(isBackground: false)
        await waitForStarts(2, source: source)
        XCTAssertTrue(session.isRunning)
        XCTAssertEqual(source.starts, 2)
        session.stop()
        session.sceneChanged(isBackground: true)
        session.sceneChanged(isBackground: false)
        try? await Task.sleep(nanoseconds: 2_000_000)
        XCTAssertEqual(source.starts, 2)
    }

    @MainActor
    func testPendingPermissionGrantedInPausedBackgroundResumesForeground() async {
        let source = FakeAudioSource()
        let session = RhythmSession(manager: LightstickManager(preview: true), source: source,
                                    recoveryDelayNanoseconds: 1, preferences: freshPreferences())
        session.backgroundEnabled = false
        session.start()
        session.sceneChanged(isBackground: true)
        source.permissions[0](true)
        XCTAssertEqual(source.starts, 0)
        XCTAssertEqual(session.phase, .paused)
        session.sceneChanged(isBackground: false)
        await waitForStarts(1, source: source)
        XCTAssertTrue(session.isRunning)
        session.stop()
    }

    @MainActor
    func testBackgroundPauseRetainsInterruptionEndSubscription() async {
        let source = FakeAudioSource()
        let session = RhythmSession(manager: LightstickManager(preview: true), source: source,
                                    recoveryDelayNanoseconds: 1, preferences: freshPreferences())
        session.backgroundEnabled = false
        session.start(); source.permissions[0](true)
        source.emit(.interruptionBegan)
        session.sceneChanged(isBackground: true)
        XCTAssertNotNil(source.activeEvent)
        source.emit(.interruptionEnded(shouldResume: true))
        XCTAssertEqual(source.starts, 1)
        session.sceneChanged(isBackground: false)
        await waitForStarts(2, source: source)
        XCTAssertTrue(session.isRunning)
        session.stop()
        XCTAssertNil(source.activeEvent)
        source.emit(.interruptionEnded(shouldResume: true))
        XCTAssertFalse(session.isRunning)
    }

    @MainActor
    func testStoppedBackgroundPermissionCannotReviveIntent() async {
        let source = FakeAudioSource()
        let session = RhythmSession(manager: LightstickManager(preview: true), source: source,
                                    recoveryDelayNanoseconds: 1, preferences: freshPreferences())
        session.backgroundEnabled = false
        session.start(); session.sceneChanged(isBackground: true); session.stop()
        source.permissions[0](true)
        session.sceneChanged(isBackground: false)
        try? await Task.sleep(nanoseconds: 2_000_000)
        XCTAssertEqual(source.starts, 0)
        XCTAssertEqual(session.phase, .idle)
    }

    @MainActor
    func testDisplayUsesSubmittedColorAndClearsWhenManagerEndsIntent() {
        let manager = LightstickManager(preview: true)
        let source = FakeAudioSource()
        let session = RhythmSession(manager: manager, source: source, preferences: freshPreferences())
        session.start(); source.permissions[0](true)
        let frame = AudioFeatures(fastEnergy: 0.4, slowEnergy: 0.4, calibrationProgress: 1, hasSound: true)
        for _ in 0..<30 { source.deliveries[0](frame, 0.05) }
        XCTAssertEqual(session.light.color, manager.lastRhythmColor)
        let submitted = LightRGB(red: 13, green: 24, blue: 35)
        manager.submitRhythmColor(submitted)
        XCTAssertEqual(session.light.color, submitted)
        let energy = session.light.energy
        manager.endRhythm(sendBlack: false)
        XCTAssertEqual(session.light.color, LightState.idle.color)
        XCTAssertEqual(session.light.energy, energy)
        XCTAssertTrue(session.isRunning)
        XCTAssertFalse(manager.hasCreatedCentralManager)
        session.stop()
        XCTAssertEqual(manager.lastRhythmColor, LightState.idle.color)
        XCTAssertEqual(session.light, .idle)
    }
}
