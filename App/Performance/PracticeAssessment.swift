import Foundation

struct PerformanceClock {
    private var accumulated = 0.0
    private var startedAt: Double?
    mutating func resume(at now: Double) {
        guard now.isFinite, startedAt == nil else { return }
        startedAt=now
    }
    mutating func pause(at now: Double) {
        accumulated=elapsed(at:now); startedAt=nil
    }
    func elapsed(at now: Double) -> Double {
        guard let startedAt, now.isFinite else { return accumulated }
        return accumulated + max(0,now-startedAt)
    }
}

struct PracticePassage:Codable,Equatable {
    var start:Double
    var steadiness:Int
    var volumeEvenness:Int
}

struct PracticeTip:Codable,Equatable,Identifiable {
    var id:String
    var at:Double?
    var title:String
    var observation:String
    var action:String
    var goal:String
    var timeLabel:String {
        guard let at else { return "下一遍可以这样练" }
        return String(format:"这次练习 %02d:%02d 附近",Int(at)/60,Int(at)%60)
    }
}

/// Mixed-input sustained-note practice measures, without a reference melody.
struct PracticeAssessment: Codable, Equatable {
    var validSamples: Int
    var measuredSeconds: Double
    var steadyWindows: Int
    var steadiness: Int?
    var levelHeadroom: Int?
    var referenceMelodyAvailable = false
    var volumeEvenness:Int?
    var passages:[PracticePassage]?
    var loudestTime:Double?

    var practiceScore:Int? {
        guard let steadiness,let volumeEvenness,let levelHeadroom,levelHeadroom>=90 else { return nil }
        return Int((Double(steadiness)*0.7+Double(volumeEvenness)*0.3).rounded())
    }
    var recordingQuality:String {
        guard let levelHeadroom else { return "再唱一小段，收集足够的声音" }
        return levelHeadroom<90 ? "声音太响，先降低伴奏或离手机稍远一点" : "收音音量合适"
    }
    var headline:String {
        guard let score=practiceScore else { return "先把这段声音录清楚" }
        return score>=85 ? "长音保持得比较平稳" : score>=65 ? "有些长音还可以更稳" : "先练稳一个舒服的长音"
    }

    static func evaluate(_ input: [VocalFrame]) -> Self {
        let sorted=input.filter { $0.time.isFinite && (0...1200).contains($0.time) && $0.rms.isFinite && $0.rms>=0 && $0.pitch.isFinite && $0.confidence.isFinite && (0...1).contains($0.confidence) }
            .sorted { $0.time < $1.time }
        var frames:[VocalFrame]=[]
        for frame in sorted where frame.time>(frames.last?.time ?? -1) { frames.append(frame) }
        let voiced=frames.filter { (65...900).contains($0.pitch) && $0.confidence>=0.8 && $0.rms>0.008 }
        let seconds=max(0,(frames.last?.time ?? 0)-(frames.first?.time ?? 0))
        var result=Self(validSamples:voiced.count,measuredSeconds:seconds,steadyWindows:0)
        result.loudestTime=frames.first(where:{$0.rms>0.65})?.time
        guard voiced.count>=30,seconds>=5 else { return result }
        let groups=Dictionary(grouping:voiced) { Int(min(1200,$0.time)*2) }
        var deviations:[Double]=[]
        var volumeDeviations:[Double]=[]
        var passages:[PracticePassage]=[]
        for group in groups.values {
            guard group.count>=4,let first=group.first,let last=group.last,last.time-first.time>=0.3 else { continue }
            let cents=group.map { 1200*log2($0.pitch) }.sorted()
            // Exclude changing notes; quantify only short, near-level pitch segments.
            guard let lo=cents.first,let hi=cents.last,hi-lo<=180 else { continue }
            let center=cents[cents.count/2]
            let distances=cents.map { abs($0-center) }.sorted()
            let deviation=distances[distances.count/2]
            deviations.append(deviation)
            let levels=group.map(\.rms).sorted(),middle=levels[levels.count/2]
            let changes=levels.map { abs($0-middle)/max(0.008,middle) }.sorted()
            let volumeDeviation=changes[changes.count/2]
            volumeDeviations.append(volumeDeviation)
            passages.append(.init(start:first.time,steadiness:points(deviation*2),volumeEvenness:points(volumeDeviation*250)))
        }
        result.steadyWindows=deviations.count
        if deviations.count>=3 {
            deviations.sort()
            result.steadiness=points(deviations[deviations.count/2]*2)
            volumeDeviations.sort()
            result.volumeEvenness=points(volumeDeviations[volumeDeviations.count/2]*250)
        }
        result.passages=passages.sorted { $0.start<$1.start }
        let loud=Double(frames.filter { $0.rms>0.65 }.count)/Double(max(1,frames.count))
        result.levelHeadroom=Int((100*(1-loud)).rounded())
        return result
    }

