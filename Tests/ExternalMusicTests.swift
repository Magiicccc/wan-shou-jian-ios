import AVFoundation
import XCTest
@testable import WanShouJian

final class ExternalMusicTests: XCTestCase {
    func testClockTracksBackgroundTimeAndExplicitPauses() {
        var clock=PerformanceClock()
        clock.resume(at:10); clock.resume(at:12)
        XCTAssertEqual(clock.elapsed(at:70),60)
        clock.pause(at:70)
        XCTAssertEqual(clock.elapsed(at:100),60)
        clock.resume(at:110)
        XCTAssertEqual(clock.elapsed(at:120),70)
        XCTAssertEqual(clock.elapsed(at:.nan),60)
    }

    @MainActor func testRoutingAllowsMusicMixingAndA2DPRatherThanHFPInput() {
        let options=HomeAudioRouting.captureOptions
        XCTAssertTrue(options.contains(.mixWithOthers))
        XCTAssertTrue(options.contains(.allowBluetoothA2DP))
        XCTAssertFalse(options.contains(.allowBluetooth))
        XCTAssertFalse(options.contains(.duckOthers))
    }

    private func tone(pitch:Double = 220, rms:Double = 0.2) -> [VocalFrame] {
        (0..<100).map { .init(time:Double($0)*0.1,rms:rms,pitch:pitch,confidence:0.95) }
    }

    func testPracticeScoresRequireSufficientEvidence() {
        XCTAssertNil(PracticeAssessment.evaluate([]).steadiness)
        XCTAssertNil(PracticeAssessment.evaluate(Array(tone().prefix(8))).levelHeadroom)
        let silence=tone(pitch:0,rms:0)
        XCTAssertNil(PracticeAssessment.evaluate(silence).steadiness)
    }

    func testSteadyToneScoresStabilityWithoutInventingAccuracy() {
        let result=PracticeAssessment.evaluate(tone())
        XCTAssertEqual(result.steadiness,100)
        XCTAssertEqual(result.levelHeadroom,100)
        XCTAssertFalse(result.referenceMelodyAvailable)
        XCTAssertGreaterThan(result.steadyWindows,3)
        XCTAssertTrue(result.text.contains("练习参考分"))
    }

    func testLoudInputAndVaryingNotesStayWithinScoringScope() {
        XCTAssertEqual(PracticeAssessment.evaluate(tone(rms:0.9)).levelHeadroom,0)
        let glides=tone().enumerated().map { index,frame in
            VocalFrame(time:frame.time,rms:frame.rms,pitch:220*pow(2,Double(index%5)*0.2),confidence:0.95)
        }
        XCTAssertNil(PracticeAssessment.evaluate(glides).steadiness)
    }

    func testInvalidEvidenceDoesNotProduceScores() {
        let invalid=[VocalFrame(time:.nan,rms:0.2,pitch:220,confidence:1),
                     VocalFrame(time:1,rms:.infinity,pitch:220,confidence:1)]
        XCTAssertEqual(PracticeAssessment.evaluate(invalid).validSamples,0)
    }

    @MainActor private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds:2_000_000)
        }
        XCTAssertTrue(predicate())
    }

    @MainActor func testExternalStageNeedsNoImportedPlayerAndBlocksSeeking() async {
        let manager=LightstickManager(preview:true)
        let session=KaraokeSession(manager:manager,preview:true,recoveryDelay:1)
        session.useExternalMusic(title:"自由练唱")
        XCTAssertTrue(session.externalMusic)
        XCTAssertTrue(session.cues.isEmpty)
        session.seek(100)
        XCTAssertEqual(session.position,0)
        session.start()
        await waitUntil { session.playing }
        XCTAssertFalse(session.hasMicrophone)
        XCTAssertFalse(manager.hasCreatedCentralManager)
        session.finish()
        XCTAssertFalse(session.isSessionActive)
        XCTAssertTrue(session.report.contains("练习参考分"))
    }

    @MainActor func testSpeakerRouteRecoveryPreservesBLEIntentAndElapsedTake() async {
        let manager=LightstickManager(preview:true)
        manager.setBackgroundRhythmEnabled(true)
        manager.submitRhythmColor(.init(red:1,green:2,blue:3))
        let session=KaraokeSession(manager:manager,preview:true,recoveryDelay:1)
        session.useExternalMusic(); session.start()
        await waitUntil { session.playing }
        manager.applicationDidEnterBackground()
        session.handleAudioEvent(.routeChanged)
        XCTAssertTrue(session.recovering)
        XCTAssertTrue(manager.canControl)
        XCTAssertEqual(manager.lastSubmitted,"#010203")
        await waitUntil { session.playing }
        XCTAssertTrue(session.externalMusic)
        session.pause()
    }

    @MainActor func testStopCancelsRouteRecoveryAndLateInterruptionResume() async {
        let session=KaraokeSession(manager:LightstickManager(preview:true),preview:true,recoveryDelay:1_000_000)
        session.useExternalMusic(); session.start()
        await waitUntil { session.playing }
        session.handleAudioEvent(.configurationChanged)
        session.pause()
        session.handleAudioEvent(.interruptionEnded(shouldResume:true))
        try? await Task.sleep(nanoseconds:20_000_000)
        XCTAssertFalse(session.isSessionActive)
        XCTAssertFalse(session.playing)
    }

    @MainActor func testInterruptionWithoutResumeAndMediaResetRequireUserStart() async {
        let session=KaraokeSession(manager:LightstickManager(preview:true),preview:true,recoveryDelay:1)
        session.useExternalMusic();session.start()
        await waitUntil { session.playing }
        session.handleAudioEvent(.interruptionBegan)
        session.handleAudioEvent(.routeChanged)
        XCTAssertFalse(session.recovering)
        session.handleAudioEvent(.interruptionEnded(shouldResume:false))
        XCTAssertFalse(session.isSessionActive)
        session.start();await waitUntil { session.playing }
        session.handleAudioEvent(.mediaServicesReset)
        session.handleAudioEvent(.configurationChanged)
        XCTAssertFalse(session.isSessionActive)
    }

    @MainActor func testReturningToDemoRestoresLocalSourceAndLyrics() {
        let session=KaraokeSession(manager:LightstickManager(preview:true),preview:true)
        session.useExternalMusic();session.useDemo()
        XCTAssertFalse(session.externalMusic)
        XCTAssertEqual(session.cues,PerformanceScore.demo)
        session.pause()
    }
}
