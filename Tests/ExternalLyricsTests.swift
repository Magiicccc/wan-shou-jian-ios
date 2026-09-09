import XCTest
@testable import WanShouJian

final class ExternalLyricsTests:XCTestCase {
    private func record(_ id:Int=1,duration:Double=48,text:String="[00:00.00]让夜色慢慢靠近\n[00:06.00]把回声留在掌心") -> LyricRecord {
        .init(id:id,trackName:"夜航",artistName:"原创",albumName:"练习",duration:duration,syncedLyrics:text)
    }
    private func snapshot(title:String="夜航",elapsed:Double=10,rate:Double=1,now:Double=100) -> PlayerSnapshot {
        PlayerSnapshot(dictionary:["title":title,"artist":"原创","album":"练习","duration":48,"elapsed":elapsed,"rate":rate],uptime:now)!
    }
    func testClockHandlesPauseSeekOffsetAndStaleSystemData() {
        var clock=LyricClock(anchor:10,observed:100,rate:1,duration:48,system:true)
        XCTAssertEqual(clock.position(at:105),15)
        XCTAssertEqual(clock.position(at:120),18)
        clock.offset = -2
        XCTAssertEqual(clock.position(at:105),13)
        clock.freeze(at:105)
        XCTAssertEqual(clock.position(at:1000),13)
        clock = .init(anchor:40,observed:100,rate:0,duration:48,system:true)
        XCTAssertEqual(clock.position(at:105),40)
        clock = .init(anchor:3,observed:100,rate:1,duration:48)
        XCTAssertEqual(clock.position(at:1000),48)
    }
    func testMetadataValidationAndTimestampExtrapolation() {
        XCTAssertNil(PlayerSnapshot(dictionary:[:]))
        XCTAssertNil(PlayerSnapshot(dictionary:["title":"夜航","duration":Double.nan]))
        let now=Date()
        let item=PlayerSnapshot(dictionary:["title":"夜航","duration":48,"elapsed":10,"rate":1,"timestamp":now.addingTimeInterval(-3)],now:now)
        XCTAssertEqual(item?.elapsed,13)
        let unknown=PlayerSnapshot(dictionary:["title":"夜航","duration":48,"elapsed":10])
        XCTAssertNil(unknown?.rate)
        XCTAssertNil(PlayerSnapshot(dictionary:["title":"夜航","duration":48,"elapsed":Double.nan])?.elapsed)
    }
    func testMatchingRequiresArtistDurationAndUnambiguousTimeline() {
        let track=ExternalTrack(title:"夜航",artist:"原创",album:"练习",duration:48)
        XCTAssertEqual(LyricRecord.automatic(in:[record()],for:track)?.id,1)
        XCTAssertNil(LyricRecord.automatic(in:[record(duration:140)],for:track))
        XCTAssertNil(LyricRecord.automatic(in:[record()],for:.init(title:"夜航",artist:"",duration:48)))
        XCTAssertNil(LyricRecord.automatic(in:[record(),record(2,text:"[00:08.00]另一段原创歌词")],for:track))
        XCTAssertEqual(LyricRecord.automatic(in:[record(),record(2)],for:track)?.id,1)
    }
    @MainActor func testManualSelectionWaitsForAlignmentThenStopsIndependently() {
        let lyrics=ExternalLyrics(preview:true)
        lyrics.choose(record())
        XCTAssertFalse(lyrics.hasPosition)
        lyrics.start();lyrics.align(to:lyrics.cues[1])
        XCTAssertEqual(lyrics.position(),6,accuracy:0.1)
        XCTAssertEqual(lyrics.syncing,"手动对齐")
        lyrics.stop()
        XCTAssertEqual(lyrics.clock.rate,0)
        XCTAssertEqual(lyrics.cues.count,2)
    }
    @MainActor func testPreviewNeverReadsRealPlayer() async {
        var calls=0
        let lyrics=ExternalLyrics(preview:true,read:{ calls += 1;return nil })
        lyrics.start();try? await Task.sleep(nanoseconds:5_000_000)
        XCTAssertEqual(calls,0)
        lyrics.loadPreview()
        XCTAssertEqual(lyrics.cues.count,8)
        lyrics.reset();XCTAssertTrue(lyrics.cues.isEmpty)
    }
    @MainActor func testOldSearchCannotOverwriteNewResults() async {
        let old=record(),new=record(2)
        let lyrics=ExternalLyrics(preview:true,search:{ title,_ in
            if title=="old" { try? await Task.sleep(nanoseconds:40_000_000);return [old] }
            return [new]
        })
        lyrics.find(title:"old")
        try? await Task.sleep(nanoseconds:3_000_000)
        lyrics.find(title:"new")
        try? await Task.sleep(nanoseconds:60_000_000)
        XCTAssertEqual(lyrics.results.map(\.id),[2])
        XCTAssertFalse(lyrics.busy)
    }
    @MainActor func testSourceResetInvalidatesSearchAndClearsLyrics() async {
        let found=record()
        let lyrics=ExternalLyrics(preview:true,search:{ _,_ in
            try? await Task.sleep(nanoseconds:20_000_000);return [found]
        })
        lyrics.find(title:"夜航");lyrics.reset()
        try? await Task.sleep(nanoseconds:40_000_000)
        XCTAssertTrue(lyrics.results.isEmpty);XCTAssertTrue(lyrics.cues.isEmpty);XCTAssertNil(lyrics.track)
    }
    @MainActor func testPlayerChangeClearsPreviousCueAndPauseFreezesSongOnly() async {
        let found=record()
        let lyrics=ExternalLyrics(preview:true,search:{ _,_ in [found] })
        lyrics.accept(snapshot())
        try? await Task.sleep(nanoseconds:5_000_000)
        XCTAssertEqual(lyrics.cues.count,2)
        lyrics.accept(snapshot(elapsed:25,rate:0))
        XCTAssertEqual(lyrics.clock.rate,0);XCTAssertEqual(lyrics.position(),25)
        lyrics.accept(snapshot(title:"另一首"))
        XCTAssertTrue(lyrics.cues.isEmpty)
        XCTAssertEqual(lyrics.track?.title,"另一首")
        lyrics.reset()
    }
    @MainActor func testPlainLyricsAreReadableWithNoInventedTiming() {
        let lyrics=ExternalLyrics(preview:true)
        var item=record();item.syncedLyrics=nil;item.plainLyrics="原创测试文本"
        lyrics.choose(item)
        XCTAssertTrue(lyrics.cues.isEmpty);XCTAssertEqual(lyrics.plainText,"原创测试文本")
        XCTAssertFalse(lyrics.hasPosition)
    }
    @MainActor func testLyricsCacheRoundTrip() async throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:directory) }
        let file=directory.appendingPathComponent("lyrics.json")
        let lyrics=ExternalLyrics(cacheURL:file)
        lyrics.choose(record())
        var requests=0
        let restored=ExternalLyrics(search:{ _,_ in requests += 1;return [] },cacheURL:file)
        restored.accept(snapshot())
        XCTAssertEqual(restored.cues.count,2);XCTAssertEqual(requests,0)
    }
    @MainActor func testImportExternalLyricsAndInvalidAlignment() throws {
        let lyrics=ExternalLyrics(preview:true)
        try lyrics.importLRC("[00:05.00]原创一句",title:"本机")
        XCTAssertFalse(lyrics.hasPosition)
        lyrics.align(to:PerformanceScore.demo[0])
        XCTAssertFalse(lyrics.hasPosition)
        lyrics.align(to:lyrics.cues[0]);XCTAssertTrue(lyrics.hasPosition)
    }
}
