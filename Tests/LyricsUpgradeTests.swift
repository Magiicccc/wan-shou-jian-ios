import XCTest
@testable import WanShouJian

final class LyricsUpgradeTests:XCTestCase {
    func testNetEaseSearchFetchesSameIDWithoutAuthentication() async throws {
        let configuration=URLSessionConfiguration.ephemeral
        configuration.protocolClasses=[LyricFixtureProtocol.self]
        let session=URLSession(configuration:configuration)
        defer { session.invalidateAndCancel() }
        let records=try await NetEaseLyrics(session:session).search(title:"Night",artist:"Original")
        XCTAssertEqual(records.count,1)
        XCTAssertEqual(records[0].id,-999)
        XCTAssertTrue(records[0].hasTiming)
        XCTAssertTrue(records[0].syncedLyrics?.contains("Original line") ?? false)
    }
    func testWordTimingPreservesRealTimesAndRejectsCorruption() throws {
        let cues=try PerformanceScore.parseYRC("[1000,2000](1000,500,0)夜(1500,1500,0)航",duration:5)
        XCTAssertEqual(cues[0].text,"夜航")
        XCTAssertEqual(cues[0].words?[1].start,1.5)
        XCTAssertEqual(cues[0].words?[1].offset,1)
        XCTAssertThrowsError(try PerformanceScore.parseYRC("[1000,2000](900,500,0)夜",duration:5))
        XCTAssertThrowsError(try PerformanceScore.parseYRC("[1000,2000](1000,5000,0)夜",duration:5))
    }
    func testNetEaseMetadataUsesMillisecondsAndSourceSafeIdentity() throws {
        let data=Data(#"{"id":3324801986,"name":"Example (Live)","duration":276301,"artists":[{"name":"Test"}],"album":{"name":"Session"}}"#.utf8)
        let record=try JSONDecoder().decode(NetEaseSong.self,from:data).record
        XCTAssertEqual(record.id,-3324801986)
        XCTAssertEqual(record.duration,276.301,accuracy:0.001)
        XCTAssertEqual(record.sourceName,"网易云")
        XCTAssertEqual(ExternalTrack.normalize("Example（Live）"),ExternalTrack.normalize("example (live)"))
        XCTAssertNotEqual(ExternalTrack.normalize("Example"),ExternalTrack.normalize("Example Live"))
    }
    func testDefaultKeepsFullPhraseAndAllowsEmptyFocus() throws {
        let cues=try PerformanceScore.parseLRC("[00:01]让夜色慢慢靠近",duration:10)
        XCTAssertEqual(cues[0].emphasis,"")
        let plan=PerformanceScore.Plan(directions:[.init(id:0,emphasis:"",scene:.narrative,mood:.reflective,
            groups:["让夜色","慢慢靠近"],palette:.silver,intensity:0.2,focusStart:0)])
        XCTAssertEqual(try PerformanceScore.apply(plan,to:cues)[0].groups?.joined(),cues[0].text)
    }
    func testSemanticRangesRejectAlteredTextAndOutOfBounds() throws {
        let cues=PerformanceScore.demo
        var directions=cues.map { PerformanceScore.Direction(id:$0.id,emphasis:"",scene:.narrative,mood:.reflective) }
        directions[0].groups=["changed"]
        XCTAssertThrowsError(try PerformanceScore.apply(.init(directions:directions),to:cues))
        directions[0].groups=nil;directions[0].focusStart = -1
        XCTAssertThrowsError(try PerformanceScore.apply(.init(directions:directions),to:cues))
        directions[0].focusStart=0;directions[0].intensity = .nan
        XCTAssertThrowsError(try PerformanceScore.apply(.init(directions:directions),to:cues))
    }
    func testAudioAlignmentRequiresRecentConfidentUniquePrefix() {
        let cue=PerformanceScore.demo[0]
        let words=[HeardWord(text:cue.text,start:100,confidence:0.9)]
        XCTAssertEqual(LyricAlignment.match(words:words,cues:[cue],near:nil,now:103)?.cue.id,cue.id)
        XCTAssertNil(LyricAlignment.match(words:words,cues:[cue],near:nil,now:120))
        XCTAssertNil(LyricAlignment.match(words:[.init(text:cue.text,start:100,confidence:0.1)],cues:[cue],near:nil,now:103))
        var repeated=cue;repeated.id=99;repeated.start=100
        XCTAssertNil(LyricAlignment.match(words:words,cues:[cue,repeated],near:nil,now:103))
        XCTAssertEqual(LyricAlignment.match(words:words,cues:[cue,repeated],near:101,now:103)?.cue.id,99)
    }
    func testDirectionCacheIdentityIgnoresVisualChangesButIncludesTiming() {
        var cues=PerformanceScore.demo
        let original=DirectorCache.key(cues:cues,settings:.init())
        cues[0].palette = .wine
        XCTAssertEqual(original,DirectorCache.key(cues:cues,settings:.init()))
        cues[0].start += 1
        XCTAssertNotEqual(original,DirectorCache.key(cues:cues,settings:.init()))
    }
}

private final class LyricFixtureProtocol:URLProtocol {
    override class func canInit(with request:URLRequest)->Bool { true }
    override class func canonicalRequest(for request:URLRequest)->URLRequest { request }
    override func startLoading() {
        let body:String
        if request.url!.path=="/api/search/get" {
            body=#"{"code":200,"result":{"songs":[{"id":999,"name":"Night","duration":10000,"artists":[{"name":"Original"}],"album":{"name":"Study"}}]}}"#
        } else {
            guard URLComponents(url:request.url!,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{$0.name=="id"})?.value=="999" else {
                client?.urlProtocol(self,didFailWithError:URLError(.badURL));return
            }
            body=#"{"code":200,"lrc":{"lyric":"[00:01.00]Original line"}}"#
        }
        client?.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client?.urlProtocol(self,didLoad:Data(body.utf8));client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
