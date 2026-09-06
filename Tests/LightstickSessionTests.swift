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
