import XCTest
@testable import WanShouJian

final class LightstickSessionTests: XCTestCase {
    func testReleaseGateBlocksReplacementUntilTerminalCallback() throws {
        var gate = LightstickSessionGate()
        let first = UUID()
        let second = UUID()
        let token = try XCTUnwrap(gate.begin(first))
        XCTAssertTrue(gate.accepts(first, generation: token))
        gate.beginRelease()
        XCTAssertFalse(gate.accepts(first, generation: token))
        XCTAssertNil(gate.begin(second))
        XCTAssertFalse(gate.finish(second))
        XCTAssertFalse(gate.canBegin)
        XCTAssertTrue(gate.finish(first))
        let replacement = try XCTUnwrap(gate.begin(second))
        XCTAssertGreaterThan(replacement, token)
        XCTAssertFalse(gate.accepts(first))
        XCTAssertTrue(gate.accepts(second, generation: replacement))
    }

    func testGenerationInvalidatesOldTimersAcrossSameDeviceReconnect() throws {
        var gate = LightstickSessionGate()
        let id = UUID()
        let old = try XCTUnwrap(gate.begin(id))
        gate.beginRelease()
        gate.finish(id)
        let fresh = try XCTUnwrap(gate.begin(id))
        XCTAssertFalse(gate.accepts(id, generation: old))
        XCTAssertTrue(gate.accepts(id, generation: fresh))
    }

    func testRadioInvalidationReleasesSessionWithoutWaitingForTerminalCallback() throws {
        var gate = LightstickSessionGate()
        let staleDevice = UUID()
        let newDevice = UUID()
        let staleToken = try XCTUnwrap(gate.begin(staleDevice))
        gate.beginRelease()
        gate.invalidate()
        XCTAssertTrue(gate.canBegin)
        XCTAssertFalse(gate.isReleasing)
        XCTAssertFalse(gate.accepts(staleDevice, generation: staleToken))
        let newToken = try XCTUnwrap(gate.begin(newDevice))
        XCTAssertFalse(gate.finish(staleDevice))
        XCTAssertTrue(gate.accepts(newDevice, generation: newToken))
    }

    func testRadioInvalidationRequiresFreshGenerationForSameDevice() throws {
        var gate = LightstickSessionGate()
        let id = UUID()
        let staleToken = try XCTUnwrap(gate.begin(id))
        gate.invalidate()
        let newToken = try XCTUnwrap(gate.begin(id))
        XCTAssertTrue(gate.accepts(id, generation: newToken))
        XCTAssertFalse(gate.accepts(id, generation: staleToken))
    }

    func testLatestOnlyQueueKeepsNewestColorWhileBackpressured() throws {
        var queue = LatestLightQueue()
        let red = LightRGB(red: 255, green: 0, blue: 0)
        let green = LightRGB(red: 0, green: 64, blue: 0)
        queue.offer(red)
        XCTAssertNil(queue.take(at: 0, capacityAvailable: false))
        queue.offer(green)
        let value = try XCTUnwrap(queue.take(at: 0, capacityAvailable: true))
        XCTAssertEqual(value.sequence, 1)
        XCTAssertEqual(value.color, green)
        XCTAssertFalse(queue.hasPending)
    }

    func testQueueEnforcesDevelopmentPacingAndResetsSequence() throws {
        var queue = LatestLightQueue()
        let color = LightRGB(red: 0, green: 64, blue: 0)
        queue.offer(color)
        XCTAssertEqual(queue.take(at: 1, capacityAvailable: true)?.sequence, 1)
        queue.offer(color)
        XCTAssertNil(queue.take(at: 1.1, capacityAvailable: true))
        XCTAssertEqual(queue.delay(at: 1.1), 0.1, accuracy: 0.000001)
        XCTAssertEqual(queue.take(at: 1.201, capacityAvailable: true)?.sequence, 2)
        queue.offer(color)
        queue.reset()
        XCTAssertFalse(queue.hasPending)
        queue.offer(color)
        XCTAssertEqual(queue.take(at: 2, capacityAvailable: true)?.sequence, 1)
    }

    func testQueueStopsAtUInt32BoundaryAndPreservesPendingColor() throws {
        var queue = LatestLightQueue(nextSequence: .max)
        let color = LightRGB(red: 1, green: 2, blue: 3)
        queue.offer(color)
        XCTAssertEqual(queue.take(at: 1, capacityAvailable: true)?.sequence, UInt32.max)
        XCTAssertTrue(queue.sequenceExhausted)
        queue.offer(color)
        XCTAssertNil(queue.take(at: 2, capacityAvailable: true))
        XCTAssertTrue(queue.hasPending)
    }

