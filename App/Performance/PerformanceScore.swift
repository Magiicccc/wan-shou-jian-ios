import Foundation

enum SongMood: String, Codable, CaseIterable {
    case reflective = "沉静", sorrow = "哀伤", tense = "张力", warm = "温暖"
    var rgb: LightRGB {
        switch self {
        case .reflective: return LightRGB(red: 20, green: 116, blue: 255)
        case .sorrow: return LightRGB(red: 65, green: 28, blue: 220)
        case .tense: return LightRGB(red: 225, green: 24, blue: 63)
        case .warm: return LightRGB(red: 255, green: 136, blue: 30)
        }
    }
}

enum TypeScene: String, Codable, CaseIterable {
    case narrative, intimate, confrontation, falling, rising, echo, climax
}

enum LyricPalette:String,Codable,CaseIterable { case silver, mist, rose, wine, amber, champagne }

struct LyricCue: Identifiable, Codable, Equatable {
    var id: Int
    var start: Double
    var end: Double
    var text: String
    var emphasis: String
    var scene: TypeScene
    var mood: SongMood
    var groups:[String]? = nil
    var palette:LyricPalette? = nil
    var intensity:Double? = nil
    var focusStart:Int? = nil
}

enum ScoreError: LocalizedError {
    case invalidLyrics, invalidPlan, invalidEndpoint, missingKey, server(Int), malformedResponse
    var errorDescription: String? {
        switch self {
        case .invalidLyrics: return "请导入带时间标记的 LRC 歌词。"
        case .invalidPlan: return "分镜校验失败，已保留本地编排。"
        case .invalidEndpoint: return "请填写完整的 HTTPS API 地址。"
        case .missingKey: return "请先在 AI 设置中填写密钥。"
        case .server(let code): return "服务返回 HTTP \(code)，请检查模型、余额或网络。"
        case .malformedResponse: return "服务响应格式不完整，请重试。"
        }
    }
}

enum PerformanceScore {
    static let demoTitle = "夜航 · 原创舞台练习"
    static let demo: [LyricCue] = [
        .init(id: 0, start: 0, end: 6, text: "让夜色慢慢靠近", emphasis: "夜色", scene: .intimate, mood: .reflective),
        .init(id: 1, start: 6, end: 12, text: "把回声留在掌心", emphasis: "回声", scene: .echo, mood: .sorrow),
        .init(id: 2, start: 12, end: 18, text: "那些未说完的话", emphasis: "未说完", scene: .falling, mood: .sorrow),
        .init(id: 3, start: 18, end: 24, text: "此刻终于有了声音", emphasis: "声音", scene: .rising, mood: .tense),
        .init(id: 4, start: 24, end: 30, text: "向着光抬起头", emphasis: "光", scene: .climax, mood: .warm),
        .init(id: 5, start: 30, end: 36, text: "让心跳穿过寂静", emphasis: "心跳", scene: .confrontation, mood: .tense),
        .init(id: 6, start: 36, end: 42, text: "我仍听见你的回音", emphasis: "回音", scene: .echo, mood: .reflective),
        .init(id: 7, start: 42, end: 48, text: "在黎明以前相拥", emphasis: "相拥", scene: .intimate, mood: .warm)
    ]

