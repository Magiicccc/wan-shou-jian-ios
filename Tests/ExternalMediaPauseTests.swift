import XCTest
@testable import WanShouJian

final class ExternalMediaPauseTests: XCTestCase {
    @MainActor func testPreviewSkipsNativeTransportAndUsesExplicitPauseCommand() {
        XCTAssertEqual(ExternalMediaPause.send(preview:true), .preview)
        XCTAssertEqual(ExternalMediaPause.pauseCommand, 1)
        #if targetEnvironment(simulator)
        XCTAssertEqual(ExternalMediaPause.send(preview:false), .unavailable)
        #endif
    }

    func testSubmissionCopyRequiresPhysicalConfirmation() {
        XCTAssertTrue(MediaPauseResult.submitted.message.contains("请确认"))
        XCTAssertTrue(MediaPauseResult.rejected.message.contains("失败"))
        XCTAssertTrue(MediaPauseResult.unavailable.message.contains("控制中心"))
    }

    @MainActor func testExternalUserPauseStopsStageRegardlessOfTransportResult() async {
        for result in [MediaPauseResult.submitted, .rejected, .unavailable] {
            var requests=0
            let manager=LightstickManager(preview:true)
            let session=KaraokeSession(manager:manager,preview:true,sendMediaPause: { preview in
                XCTAssertTrue(preview); requests += 1; return result
            })
            session.useExternalMusic(); session.start()
            await waitUntil { session.playing }
            session.pauseFromUser()
            XCTAssertEqual(requests,1)
            XCTAssertFalse(session.isSessionActive)
            XCTAssertEqual(session.mediaPauseResult,result)
            XCTAssertTrue(session.status.contains(result.message))
            XCTAssertFalse(manager.hasCreatedCentralManager)
        }
    }

    @MainActor func testInternalPauseRecoveryAndFinishNeverSendRemoteCommand() async {
        var requests=0
        let session=KaraokeSession(manager:LightstickManager(preview:true),preview:true,recoveryDelay:1,
            sendMediaPause: { _ in requests += 1; return .submitted })
        session.useExternalMusic();session.start()
        await waitUntil { session.playing }
        session.handleAudioEvent(.routeChanged)
        await waitUntil { session.playing }
        session.handleAudioEvent(.interruptionBegan)
        session.handleAudioEvent(.interruptionEnded(shouldResume:false))
        session.pause();session.finish();session.useDemo()
        XCTAssertEqual(requests,0)
    }

    @MainActor func testLocalSourcePauseRemainsLocal() {
        var requests=0
        let session=KaraokeSession(manager:LightstickManager(preview:true),preview:true,
            sendMediaPause: { _ in requests += 1; return .submitted })
        session.pauseFromUser()
        XCTAssertEqual(requests,0)
        XCTAssertEqual(session.mediaPauseResult,.idle)
    }

    @MainActor func testRhythmSeparatesExplicitStopAndSyntheticMode() {
        var flags:[Bool]=[]
        let session=RhythmSession(manager:LightstickManager(preview:true),preview:false,
            sendMediaPause: { flags.append($0); return $0 ? .preview : .submitted })
        session.stop()
        XCTAssertTrue(flags.isEmpty)
        session.stopFromUser()
        XCTAssertEqual(flags,[false])
        session.startPreview();session.stopFromUser()
        XCTAssertEqual(flags,[false,true])
        XCTAssertFalse(session.isRunning)
        XCTAssertEqual(session.mediaPauseResult,.preview)
    }

    @MainActor private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(nanoseconds:2_000_000)
        }
        XCTAssertTrue(predicate())
    }
}
