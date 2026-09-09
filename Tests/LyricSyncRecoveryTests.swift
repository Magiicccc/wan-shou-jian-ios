import XCTest
@testable import WanShouJian

final class LyricSyncRecoveryTests:XCTestCase {
    private var record:LyricRecord {
        .init(id:-400,trackName:"回声测试",artistName:"原创",duration:180,
              syncedLyrics:"[00:05]让夜色慢慢靠近\n[01:10]把回声留在掌心\n[01:30]迎着风继续远行")
    }

    @MainActor func testMidSongPartialZeroConfidenceLocksAfterStableAgreement() {
        var now=100.0
        let lyrics=ExternalLyrics(preview:true,now:{now})
        lyrics.choose(record);lyrics.start()
        let words=[HeardWord(text:"把回声留在掌心",start:99,confidence:0,duration:2,provisional:true)]
        lyrics.accept(words:words);XCTAssertFalse(lyrics.hasPosition)
        now=100.1;lyrics.accept(words:words);XCTAssertFalse(lyrics.hasPosition)
        now=100.4;lyrics.accept(words:words)
        XCTAssertTrue(lyrics.hasPosition)
        XCTAssertEqual(lyrics.position(),71.4,accuracy:0.01)
        XCTAssertEqual(lyrics.currentCue?.text,"把回声留在掌心")
        lyrics.stop()
    }

    @MainActor func testFinalLowConfidenceIsStillRejected() {
        let lyrics=ExternalLyrics(preview:true,now:{100})
        lyrics.choose(record);lyrics.start()
        lyrics.accept(words:[.init(text:"把回声留在掌心",start:99,confidence:0.1)])
        XCTAssertFalse(lyrics.hasPosition)
        lyrics.stop()
    }

    @MainActor func testAudioAnchorBridgesPhraseGapAndThenExpiresHonestly() {
        var now=100.0
        let lyrics=ExternalLyrics(preview:true,now:{now})
        lyrics.choose(record);lyrics.start()
        lyrics.accept(words:[.init(text:"把回声留在掌心",start:99,confidence:0.9)])
        now=115;lyrics.refreshSyncState()
        XCTAssertTrue(lyrics.hasPosition);XCTAssertEqual(lyrics.position(),86)
        now=130;lyrics.refreshSyncState()
        XCTAssertFalse(lyrics.hasPosition);XCTAssertEqual(lyrics.position(),100)
        lyrics.stop()
    }

    @MainActor func testTimeoutShowsReadingReasonAndAutoRecovers() {
        var now=100.0
        let lyrics=ExternalLyrics(preview:true,now:{now})
        lyrics.choose(record);lyrics.start()
        now=116;lyrics.refreshSyncState()
        XCTAssertTrue(lyrics.syncNeedsAttention)
        XCTAssertEqual(lyrics.syncing,"暂未定位 · 自动重试中")
        XCTAssertTrue(lyrics.syncDetail.contains("尚未收到"))
        XCTAssertEqual(lyrics.cues.count,3)
        lyrics.accept(words:[.init(text:"把回声留在掌心",start:115,confidence:0.9)])
        XCTAssertTrue(lyrics.hasPosition);XCTAssertFalse(lyrics.syncNeedsAttention)
        lyrics.stop()
    }

    @MainActor func testPermissionFailureSurvivesPlayerPollingAndAllowsPlayerRecovery() {
        let lyrics=ExternalLyrics(preview:true,now:{100})
        lyrics.choose(record);lyrics.start()
        lyrics.receiveSpeechState(.unavailable("请允许语音识别权限"))
        lyrics.refreshSyncState()
        XCTAssertEqual(lyrics.syncing,"声音定位需要处理")
        XCTAssertTrue(lyrics.syncDetail.contains("权限"));XCTAssertTrue(lyrics.syncNeedsAttention)
        let snapshot=PlayerSnapshot(dictionary:["title":"回声测试","artist":"原创","duration":180,"elapsed":70,"rate":1],uptime:100)!
        lyrics.accept(snapshot);lyrics.refreshSyncState()
        XCTAssertTrue(lyrics.hasPosition);XCTAssertFalse(lyrics.syncNeedsAttention)
        XCTAssertEqual(lyrics.position(),70)
        lyrics.stop()
    }

