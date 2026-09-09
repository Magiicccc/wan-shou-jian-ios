import Foundation
import Speech
import AVFoundation

struct HeardWord {
    var text:String
    var start:Double
    var confidence:Float
    var duration:Double = 0
    var provisional:Bool = false
}

enum LyricSpeechStatus:Equatable {
    case starting, listening, retrying, unavailable(String)
}

enum LyricAlignment {
    struct Match {
        var cue:LyricCue
        var observed:Double
        var provisional:Bool
        var matchedCount:Int
    }
    static func normalized(_ text:String)->String {
        text.folding(options:[.caseInsensitive,.diacriticInsensitive,.widthInsensitive],locale:Locale(identifier:"zh_CN"))
            .unicodeScalars.filter{CharacterSet.alphanumerics.contains($0)}.map(String.init).joined()
    }
    static func match(words:[HeardWord],cues:[LyricCue],near:Double?,now:Double)->Match? {
        guard now.isFinite else { return nil }
        struct HeardCharacter {
            var value:Character
            var observed:Double
            var trusted:Bool
            var provisional:Bool
        }
        var heard:[HeardCharacter]=[]
        for word in words.suffix(80) {
            guard word.start.isFinite,now>=word.start,now-word.start<24 else { continue }
            let characters=Array(normalized(word.text).prefix(160))
            // Partial hypotheses can have unset confidence. Repeated agreement is checked by the caller.
            let provisional=word.provisional && word.confidence==0
            let trusted=word.confidence.isFinite && (word.confidence>=0.4 || provisional)
            for (i,character) in characters.enumerated() {
                let within=word.duration.isFinite ? min(12,max(0,word.duration))*Double(i)/Double(max(1,characters.count)) : 0
                heard.append(.init(value:character,observed:word.start+within,trusted:trusted,provisional:provisional))
            }
        }
        heard=Array(heard.suffix(600))
        guard heard.count>=4 else { return nil }
        let text=heard.map(\.value)
        var matches:[Match]=[]
        for (index,cue) in cues.enumerated() {
            var needle=Array(normalized(cue.text).prefix(10))
            if needle.count<6,index+1<cues.count,cues[index+1].start-cue.start<=12 {
                needle += normalized(cues[index+1].text).prefix(10-needle.count)
            }
            guard needle.count>=4,needle.count<=text.count else { continue }
            for start in (0...(text.count-needle.count)).reversed() {
                guard Array(text[start..<(start+needle.count)])==needle else { continue }
                let evidence=heard[start..<(start+needle.count)]
                guard evidence.allSatisfy(\.trusted),let first=evidence.first,
                      now>=first.observed,now-first.observed<20 else { continue }
                let partial=evidence.contains(where: \.provisional)
                guard !partial || needle.count>=6 else { continue }
                matches.append(.init(cue:cue,observed:first.observed,provisional:partial,matchedCount:needle.count))
                break
            }
        }
        // Prefer the latest utterance. Repeated chorus text requires a nearby established clock.
        guard let latest=matches.map(\.observed).max() else { return nil }
        var candidates=matches.filter { abs($0.observed-latest)<0.25 }
        if let longest=candidates.map(\.matchedCount).max() { candidates=candidates.filter { $0.matchedCount==longest } }
        if candidates.count>1,let near { candidates=candidates.filter { abs($0.cue.start+(now-$0.observed)-near)<10 } }
        return candidates.count==1 ? candidates[0] : nil
    }
}

// The speech request shares the existing audio tap. It is always on-device.
final class SpokenLyricSync:@unchecked Sendable {
    private let lock=NSLock()
    private var request:SFSpeechAudioBufferRecognitionRequest?
    private var base:Double?
    private var task:SFSpeechRecognitionTask?
    private var timer:Task<Void,Never>?
    private var restart:Task<Void,Never>?
    private var generation=0
    private var failures=0
    private var active=false
    private var ending=false
    private var openedAt=0.0
    private var lastResultAt=0.0
    private var context:[String]=[]
    private let recognizer=SFSpeechRecognizer(locale:Locale(identifier:"zh-CN"))
    var receive:(( [HeardWord] )->Void)?
    var state:((LyricSpeechStatus)->Void)?