    func testDevicePolicyUsesConfiguredHashFirmwareAndLTName() {
        let sampleMAC = "12:34:56:78:9A:BC"
        let hash = LightstickDevicePolicy.hashMAC(sampleMAC)
        let policy = LightstickDevicePolicy(expectedMACHash: hash.uppercased())
        XCTAssertTrue(policy.accepts(name: "LTDEMO", mac: sampleMAC, firmware: "v0.20.14"))
        XCTAssertFalse(policy.accepts(name: "SPEAKER", mac: sampleMAC, firmware: "v0.20.14"))
        XCTAssertFalse(policy.accepts(name: "LTDEMO", mac: "12:34:56:78:9A:BD", firmware: "v0.20.14"))
        XCTAssertFalse(policy.accepts(name: "LTDEMO", mac: sampleMAC, firmware: "v0.20.15"))
        XCTAssertFalse(LightstickDevicePolicy(expectedMACHash: "").isConfigured)
        XCTAssertFalse(LightstickDevicePolicy(expectedMACHash: String(repeating: "g", count: 64)).isConfigured)
    }

    func testResponseWindowLimitsReadsAndUsesRemainingDeadline() {
        var window = LightstickResponseWindow()
        XCTAssertFalse(window.canScheduleRead(at: 0))
        window.start(at: 10)
        XCTAssertTrue(window.canScheduleRead(at: 10))
        XCTAssertEqual(window.beginRead(at: 10.6), 5)
        XCTAssertEqual(window.beginRead(at: 11.2) ?? 0, 4.8, accuracy: 0.000001)
        XCTAssertEqual(window.beginRead(at: 11.8) ?? 0, 4.2, accuracy: 0.000001)
        XCTAssertEqual(window.attempts, 3)
        XCTAssertFalse(window.canScheduleRead(at: 12))
        XCTAssertNil(window.beginRead(at: 12))
    }

    func testResponseWindowRejectsDelayedReadAndLateResponse() {
        var window = LightstickResponseWindow()
        window.start(at: 10)
        XCTAssertFalse(window.canScheduleRead(at: 15.5))
        XCTAssertNil(window.beginRead(at: 16))
        XCTAssertFalse(window.isOpen(at: 16))
        XCTAssertFalse(window.isOpen(at: .nan))
        window.start(at: 20)
        XCTAssertEqual(window.attempts, 0)
        XCTAssertEqual(window.beginRead(at: 25.8) ?? 0, 0.2, accuracy: 0.000001)
        window.start(at: .infinity)
        XCTAssertFalse(window.isOpen(at: 0))
    }

    func testRhythmRecoveryRequiresSelectedDeviceAndExplicitRhythmIntent() {
        var intent = LightstickRhythmIntent()
        intent.setBackgroundEnabled(true)
        XCTAssertFalse(intent.permitsRecovery(inBackground: true))
        intent.start(at: Date())
        XCTAssertFalse(intent.permitsRecovery(inBackground: false))
        intent.select(UUID(), name: "LTDEMO")
        XCTAssertTrue(intent.permitsRecovery(inBackground: true))
        intent.setBackgroundEnabled(false)
        XCTAssertTrue(intent.permitsRecovery(inBackground: false))
        XCTAssertFalse(intent.permitsRecovery(inBackground: true))
        intent.stop()
        XCTAssertFalse(intent.permitsRecovery(inBackground: false))
        XCTAssertNotNil(intent.selectedID)
    }

    func testRhythmRecoveryBudgetIsBoundedAndStopInvalidatesPendingGeneration() {
        var intent = LightstickRhythmIntent()
        intent.select(UUID(), name: "LTDEMO")
        intent.start(at: Date())
        let token = intent.generation
        XCTAssertEqual(intent.nextRetryDelay(inBackground: false), 1)
        XCTAssertEqual(intent.nextRetryDelay(inBackground: false), 2)
        XCTAssertEqual(intent.nextRetryDelay(inBackground: false), 4)
        XCTAssertEqual(intent.nextRetryDelay(inBackground: false), 8)
        XCTAssertNil(intent.nextRetryDelay(inBackground: false))
        intent.stop()
        XCTAssertGreaterThan(intent.generation, token)
        XCTAssertNil(intent.nextRetryDelay(inBackground: false))
        intent.start(at: Date())
        XCTAssertEqual(intent.nextRetryDelay(inBackground: false), 1)
        intent.stop(clearSelection: true)
        XCTAssertNil(intent.selectedID)
    }