    @MainActor func testResumeDoesNotKeepFrozenAudioClock() {
        var now=100.0
        let lyrics=ExternalLyrics(preview:true,now:{now})
        lyrics.choose(record);lyrics.start()
        lyrics.accept(words:[.init(text:"把回声留在掌心",start:99,confidence:0.9)])
        lyrics.stop();now=160;lyrics.start()
        XCTAssertFalse(lyrics.hasPosition)
        lyrics.accept(words:[.init(text:"迎着风继续远行",start:159,confidence:0.9)])
        XCTAssertEqual(lyrics.position(),91)
        lyrics.stop()
    }

    @MainActor func testManualAlignmentAndFreshPlayerKeepPriority() {
        let lyrics=ExternalLyrics(preview:true,now:{100})
        lyrics.choose(record);lyrics.start();lyrics.align(to:lyrics.cues[0])
        lyrics.accept(words:[.init(text:"把回声留在掌心",start:99,confidence:0.9)])
        XCTAssertEqual(lyrics.position(),5)
        lyrics.followPlayer()
        lyrics.accept(PlayerSnapshot(dictionary:["title":"回声测试","artist":"原创","duration":180,"elapsed":40,"rate":1],uptime:100)!)
        lyrics.accept(words:[.init(text:"把回声留在掌心",start:99,confidence:0.9)])
        XCTAssertEqual(lyrics.position(),40)
        lyrics.stop()
    }

    func testPrefixInsideLargerRecognitionSegmentAndPunctuation() throws {
        let cues=try PerformanceScore.parseLRC("[00:40]把回声，留在掌心",duration:90)
        let match=LyricAlignment.match(words:[.init(text:"嗯把回声留在掌心",start:99,confidence:0.9,duration:4)],cues:cues,near:nil,now:104)
        XCTAssertEqual(match?.cue.id,cues[0].id)
        XCTAssertEqual(match!.observed,99.5,accuracy:0.01)
    }

    func testShortLinesUseNeighbourToResolveRepeatedRefrain() throws {
        let cues=try PerformanceScore.parseLRC("[00:10]别走\n[00:13]把回声留在掌心\n[01:00]别走\n[01:03]迎着风继续远行",duration:100)
        let words=[HeardWord(text:"别走迎着风继续远行",start:99,confidence:0.9)]
        XCTAssertEqual(LyricAlignment.match(words:words,cues:cues,near:nil,now:102)?.cue.start,60)
    }

    func testRepeatedLyricsRequireEstablishedClock() throws {
        let cues=try PerformanceScore.parseLRC("[00:10]把回声留在掌心\n[01:10]把回声留在掌心",duration:100)
        let words=[HeardWord(text:"把回声留在掌心",start:99,confidence:0.9)]
        XCTAssertNil(LyricAlignment.match(words:words,cues:cues,near:nil,now:102))
        XCTAssertEqual(LyricAlignment.match(words:words,cues:cues,near:73,now:102)?.cue.start,70)
    }

    func testUntrustedMiddleWordsCannotBeBorrowedByConfidentPrefix() throws {
        let cues=try PerformanceScore.parseLRC("[00:10]把回声留在掌心",duration:100)
        let words=[HeardWord(text:"把回声",start:99,confidence:0.9),HeardWord(text:"留在掌心",start:100,confidence:0.1)]
        XCTAssertNil(LyricAlignment.match(words:words,cues:cues,near:nil,now:102))
    }

    @MainActor func testChangingHypothesisCannotAcquirePosition() {
        var now=100.0
        let lyrics=ExternalLyrics(preview:true,now:{now})
        lyrics.choose(record);lyrics.start()
        lyrics.accept(words:[.init(text:"把回声留在掌心",start:99,confidence:0,provisional:true)])
        now=100.5
        lyrics.accept(words:[.init(text:"迎着风继续远行",start:99,confidence:0,provisional:true)])
        XCTAssertFalse(lyrics.hasPosition)
        lyrics.stop()
    }
}
