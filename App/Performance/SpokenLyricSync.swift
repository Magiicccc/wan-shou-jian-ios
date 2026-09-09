import Foundation
import Speech
import AVFoundation

struct HeardWord {
    var text:String
    var start:Double
    var confidence:Float
}

enum LyricAlignment {
    static func normalized(_ text:String)->String {
        text.folding(options:[.caseInsensitive,.diacriticInsensitive,.widthInsensitive],locale:Locale(identifier:"zh_CN"))
            .unicodeScalars.filter{CharacterSet.alphanumerics.contains($0)}.map(String.init).joined()
    }
    static func match(words:[HeardWord],cues:[LyricCue],near:Double?,now:Double)->(cue:LyricCue,observed:Double)? {
        guard now.isFinite else { return nil }
        for i in words.indices.reversed() {
            let word=words[i]
            guard word.start.isFinite,now>=word.start,now-word.start<10,word.confidence>=0.4 else { continue }
            let phrase=normalized(words[i...].map(\.text).joined())
            guard phrase.count>=6 else { continue }
            var candidates=cues.filter {
                let text=normalized($0.text)
                return text.count>=6 && phrase.hasPrefix(String(text.prefix(min(10,text.count))))
            }
            if candidates.count>1,let near { candidates=candidates.filter{abs($0.start-near)<8} }
            if candidates.count==1 { return (candidates[0],word.start) }
        }
        return nil
    }
}

// The speech request shares the existing audio tap. It is always on-device.
final class SpokenLyricSync:@unchecked Sendable {
    private let lock=NSLock()
    private var request:SFSpeechAudioBufferRecognitionRequest?
    private var base:Double?
    private var task:SFSpeechRecognitionTask?
    private var timer:Task<Void,Never>?
    private var generation=0
    private var failures=0
    private var active=false
    private let recognizer=SFSpeechRecognizer(locale:Locale(identifier:"zh-CN"))
    var receive:(( [HeardWord] )->Void)?
    var state:((String)->Void)?

    @MainActor func authorize() async {
        if SFSpeechRecognizer.authorizationStatus() == .notDetermined {
            _ = await withCheckedContinuation { (continuation:CheckedContinuation<SFSpeechRecognizerAuthorizationStatus,Never>) in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning:$0) }
            }
        }
    }
    @MainActor func start() {
        stop();active=true;failures=0
        guard SFSpeechRecognizer.authorizationStatus() == .authorized,
              recognizer?.supportsOnDeviceRecognition==true else {
            state?("声音辅助定位待系统授权或本机语言支持；继续尝试播放器同步。")
            return
        }
        rotate()
        timer=Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds:45_000_000_000) } catch { return }
                guard let self,self.active else { return };self.rotate()
            }
        }
    }
    @MainActor private func rotate() {
        generation += 1;let token=generation
        lock.lock();let old=request;request=nil;base=nil;lock.unlock()
        old?.endAudio();task?.cancel();task=nil
        guard active,failures<4,let recognizer,recognizer.isAvailable else { return }
        let next=SFSpeechAudioBufferRecognitionRequest()
        next.requiresOnDeviceRecognition=true;next.shouldReportPartialResults=true;next.taskHint = .dictation
        lock.lock();request=next;lock.unlock()
        task=recognizer.recognitionTask(with:next) { [weak self] result,error in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self,self.active,self.generation==token else { return }
                self.lock.lock();let base=self.base;self.lock.unlock()
                if let result,let base {
                    let words=result.bestTranscription.segments.map { HeardWord(text:$0.substring,start:base+$0.timestamp,confidence:$0.confidence) }
                    self.receive?(words)
                }
                if error != nil || result?.isFinal==true {
                    if error != nil { self.failures += 1 } else { self.failures=0 }
                    self.lock.lock();let old=self.request;self.request=nil;self.lock.unlock();old?.endAudio()
                    if self.failures>=4 { self.state?("声音定位暂时不可用，继续跟随播放器；重新开始舞台可重试。") }
                    else {
                        try? await Task.sleep(nanoseconds:1_000_000_000)
                        if self.active,self.generation==token { self.rotate() }
                    }
                }
            }
        }
    }
    func append(_ buffer:AVAudioPCMBuffer) {
        lock.lock();defer{lock.unlock()}
        guard let request else { return }
        if base==nil { base=ProcessInfo.processInfo.systemUptime-Double(buffer.frameLength)/buffer.format.sampleRate }
        request.append(buffer)
    }
    @MainActor func stop() {
        active=false;generation += 1;timer?.cancel();timer=nil
        lock.lock();let old=request;request=nil;base=nil;lock.unlock()
        old?.endAudio();task?.cancel();task=nil
    }
}
