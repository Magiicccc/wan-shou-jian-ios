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

/// Relative practice indicators from mixed microphone input, independent of song identity.
struct PracticeAssessment: Codable, Equatable {
    var validSamples: Int
    var measuredSeconds: Double
    var steadyWindows: Int
    var steadiness: Int?
    var levelHeadroom: Int?
    var referenceMelodyAvailable = false

    static func evaluate(_ input: [VocalFrame]) -> Self {
        let frames=input.filter { $0.time.isFinite && $0.time>=0 && $0.rms.isFinite && $0.rms>=0 && $0.pitch.isFinite && $0.confidence.isFinite }
            .sorted { $0.time < $1.time }
        let voiced=frames.filter { (65...900).contains($0.pitch) && $0.confidence>=0.8 && $0.rms>0.008 }
        let seconds=max(0,(frames.last?.time ?? 0)-(frames.first?.time ?? 0))
        var result=Self(validSamples:voiced.count,measuredSeconds:seconds,steadyWindows:0)
        guard voiced.count>=30,seconds>=5 else { return result }
        let groups=Dictionary(grouping:voiced) { Int(min(1200,$0.time)*2) }
        var deviations:[Double]=[]
        for group in groups.values {
            guard group.count>=4,let first=group.first,let last=group.last,last.time-first.time>=0.3 else { continue }
            let cents=group.map { 1200*log2($0.pitch) }.sorted()
            // Exclude changing notes; quantify only short, near-level pitch segments.
            guard let lo=cents.first,let hi=cents.last,hi-lo<=180 else { continue }
            let center=cents[cents.count/2]
            let distances=cents.map { abs($0-center) }.sorted()
            deviations.append(distances[distances.count/2])
        }
        result.steadyWindows=deviations.count
        if deviations.count>=3 {
            deviations.sort()
            result.steadiness=Int(max(0,min(100,100-deviations[deviations.count/2]*2)).rounded())
        }
        let loud=Double(frames.filter { $0.rms>0.65 }.count)/Double(max(1,frames.count))
        result.levelHeadroom=Int((100*(1-loud)).rounded())
        return result
    }

    var text: String {
        let stability=steadiness.map { "\($0) / 100" } ?? "等待更多持续声线"
        let headroom=levelHeadroom.map { "\($0) / 100" } ?? "等待更多有效收音"
        return """
        练习参考分
        持续声线稳定度：\(stability)
        收音电平余量：\(headroom)
        有效声线 \(validSamples) 个 · 持续片段 \(steadyWindows) 个

        评分依据手机麦克风的混合收音，用于比较自己的练习记录。伴奏、原唱和回声会影响测量；音准与节拍评分需要对应参考旋律及同步时间轴。AI 根据这些指标提供练习建议。
        """
    }
}
