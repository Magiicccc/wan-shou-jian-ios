import XCTest
@testable import WanShouJian

final class PracticeCoachingTests:XCTestCase {
    private func tone(varyVolume:Bool=false)->[VocalFrame] {
        (0..<120).map { i in
            .init(time:Double(i)*0.1,rms:varyVolume ? 0.2*(0.6+Double(i%5)*0.2) : 0.2,pitch:220,confidence:0.95)
        }
    }
    private func data(id:String="keep-steady",action:String="把这一句轻声唱三遍。",extra:Bool=false)->Data {
        var value:[String:Any]=["summary":"先保持舒服的声音，再唱一遍。","tips":[["id":id,"title":"把平稳带回歌里","action":action,"goal":"听听长音是否一直比较平稳。"]]]
        if extra { value["score"]=99 }
        return try! JSONSerialization.data(withJSONObject:value)
    }
    func testScoreIsBoundedAndUsesObservableSubscores() {
        let result=PracticeAssessment.evaluate(tone(varyVolume:true))
        XCTAssertEqual(result.steadiness,100)
        XCTAssertLessThan(result.volumeEvenness!,100)
        XCTAssertEqual(result.practiceScore,Int((Double(result.steadiness!)*0.7+Double(result.volumeEvenness!)*0.3).rounded()))
        XCTAssertTrue((0...100).contains(result.practiceScore!))
    }
    func testSteadyPracticeHasClearScoreAndLocalAdvice() {
        let result=PracticeAssessment.evaluate(tone())
        XCTAssertEqual(result.practiceScore,100)
        XCTAssertEqual(result.tips.first?.id,"keep-steady")
        XCTAssertTrue(result.text.contains("怎么练"))
        XCTAssertTrue(result.text.contains("练习参考分：100"))
    }
    func testInsufficientInputHasAdviceWithoutAZeroGrade() {
        let result=PracticeAssessment.evaluate([])
        XCTAssertNil(result.practiceScore)
        XCTAssertEqual(result.tips.first?.id,"more-voice")
        XCTAssertTrue(result.text.contains("待评分"))
        XCTAssertFalse(result.text.contains("0 / 100"))
    }
    func testRecordingQualityDoesNotBoostOrPenalizeSingingScore() {
        let frames=tone().map { VocalFrame(time:$0.time,rms:0.9,pitch:$0.pitch,confidence:$0.confidence) }
        let result=PracticeAssessment.evaluate(frames)
        XCTAssertNil(result.practiceScore)
        XCTAssertEqual(result.tips.first?.id,"recording")
        XCTAssertTrue(result.recordingQuality.contains("太响"))
    }
    func testDuplicateFramesCannotCreateEvidence() {
        let frames=Array(repeating:VocalFrame(time:1,rms:0.2,pitch:220,confidence:0.95),count:100)
        let result=PracticeAssessment.evaluate(frames)
        XCTAssertEqual(result.validSamples,1)
        XCTAssertNil(result.practiceScore)
    }
    func testAdviceTimesComeFromRecordedPassages() {
        let result=PracticeAssessment.evaluate(tone(varyVolume:true))
        let tip=result.tips.first(where:{$0.id=="even-volume"})!
        XCTAssertNotNil(tip.at)
        XCTAssertTrue(result.passages!.contains(where:{$0.start==tip.at}))
        XCTAssertTrue(tip.timeLabel.contains("这次练习"))
    }
    func testLocalAdviceUsesEverydayWords() {
        for frames in [tone(),tone(varyVolume:true),[]] {
            let text=PracticeAssessment.evaluate(frames).text
            for term in ["Hz","dB","电平","基频","置信度","音分"] { XCTAssertFalse(text.contains(term)) }
        }
    }
    func testAIRewritesActionsWhilePreservingObservationsAndTimes() throws {
        let result=PracticeAssessment.evaluate(tone())
        let before=result.tips
        let review=try PracticeReview.decode(data(),for:result)
        let after=review.applying(to:before)
        XCTAssertEqual(after[0].at,before[0].at)
        XCTAssertEqual(after[0].observation,before[0].observation)
        XCTAssertEqual(after[0].id,before[0].id)
        XCTAssertEqual(after[0].action,"把这一句轻声唱三遍。")
        XCTAssertEqual(result.practiceScore,100)
    }
    func testAIExtraScoreOrUnknownEvidenceIsRejected() {
        let result=PracticeAssessment.evaluate(tone())
        XCTAssertThrowsError(try PracticeReview.decode(data(extra:true),for:result))
        XCTAssertThrowsError(try PracticeReview.decode(data(id:"invented"),for:result))
    }
    func testJargonAndUnsupportedJudgmentsAreRejected() {
        let result=PracticeAssessment.evaluate(tone())
        for action in ["控制基频的稳定。","把电平降低。","你这一句跑调了。","建议练到95分。"] {
            XCTAssertThrowsError(try PracticeReview.decode(data(action:action),for:result))
        }
    }
    func testOlderAssessmentDecodesWithNewOptionalFields() throws {
        let json=Data(#"{"validSamples":100,"measuredSeconds":10,"steadyWindows":10,"steadiness":100,"levelHeadroom":100,"referenceMelodyAvailable":false}"#.utf8)
        let result=try JSONDecoder().decode(PracticeAssessment.self,from:json)
        XCTAssertNil(result.practiceScore)
        XCTAssertEqual(result.steadiness,100)
    }
}