    static func parseLRC(_ input: String, duration: Double) throws -> [LyricCue] {
        guard input.utf8.count <= 512_000, duration.isFinite, duration > 0 else { throw ScoreError.invalidLyrics }
        let regex = try NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{2})(?:[.:](\d{1,3}))?\]"#)
        let offsetRegex = try NSRegularExpression(pattern: #"\[offset:([+-]?\d+)\]"#, options: .caseInsensitive)
        let ns = input as NSString
        var offset = 0.0
        if let m = offsetRegex.firstMatch(in: input, range: NSRange(location: 0, length: ns.length)) {
            offset = (Double(ns.substring(with: m.range(at: 1))) ?? 0) / 1000
        }
        var rows: [(Double, String)] = []
        for line in input.components(separatedBy: .newlines) {
            let s = line as NSString
            let matches = regex.matches(in: line, range: NSRange(location: 0, length: s.length))
            guard let last = matches.last else { continue }
            let text = s.substring(from: NSMaxRange(last.range)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 100 else { continue }
            for match in matches {
                let minutes = Double(s.substring(with: match.range(at: 1))) ?? 0
                let seconds = Double(s.substring(with: match.range(at: 2))) ?? 0
                guard seconds < 60 else { continue }
                let fraction = match.range(at: 3).location == NSNotFound ? 0 : (Double("0." + s.substring(with: match.range(at: 3))) ?? 0)
                let time = max(0, minutes * 60 + seconds + fraction + offset)
                if time < duration { rows.append((time, text)) }
            }
        }
        rows.sort { $0.0 < $1.0 }
        var unique: [(Double,String)] = []
        for row in rows { if unique.last?.0 != row.0 { unique.append(row) } }
        guard !unique.isEmpty, unique.count <= 2000 else { throw ScoreError.invalidLyrics }
        return unique.enumerated().map { index, row in
            let mood: SongMood = ["失去", "离开", "泪", "孤独", "再见"].contains(where: row.1.contains) ? .sorrow : .reflective
            return LyricCue(id: index, start: row.0, end: index + 1 < unique.count ? unique[index+1].0 : duration,
                            text: row.1, emphasis: "", scene: .narrative, mood: mood)
        }
    }

    static func cue(at time: Double, in cues: [LyricCue]) -> LyricCue? {
        cues.last { time >= $0.start && time < $0.end }
    }

    struct Direction: Codable {
        var id: Int
        var emphasis: String
        var scene: TypeScene
        var mood: SongMood
        var groups:[String]? = nil
        var palette:LyricPalette? = nil
        var intensity:Double? = nil
        var focusStart:Int? = nil
    }
    struct Plan: Codable { var directions: [Direction] }
    static func apply(_ plan: Plan, to cues: [LyricCue]) throws -> [LyricCue] {
        guard plan.directions.count == cues.count, Set(plan.directions.map(\.id)).count == cues.count else { throw ScoreError.invalidPlan }
        var result = cues
        for direction in plan.directions {
            guard let i = result.firstIndex(where: { $0.id == direction.id }),
                  direction.emphasis.count <= 8, (direction.emphasis.isEmpty || result[i].text.contains(direction.emphasis)) else { throw ScoreError.invalidPlan }
            if let groups=direction.groups {
                guard (1...3).contains(groups.count),groups.allSatisfy({!$0.isEmpty}),groups.joined()==result[i].text else { throw ScoreError.invalidPlan }
            }
            if let intensity=direction.intensity { guard intensity.isFinite,(0...1).contains(intensity) else { throw ScoreError.invalidPlan } }
            if let start=direction.focusStart {
                let chars=Array(result[i].text)
                guard start>=0,start<=chars.count,direction.emphasis.count<=chars.count-start,
                      String(chars[start..<(start+direction.emphasis.count)])==direction.emphasis else { throw ScoreError.invalidPlan }
            }
            result[i].emphasis = direction.emphasis; result[i].scene = direction.scene; result[i].mood = direction.mood
            result[i].groups=direction.groups;result[i].palette=direction.palette
            result[i].intensity=direction.intensity;result[i].focusStart=direction.focusStart
        }
        return result
    }
}

struct VocalFrame: Codable, Equatable {
    var time: Double
    var rms: Double
    var pitch: Double
    var confidence: Double
}

enum VocalMetrics {
    static func measure(_ samples: [Float], rate: Double, time: Double) -> VocalFrame {
        guard samples.count >= 256, rate >= 8000, rate.isFinite else { return .init(time: time, rms: 0, pitch: 0, confidence: 0) }
        let strideSize = max(1, Int(rate / 12000))
        let data = stride(from: 0, to: samples.count, by: strideSize).map { samples[$0].isFinite ? Double(samples[$0]) : 0 }
        let mean = data.reduce(0,+) / Double(data.count)
        let x = data.map { $0 - mean }
        let rms = sqrt(x.reduce(0) { $0 + $1*$1 } / Double(x.count))
        guard rms > 0.008 else { return .init(time: time, rms: rms, pitch: 0, confidence: 0) }
        let sampleRate = rate / Double(strideSize)
        let lower = max(2, Int(sampleRate/900)), upper = min(x.count/2, Int(sampleRate/65))
        guard upper > lower else { return .init(time: time, rms: rms, pitch: 0, confidence: 0) }
        var best = 0.0, bestLag = 0
        for lag in lower...upper {
            var ab=0.0, aa=0.0, bb=0.0
            for i in 0..<(x.count-lag) { ab += x[i]*x[i+lag]; aa += x[i]*x[i]; bb += x[i+lag]*x[i+lag] }
            let correlation = ab / max(1e-12,sqrt(aa*bb))
            if correlation > best + 0.005 { best=correlation;bestLag=lag }
        }
        return .init(time: time, rms: rms, pitch: best > 0.75 && bestLag > 0 ? sampleRate / Double(bestLag) : 0, confidence: unit(best))
    }

    static func report(_ frames: [VocalFrame]) -> String {
        let voiced = frames.filter { $0.pitch > 0 && $0.confidence >= 0.8 }
        guard voiced.count >= 10 else { return "有效声线样本较少。请靠近手机轻唱一段，适当降低伴奏音量后重新录制。" }
        let minPitch = voiced.map(\.pitch).min() ?? 0, maxPitch = voiced.map(\.pitch).max() ?? 0
        let loud = frames.filter { $0.rms > 0.85 }.count
        return "测得声线范围约 \(Int(minPitch))–\(Int(maxPitch)) Hz，有效样本 \(voiced.count) 个。\n\n\(loud > 0 ? "出现较高输入电平，建议降低返送和伴奏音量。" : "输入电平保持在当前测量范围内。")\n\n当前使用手机外放收音，包含房间回声和伴奏。此报告描述检测到的声线；具体音准对照将在导入参考旋律后提供。"
    }
}