    @MainActor func setContext(_ cues:[LyricCue]) {
        context=Array(cues.map { String($0.text.prefix(60)) }.prefix(80))
    }

    @MainActor func authorize() async {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            _ = await withCheckedContinuation { (continuation:CheckedContinuation<SFSpeechRecognizerAuthorizationStatus,Never>) in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning:$0) }
            }
        }
    }
    @MainActor func start() {
        stop();active=true;failures=0
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            state?(.unavailable("请在 iPhone 设置中允许本 App 的语音识别权限。"))
            return
        }
        guard recognizer?.supportsOnDeviceRecognition==true else {
            state?(.unavailable("本机中文识别暂不可用；继续尝试播放器进度。"));return
        }
        state?(.starting)
        rotate()
        timer=Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds:1_000_000_000) } catch { return }
                guard let self,self.active else { return }
                let now=ProcessInfo.processInfo.systemUptime
                if self.restart==nil,!self.ending,(now-self.openedAt>=18 || now-self.lastResultAt>=10) {
                    self.finishWindow()
                }
            }
        }
    }
    @MainActor private func rotate() {
        restart?.cancel();restart=nil;ending=false
        generation += 1;let token=generation
        lock.lock();let old=request;request=nil;base=nil;lock.unlock()
        old?.endAudio();task?.cancel();task=nil
        guard active else { return }
        guard let recognizer,recognizer.isAvailable else {
            state?(.retrying);scheduleRestart(after:5,token:token);return
        }
        let next=SFSpeechAudioBufferRecognitionRequest()
        next.requiresOnDeviceRecognition=true;next.shouldReportPartialResults=true;next.taskHint = .dictation
        next.contextualStrings=context
        openedAt=ProcessInfo.processInfo.systemUptime;lastResultAt=openedAt
        lock.lock();request=next;lock.unlock()
        task=recognizer.recognitionTask(with:next) { [weak self] result,error in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self,self.active,self.generation==token else { return }
                self.lock.lock();let base=self.base;self.lock.unlock()
                if let result,let base {
                    self.lastResultAt=ProcessInfo.processInfo.systemUptime;self.failures=0
                    self.state?(.listening)
                    let words=result.bestTranscription.segments.map {
                        HeardWord(text:$0.substring,start:base+$0.timestamp,confidence:$0.confidence,
                                  duration:$0.duration,provisional:!result.isFinal)
                    }
                    self.receive?(words)
                }
                if error != nil || result?.isFinal==true {
                    if error != nil { self.failures += 1 } else { self.failures=0 }
                    self.lock.lock();let old=self.request;self.request=nil;self.lock.unlock();old?.endAudio()
                    if error != nil { self.state?(.retrying) }
                    self.scheduleRestart(after:error == nil ? 0.15 : min(15,Double(max(1,self.failures))*2),token:token)
                }
            }
        }
    }
    @MainActor private func scheduleRestart(after seconds:Double,token:Int) {
        restart?.cancel()
        restart=Task { [weak self] in
            do { try await Task.sleep(nanoseconds:UInt64(seconds*1_000_000_000)) } catch { return }
            guard let self,self.active,self.generation==token else { return }
            self.rotate()
        }
    }
    @MainActor private func finishWindow() {
        ending=true
        lock.lock();let old=request;request=nil;lock.unlock()
        // Give the final transcript time to arrive before replacing the recognition task.
        old?.endAudio()
        scheduleRestart(after:2,token:generation)
    }
    func append(_ buffer:AVAudioPCMBuffer) {
        lock.lock();defer{lock.unlock()}
        guard let request else { return }
        if base==nil { base=ProcessInfo.processInfo.systemUptime-Double(buffer.frameLength)/buffer.format.sampleRate }
        request.append(buffer)
    }
    @MainActor func stop() {
        active=false;generation += 1;timer?.cancel();timer=nil;restart?.cancel();restart=nil;ending=false
        lock.lock();let old=request;request=nil;base=nil;lock.unlock()
        old?.endAudio();task?.cancel();task=nil
    }
}