    func testRestorationIntentHasBoundedAgeAndSurvivesEncoding() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        var intent = LightstickRhythmIntent()
        intent.select(UUID(), name: "LTDEMO")
        intent.setBackgroundEnabled(true)
        intent.start(at: start)
        let restored = try JSONDecoder().decode(LightstickRhythmIntent.self, from: JSONEncoder().encode(intent))
        XCTAssertEqual(restored.selectedID, intent.selectedID)
        XCTAssertTrue(restored.permitsRestoration(at: start.addingTimeInterval(100)))
        XCTAssertFalse(restored.permitsRestoration(at: start.addingTimeInterval(-1)))
        XCTAssertFalse(restored.permitsRestoration(at: start.addingTimeInterval(6 * 60 * 60)))
        intent.setBackgroundEnabled(false)
        XCTAssertFalse(intent.permitsRestoration(at: start))
        intent.setBackgroundEnabled(true)
        intent.stop()
        XCTAssertFalse(intent.permitsRestoration(at: start))
    }

    func testRhythmStopClearsPendingColorWithoutReusingWireSequence() {
        var queue = LatestLightQueue()
        let color = LightRGB(red: 10, green: 20, blue: 30)
        queue.offer(color)
        XCTAssertEqual(queue.take(at: 1, capacityAvailable: true)?.sequence, 1)
        queue.offer(color)
        queue.removePending()
        XCTAssertFalse(queue.hasPending)
        queue.offer(LightRGB(red: 0, green: 0, blue: 0))
        XCTAssertNil(queue.take(at: 1.1, capacityAvailable: true))
        XCTAssertEqual(queue.take(at: 1.21, capacityAvailable: true)?.sequence, 2)
    }

    @MainActor
    func testEnabledBackgroundRhythmKeepsPreviewAndStopEmitsBlack() async {
        let manager = LightstickManager(preview: true)
        manager.setBackgroundRhythmEnabled(true)
        let color = LightRGB(red: 24, green: 72, blue: 144)
        manager.submitRhythmColor(color)
        XCTAssertEqual(manager.lastRhythmColor, color)
        XCTAssertEqual(manager.lastSubmitted, "#184890")
        manager.applicationDidEnterBackground()
        XCTAssertTrue(manager.canControl)
        manager.submitRhythmColor(LightRGB(red: 1, green: 2, blue: 3))
        XCTAssertEqual(manager.lastSubmitted, "#010203")
        manager.endRhythm(sendBlack: true)
        XCTAssertEqual(manager.lastSubmitted, "#000000")
        XCTAssertEqual(manager.phase, .idle)
        XCTAssertNil(manager.lastRhythmColor)
        XCTAssertFalse(manager.hasCreatedCentralManager)
    }

    @MainActor
    func testBrightnessAdjustmentWaitsForFreshRhythmFrameWithoutManualColorFlash() async {
        let manager = LightstickManager(preview: true)
        manager.submitRhythmColor(LightRGB(red: 10, green: 20, blue: 30))
        manager.applyBrightness(0.8)
        manager.applyColor("#FF0000")
        XCTAssertEqual(manager.lastSubmitted, "#0A141E")
        XCTAssertEqual(manager.brightness, 0.8)
        manager.endRhythm(sendBlack: false)
        manager.applyColor("#00FF00")
        XCTAssertEqual(manager.lastSubmitted, "#00CC00")
    }

    @MainActor
    func testUnconnectedRhythmTargetDoesNotPublishSubmittedColor() async throws {
        let suite = "WanShouJianTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let manager = LightstickManager(preferences: defaults)
        manager.submitRhythmColor(LightRGB(red: 10, green: 20, blue: 30))
        XCTAssertNil(manager.lastRhythmColor)
        XCTAssertEqual(manager.lastSubmitted, "")
        XCTAssertFalse(manager.isSending)
        XCTAssertFalse(manager.hasCreatedCentralManager)
        manager.endRhythm(sendBlack: false)
    }

    @MainActor
    func testPreviewPublishesRhythmAndFinalBlackSubmissionThenClearsOnDisconnect() async {
        let manager = LightstickManager(preview: true)
        manager.applyColor("#FF0000")
        XCTAssertNil(manager.lastRhythmColor)
        let color = LightRGB(red: 10, green: 20, blue: 30)
        manager.submitRhythmColor(color)
        XCTAssertEqual(manager.lastRhythmColor, color)
        manager.endRhythm(sendBlack: true)
        XCTAssertEqual(manager.lastRhythmColor, LightRGB(red: 0, green: 0, blue: 0))
        manager.disconnect()
        XCTAssertNil(manager.lastRhythmColor)
        XCTAssertFalse(manager.hasCreatedCentralManager)
    }

    @MainActor
    func testBackgroundSwitchAloneKeepsManualModeForegroundOnly() async {
        let manager = LightstickManager(preview: true)
        manager.setBackgroundRhythmEnabled(true)
        manager.applicationDidEnterBackground()
        XCTAssertEqual(manager.phase, .idle)
        XCTAssertFalse(manager.canControl)
        XCTAssertNil(manager.lastRhythmColor)
        manager.applicationWillEnterForeground()
        manager.submitRhythmColor(LightRGB(red: 3, green: 2, blue: 1))
        XCTAssertTrue(manager.canControl)
        XCTAssertEqual(manager.lastSubmitted, "#030201")
        XCTAssertFalse(manager.hasCreatedCentralManager)
    }

    @MainActor
    func testBackgroundOptOutStopsRhythmAndPreviewRestorationAvoidsBluetooth() async {
        let manager = LightstickManager(preview: true)
        manager.setBackgroundRhythmEnabled(true)
        manager.submitRhythmColor(LightRGB(red: 1, green: 2, blue: 3))
        manager.applicationDidEnterBackground()
        manager.setBackgroundRhythmEnabled(false)
        XCTAssertEqual(manager.phase, .idle)
        XCTAssertEqual(manager.lastSubmitted, "#000000")
        manager.submitRhythmColor(LightRGB(red: 4, green: 5, blue: 6))
        XCTAssertNil(manager.lastRhythmColor)
        manager.restoreIfRequested(identifiers: [LightstickManager.restorationIdentifier])
        XCTAssertFalse(manager.hasCreatedCentralManager)
    }

    @MainActor
    func testEndingRhythmRemovesPersistedRestorationIntent() async throws {
        let suite = "WanShouJianTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data([1, 2, 3]), forKey: "lightstick.background-rhythm-intent.v1")
        let manager = LightstickManager(preferences: defaults)
        manager.endRhythm(sendBlack: true)
        XCTAssertNil(defaults.object(forKey: "lightstick.background-rhythm-intent.v1"))
        XCTAssertFalse(manager.hasCreatedCentralManager)
    }

    @MainActor
    func testConstructionAndPreviewControlsCreateNoBluetoothManager() async {
        let idle = LightstickManager(expectedMACHash: String(repeating: "0", count: 64))
        XCTAssertEqual(idle.phase, .idle)
        XCTAssertFalse(idle.hasCreatedCentralManager)
        let preview = LightstickManager(preview: true)
        XCTAssertEqual(preview.phase, .ready)
        XCTAssertTrue(preview.canControl)
        preview.sendCurrent()
        XCTAssertEqual(preview.lastSubmitted, "#004000")
        preview.applyColor("#FF0000")
        XCTAssertEqual(preview.lastSubmitted, "#400000")
        preview.applyBrightness(1)
        XCTAssertEqual(preview.lastSubmitted, "#FF0000")
        preview.turnOff()
        XCTAssertEqual(preview.lastSubmitted, "#000000")
        XCTAssertEqual(preview.brightness, 0)
        preview.scan()
        preview.connect(UUID())
        XCTAssertFalse(preview.hasCreatedCentralManager)
    }

    @MainActor
    func testPreviewValidationAndBackgroundPauseKeepHardwareIdle() async {
        let preview = LightstickManager(preview: true)
        preview.applyColor("#oops")
        XCTAssertEqual(preview.colorHex, "#00FF00")
        preview.applyBrightness(.nan)
        XCTAssertEqual(preview.brightness, 0.25)
        preview.pauseForBackground()
        XCTAssertEqual(preview.phase, .idle)
        XCTAssertFalse(preview.canControl)
        preview.scan()
        XCTAssertTrue(preview.canControl)
        XCTAssertFalse(preview.hasCreatedCentralManager)
    }
}