    private static func points(_ deduction:Double)->Int { Int(max(0,min(100,100-deduction)).rounded()) }

    var tips:[PracticeTip] {
        if let levelHeadroom,levelHeadroom<90 {
            return [.init(id:"recording",at:loudestTime,title:"先让声音更清楚",
                observation:"这次有几处声音太响，先调整收音再比较分数。",
                action:"把伴奏调低一格，用平时说话稍大一点的声音唱十秒。",
                goal:"下一次录到的声音更清楚，分数才更方便比较。")]
        }
        guard practiceScore != nil else {
            return [.init(id:"more-voice",at:nil,title:"先录一段舒服的长音",
                observation:"这次能用来比较的长音还比较少。",
                action:"把原唱调小，选一个舒服的音，轻声唱“啊”三秒，休息一下，再唱两遍。",
                goal:"先让手机连续听清你的声音，再查看练习分。")]
        }
        var result:[PracticeTip]=[]
        if let passage=passages?.min(by:{$0.steadiness<$1.steadiness}),passage.steadiness<85 {
            result.append(.init(id:"steady",at:passage.start,title:"把这一小段唱稳",
                observation:"这里的长音有一些上下晃动。",
                action:"单独练这一小段，用舒服的音量把同一个音唱满三秒，连练三遍。",
                goal:"注意听：开始、中间和收尾的声音高低尽量接近。"))
        }
        if let passage=passages?.min(by:{$0.volumeEvenness<$1.volumeEvenness}),passage.volumeEvenness<85 {
            result.append(.init(id:"even-volume",at:passage.start,title:"让声音大小更均匀",
                observation:"这里同一个长音的声音大小变化比较明显。",
                action:"先保持手机距离，再轻声重复这一句；句尾慢慢收住。",
                goal:"注意听长音中间是否忽大忽小。"))
        }
        if result.isEmpty {
            result.append(.init(id:"keep-steady",at:passages?.first?.start,title:"把平稳的感觉带回歌曲",
                observation:"这次测到的长音比较平稳。",
                action:"选一小句，用刚才舒服的音量再唱两遍，保持手机距离。",
                goal:"比较两遍的长音是否都能保持平稳。"))
        }
        return Array(result.prefix(3))
    }

    var text: String {
        let total=practiceScore.map { "\($0) / 100" } ?? "待评分"
        let stability=practiceScore == nil ? "待评分" : steadiness.map { "\($0) / 100" } ?? "待评分"
        let volume=practiceScore == nil ? "待评分" : volumeEvenness.map { "\($0) / 100" } ?? "待评分"
        return """
        练习参考分：\(total)
        长音稳不稳：\(stability)
        音量平不平：\(volume)
        \(recordingQuality)

        分数看的是这次收音里的长音表现：声音高低是否平稳占七成，声音大小是否均匀占三成。手机也会收到伴奏与原唱。唱得准不准、是否跟上节奏，需要歌曲的参考旋律和准确时间位置。

        \(tips.map { "\($0.timeLabel) · \($0.title)\n\($0.observation)\n怎么练：\($0.action)\n练到什么样：\($0.goal)" }.joined(separator:"\n\n"))
        """
    }
}
