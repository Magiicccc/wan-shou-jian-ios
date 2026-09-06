import XCTest
@testable import WanShouJian

final class PerformanceScoreTests:XCTestCase {
    func testLRCTimestampsRepeatedTagsAndOffset() throws {
        let score=try PerformanceScore.parseLRC("[offset:100]\n[00:01.50][00:08.5]Hello light\n[00:04]Moon",duration:12)
        XCTAssertEqual(score.count,3)
        XCTAssertEqual(score[0].start,1.6,accuracy:0.001)
        XCTAssertEqual(score[0].end,4.1,accuracy:0.001)
        XCTAssertEqual(score[2].start,8.6,accuracy:0.001)
        XCTAssertEqual(score[2].end,12)
        XCTAssertNil(PerformanceScore.cue(at:0,in:score))
        XCTAssertEqual(PerformanceScore.cue(at:4.1,in:score)?.text,"Moon")
        XCTAssertNil(PerformanceScore.cue(at:12,in:score))
    }
    func testLRCRejectsMissingAndInvalidTime() {
        XCTAssertThrowsError(try PerformanceScore.parseLRC("hello",duration:20))
        XCTAssertThrowsError(try PerformanceScore.parseLRC("[00:99]hello",duration:200))
        XCTAssertThrowsError(try PerformanceScore.parseLRC("[00:01]hello",duration:.nan))
    }
    func testDirectionPreservesTextAndTime() throws {
        let cues=PerformanceScore.demo
        let plan=PerformanceScore.Plan(directions:cues.map { .init(id:$0.id,emphasis:$0.emphasis,scene:.echo,mood:.sorrow) })
        let result=try PerformanceScore.apply(plan,to:cues)
        XCTAssertEqual(result.map(\.text),cues.map(\.text))
        XCTAssertEqual(result.map(\.start),cues.map(\.start))
        XCTAssertTrue(result.allSatisfy { $0.mood == .sorrow })
    }
    func testDirectionRejectsHallucinatedWordAndDuplicateIDs() {
        var directions=PerformanceScore.demo.map { PerformanceScore.Direction(id:$0.id,emphasis:$0.emphasis,scene:.echo,mood:.sorrow) }
        directions[0].emphasis="invented"
        XCTAssertThrowsError(try PerformanceScore.apply(.init(directions:directions),to:PerformanceScore.demo))
        directions[0]=directions[1]
        XCTAssertThrowsError(try PerformanceScore.apply(.init(directions:directions),to:PerformanceScore.demo))
    }
    func testSorrowPaletteRetainsColdHue() {
        let color=SongMood.sorrow.rgb
        XCTAssertGreaterThan(color.blue,color.red*2)
        XCTAssertLessThan(color.green,50)
        XCTAssertEqual(PerformanceScore.demo[2].mood,.sorrow)
    }
    func testPitchDetectorTracksKnownTone() {
        let samples=(0..<4096).map { Float(sin(Double($0)*2 * .pi * 220/48000)*0.25) }
        let frame=VocalMetrics.measure(samples,rate:48000,time:3)
        XCTAssertEqual(frame.pitch,220,accuracy:5)
        XCTAssertGreaterThan(frame.confidence,0.95)
        XCTAssertEqual(frame.time,3)
    }
    func testSilentAndNonFiniteSamplesProduceNoPitch() {
        let zeros=[Float](repeating:0,count:4096)
        XCTAssertEqual(VocalMetrics.measure(zeros,rate:48000,time:0).pitch,0)
        XCTAssertEqual(VocalMetrics.measure([Float](repeating:.nan,count:4096),rate:48000,time:0).rms,0)
    }
    func testDemoHasContiguousReadableCues() {
        let cues=PerformanceScore.demo
        for i in 0..<cues.count {
            XCTAssertTrue(cues[i].text.contains(cues[i].emphasis))
            if i>0 { XCTAssertEqual(cues[i-1].end,cues[i].start) }
        }
        XCTAssertEqual(cues.last?.end,48)
    }
}
