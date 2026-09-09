import AVFoundation
import Combine
import Foundation

private final class VocalProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private let queue = DispatchQueue(label: "wsj.vocal.analysis", qos: .userInitiated)
    var receive: (@Sendable (VocalFrame) -> Void)?
    func offer(_ buffer: AVAudioPCMBuffer, time: Double) {
        lock.lock()
        guard !busy, let data = buffer.floatChannelData?[0] else { lock.unlock(); return }
        busy=true; lock.unlock()
        let samples = Array(UnsafeBufferPointer(start: data, count: min(Int(buffer.frameLength), 8192)))
        let rate = buffer.format.sampleRate
        queue.async { [self] in
            let frame=VocalMetrics.measure(samples, rate: rate, time: time)
            receive?(frame)
            lock.lock();busy=false;lock.unlock()
        }
    }
}

@MainActor
final class KaraokeSession: ObservableObject {
    @Published private(set) var externalMusic = false
    @Published private(set) var recovering = false
    @Published private(set) var requestingPermission = false
    @Published private(set) var route = "开始后显示收音与播放设备"
    @Published var externalMood: SongMood = .reflective
    @Published private(set) var title = PerformanceScore.demoTitle
    @Published private(set) var cues = PerformanceScore.demo
    @Published private(set) var position = 0.0
    @Published private(set) var duration = 48.0
    @Published private(set) var playing = false
    @Published private(set) var vocal = VocalFrame(time: 0, rms: 0, pitch: 0, confidence: 0)
    @Published private(set) var energy = 0.0
    @Published private(set) var light = LightState.idle
    @Published private(set) var status = "原创器乐与歌词演示 · 句级编排"
    @Published private(set) var report = "演唱结束后，查看本机声线测量与练习建议。"
    @Published private(set) var analyzing = false
    @Published private(set) var hasMicrophone = false
    @Published var accompanimentVolume = 0.45 { didSet { player?.volume=Float(accompanimentVolume) } }
    @Published var monitorVolume = 0.12 { didSet { engine?.mainMixerNode.outputVolume=monitorEnabled ? Float(min(0.3,max(0,monitorVolume))) : 0 } }
    @Published var reverbAmount = 0.12 { didSet { reverb?.wetDryMix=Float(min(0.3,max(0,reverbAmount))*100) } }
    @Published var monitorEnabled = false { didSet { engine?.mainMixerNode.outputVolume=monitorEnabled ? Float(min(0.3,max(0,monitorVolume))) : 0 } }
    @Published var brightness = 0.45
    private let manager: LightstickManager
    private let preview: Bool
    private var player: AVAudioPlayer?
    private var engine: AVAudioEngine?
    private var reverb: AVAudioUnitReverb?
    private var probe: VocalProbe?
    private var timer: Task<Void,Never>?
    private var generation = 0
    private var frames: [VocalFrame] = []
    private var bins: [Double] = []
    private var observers: [NSObjectProtocol] = []
    private var assetURL: URL?
    private var importGeneration = 0
    private var color = [0.0,0.0,0.0]
    private var audioActive=false
    private var wantsPlaying=false
    private var interrupted=false
    private var captureGranted=false
    private var recoveryTask: Task<Void, Never>?
    private var configurationObserver: NSObjectProtocol?
    private var externalClock = PerformanceClock()
    private let recoveryDelay: UInt64
    private var takeGeneration = 0
    private struct SavedSong: Codable { var file:String;var title:String;var cues:[LyricCue] }
    private var songDirectory:URL { FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Songs") }
    var currentCue: LyricCue? { PerformanceScore.cue(at: position, in: cues) }
    var evidence: [VocalFrame] { frames.enumerated().filter { $0.offset.isMultiple(of: max(1,frames.count/100)) }.map(\.element) }

    init(manager: LightstickManager, preview: Bool = false, recoveryDelay: UInt64 = 700_000_000) {
        self.manager=manager;self.preview=preview
        self.recoveryDelay=recoveryDelay
        if let url=Bundle.main.url(forResource:"NightVoyage",withExtension:"wav") { load(url, title: PerformanceScore.demoTitle) }
        if !preview,let data=UserDefaults.standard.data(forKey:"stage.song"),
           let saved=try? JSONDecoder().decode(SavedSong.self,from:data),
           saved.file == URL(fileURLWithPath:saved.file).lastPathComponent,
           load(songDirectory.appendingPathComponent(saved.file),title:saved.title) {
            cues=saved.cues;status="已恢复上次的歌曲与分镜。"
        }
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification, AVAudioSession.mediaServicesWereResetNotification, AVAudioSession.mediaServicesWereLostNotification] {
            observers.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { [weak self] notification in
                let event: AudioCaptureEvent
                if name == AVAudioSession.routeChangeNotification {
                    let raw=(notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue ?? 0
                    guard raw != AVAudioSession.RouteChangeReason.categoryChange.rawValue else { return }
                    event = .routeChanged
                } else if name == AVAudioSession.mediaServicesWereResetNotification {
                    event = .mediaServicesReset
                } else if name == AVAudioSession.mediaServicesWereLostNotification {
                    event = .mediaServicesLost
                } else {
                    let raw=(notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue ?? 0
                    let options=(notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
                    event = raw == AVAudioSession.InterruptionType.began.rawValue ? .interruptionBegan
                        : .interruptionEnded(shouldResume: AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume))
                }
                Task { @MainActor [weak self] in self?.handleAudioEvent(event) }
            })
        }
    }

    deinit {
        timer?.cancel(); recoveryTask?.cancel()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    var isSessionActive: Bool { playing || recovering || requestingPermission || interrupted }

    func useExternalMusic(title: String = "网易云 · 自由演唱") {
        pause(); importGeneration += 1; takeGeneration += 1
        externalMusic=true; self.title=String(title.prefix(100)); cues=[]; bins=[]; frames=[]
        duration=1200; position=0; externalClock=PerformanceClock(); monitorEnabled=false
        vocal = .init(time:0,rms:0,pitch:0,confidence:0); energy=0; light = .idle
        report="唱完后点击结束，查看练习参考分与 AI 建议。"
        status="先开始收音，再切到网易云播放并跟唱；结束后返回复盘。"
    }

    @discardableResult func load(_ url: URL, title: String) -> Bool {
        pause();importGeneration += 1
        do {
            let p=try AVAudioPlayer(contentsOf:url)
            guard p.duration > 0, p.duration <= 1200 else { status="请选择二十分钟以内的音频。";return false }
            p.prepareToPlay();p.volume=Float(accompanimentVolume)
            externalMusic=false; takeGeneration += 1
            self.player=p;self.assetURL=url;self.title=title;duration=p.duration;position=0;frames=[];bins=[]
            let token=importGeneration
            Task {
                let result=await Task.detached(priority:.utility) { () -> [Double] in
                    guard let file=try? AVAudioFile(forReading:url), let buffer=AVAudioPCMBuffer(pcmFormat:file.processingFormat, frameCapacity:8192) else { return [] }
                    var result:[Double]=[];var power=0.0;var count=0
                    let window=max(1,Int(file.processingFormat.sampleRate*0.2))
                    while file.framePosition < file.length {
                        do { try file.read(into:buffer) } catch { break }
                        guard buffer.frameLength > 0, let data=buffer.floatChannelData?[0] else { break }
                        for i in 0..<Int(buffer.frameLength) {
                            power += Double(data[i]*data[i]);count += 1
                            if count >= window { result.append(min(1,sqrt(power/Double(count))*4));power=0;count=0 }
                        }
                    }
                    if count>0 { result.append(min(1,sqrt(power/Double(count))*4)) }
                    return result
                }.value
                if self.importGeneration == token { self.bins=result }
            }
            return true
        } catch { status="音频读取失败，请换一个 MP3、M4A 或 WAV 文件。";return false }
    }

    func importAudio(_ url: URL) {
        let granted=url.startAccessingSecurityScopedResource();defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
            guard size <= 200_000_000 else { status="请选择 200 MB 以内的音频。";return }
            let directory=songDirectory
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let copy=directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(url.pathExtension)
            try FileManager.default.copyItem(at:url,to:copy)
            let previous=assetURL
            guard load(copy,title:url.deletingPathExtension().lastPathComponent) else { try? FileManager.default.removeItem(at:copy);return }
            cues=[];saveSong();status="音频已导入，请添加对应 LRC 歌词。"
            if let previous,previous.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL { try? FileManager.default.removeItem(at:previous) }
        } catch { status="导入失败，请在文件 App 中下载完整音频后重试。" }
    }

    func importLyrics(_ url: URL) {
        guard !externalMusic else { status="外部播放的歌词请在音乐 App 查看；本地音频可导入同步歌词。"; return }
        let granted=url.startAccessingSecurityScopedResource();defer { if granted { url.stopAccessingSecurityScopedResource() } }
        do {
            let size=try url.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0
            guard size<=512_000 else { throw ScoreError.invalidLyrics }
            cues=try PerformanceScore.parseLRC(String(contentsOf:url,encoding:.utf8),duration:duration)
            saveSong()
            status="歌词已导入 · 句级动态编排"
        } catch { status=error.localizedDescription }
    }

    func useDemo() {
        guard let url=Bundle.main.url(forResource:"NightVoyage",withExtension:"wav") else { status="演示音频资源缺失。";return }
        load(url,title:PerformanceScore.demoTitle);cues=PerformanceScore.demo;status="原创器乐与歌词演示 · 句级编排"
        if !preview { UserDefaults.standard.removeObject(forKey:"stage.song") }
    }

    func start(record: Bool = true) {
        guard !wantsPlaying, externalMusic || player != nil else { return }
        wantsPlaying=true; requestingPermission=true; interrupted=false
        takeGeneration += 1
        generation += 1;let token=generation
        Task {
            var granted=false
            if record && !preview { granted=await AVAudioApplication.requestRecordPermission() }
            guard generation == token, wantsPlaying else { return }
            requestingPermission=false
            if externalMusic && !granted && !preview {
                pause(); status="请在系统设置中允许麦克风权限，再开始外部音乐演唱。"; return
            }
            captureGranted=granted
            do {
                if position >= duration - 0.1 {
                    position=0; externalClock=PerformanceClock(); player?.currentTime=0; frames=[]; takeGeneration += 1
                }
                try resumeAudio(token:token)
            } catch { pause();status="音频启动失败：\(error.localizedDescription)" }
        }
    }

    private func startMicrophone(token: Int) throws {
        let engine=AVAudioEngine()
        // Voice-processing I/O can force a chat/HFP route. A2DP singing uses plain input.
        if !externalMusic && monitorEnabled && AVAudioSession.sharedInstance().currentRoute.outputs.allSatisfy({ $0.portType == .builtInSpeaker }) {
            try engine.inputNode.setVoiceProcessingEnabled(true)
        }
        let format=engine.inputNode.outputFormat(forBus:0)
        guard format.sampleRate.isFinite,format.sampleRate>=8000,format.channelCount>0,
              format.commonFormat == .pcmFormatFloat32,!format.isInterleaved else { throw ScoreError.malformedResponse }
        let reverb=AVAudioUnitReverb();reverb.loadFactoryPreset(.smallRoom);reverb.wetDryMix=Float(reverbAmount*100)
        engine.attach(reverb);engine.connect(engine.inputNode,to:reverb,format:format)
        engine.connect(reverb,to:engine.mainMixerNode,format:format)
        engine.mainMixerNode.outputVolume=monitorEnabled ? Float(min(0.3,monitorVolume)) : 0
        let probe=VocalProbe()
        probe.receive={ [weak self] frame in
            Task { @MainActor [weak self] in
                guard let self,self.generation==token,self.playing else { return }
                if self.externalMusic { self.position=min(self.duration,self.externalClock.elapsed(at:ProcessInfo.processInfo.systemUptime)) }
                var measured=frame;measured.time=self.position
                self.vocal=measured
                // Bound evidence at 10 Hz for the full twenty-minute take.
                if self.frames.count<12001 && (self.frames.last.map { measured.time - $0.time >= 0.1 } ?? true) { self.frames.append(measured) }
                if measured.rms>0.65 { self.monitorEnabled=false;self.status="输入电平过高，已关闭人声返送；伴奏和测量继续。" }
            }
        }
        engine.inputNode.installTap(onBus:0,bufferSize:2048,format:format) { buffer,_ in probe.offer(buffer,time:0) }
        self.engine=engine;self.reverb=reverb;self.probe=probe
        engine.prepare();try engine.start()
        configurationObserver=NotificationCenter.default.addObserver(forName:.AVAudioEngineConfigurationChange,object:engine,queue:.main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == token else { return }
                self.handleAudioEvent(.configurationChanged)
            }
        }
    }

    private func resumeAudio(token: Int) throws {
        if !preview {
            audioActive=true
            try HomeAudioRouting.activate(capture:captureGranted)
            if captureGranted { try startMicrophone(token:token) }
            manager.setBackgroundRhythmEnabled(true)
            manager.submitRhythmColor(LightState.idle.color)
            route=HomeAudioRouting.summary
        }
        if externalMusic { externalClock.resume(at:ProcessInfo.processInfo.systemUptime) }
        else {
            player?.volume=Float(accompanimentVolume)
            guard player?.play()==true else { throw ScoreError.malformedResponse }
        }
        playing=true; recovering=false; hasMicrophone=captureGranted
        status=preview ? "界面演示 · 合成测量" : externalMusic ? "正在收音 · 可切到网易云播放并跟唱" : captureGranted ? "正在收音 · 手机外放含伴奏与回声" : "伴奏舞台 · 麦克风关闭"
        timer?.cancel()
        timer=Task { [weak self] in
            while !Task.isCancelled {
                guard let self,self.playing else { return }
                self.tick()
                do { try await Task.sleep(nanoseconds:50_000_000) } catch { return }
            }
        }
    }

    private func suspendAudio(freezeExternalClock: Bool) {
        generation += 1; playing=false; hasMicrophone=false
        timer?.cancel(); timer=nil
        if freezeExternalClock {
            externalClock.pause(at:ProcessInfo.processInfo.systemUptime)
            if externalMusic { position=min(duration,externalClock.elapsed(at:ProcessInfo.processInfo.systemUptime)) }
        }
        player?.pause()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver=nil
        engine?.inputNode.removeTap(onBus:0);engine?.stop();engine=nil;probe=nil;reverb=nil
        vocal = .init(time:position,rms:0,pitch:0,confidence:0)
    }

    func handleAudioEvent(_ event: AudioCaptureEvent) {
        guard wantsPlaying, !requestingPermission else { return }
        switch event {
        case .routeChanged, .configurationChanged:
            guard !interrupted else { return }
            scheduleRecovery()
        case .interruptionBegan, .mediaServicesLost:
            recoveryTask?.cancel(); recoveryTask=nil
            suspendAudio(freezeExternalClock:true); interrupted=true; recovering=false
            status="系统暂时中断收音，宝宝剑连接保留。"
        case .interruptionEnded(let shouldResume):
            guard interrupted else { return }
            interrupted=false
            if shouldResume { scheduleRecovery() }
            else { pause(); status="音频已暂停，点击开始继续这一段。" }
        case .mediaServicesReset:
            pause(); status="系统音频服务已恢复，点击开始重建收音。"
        case .failed(let reason): pause(); status=reason
        }
    }

    private func scheduleRecovery() {
        recoveryTask?.cancel()
        suspendAudio(freezeExternalClock:false); recovering=true
        status="正在切换音频设备，宝宝剑连接保留。"
        let token=generation, delay=recoveryDelay
        recoveryTask=Task { [weak self] in
            for attempt in 0..<3 {
                do { try await Task.sleep(nanoseconds:delay * UInt64(attempt+1)) } catch { return }
                guard let self,self.wantsPlaying,self.generation==token,!self.interrupted else { return }
                do { try self.resumeAudio(token:token); self.recoveryTask=nil; return }
                catch {
                    if let observer=self.configurationObserver { NotificationCenter.default.removeObserver(observer) }
                    self.configurationObserver=nil
                    self.engine?.inputNode.removeTap(onBus:0);self.engine?.stop();self.engine=nil;self.probe=nil;self.reverb=nil
                }
            }
            guard let self,self.generation==token else { return }
            self.pause(); self.status="收音恢复暂未完成，检查音箱连接后点击开始重试。"
        }
    }

    func pause() {
        let wasActive=playing || engine != nil || audioActive
        wantsPlaying=false; recovering=false; requestingPermission=false; interrupted=false
        recoveryTask?.cancel(); recoveryTask=nil
        suspendAudio(freezeExternalClock:true)
        if !preview && wasActive { manager.endRhythm(sendBlack:true);try? AVAudioSession.sharedInstance().setActive(false,options:.notifyOthersOnDeactivation) }
        audioActive=false
    }

    func finish() { pause();report=PracticeAssessment.evaluate(frames).text + "\n\n" + VocalMetrics.report(frames);status="演唱已结束，练习参考分与复盘已更新。" }
    func seek(_ value: Double) {
        guard !externalMusic,value.isFinite else { return }
        position=min(duration,max(0,value));player?.currentTime=position
        frames=[];takeGeneration += 1
    }

    private func tick() {
        let target: Double
        if externalMusic {
            position=min(duration,externalClock.elapsed(at:ProcessInfo.processInfo.systemUptime))
            if position>=duration { finish(); return }
            target=unit(vocal.rms*4)
        } else {
            guard let player else { return }
            position=player.currentTime
            if !player.isPlaying { position=duration;finish();return }
            let bin=Int(position / 0.2)
            target=bin<bins.count ? bins[bin] : 0.15
        }
        energy=follow(energy,target,0.05,0.2)
        let beat=max(0,target-energy)*2
        let mood=externalMusic ? externalMood : currentCue?.mood ?? .reflective
        let rgb=mood.rgb
        let level=unit(brightness)*unit(0.09+energy*0.72+min(0.15,vocal.rms)+beat*0.16)
        let targets=[Double(rgb.red),Double(rgb.green),Double(rgb.blue)].map { $0*level }
        let deltas=zip(targets,color).map(-)
        let largest=deltas.map(abs).max() ?? 0
        let fraction=largest>0 ? min(1,5.5/largest) : 1
        for i in 0..<3 { color[i] += deltas[i]*fraction; color[i]=min(color[i],255*unit(brightness)) }
        light=LightState(color:.init(red:UInt8(color[0].rounded()),green:UInt8(color[1].rounded()),blue:UInt8(color[2].rounded())),energy:energy,beat:unit(beat),eyeOpening:unit(0.2+energy*0.6+vocal.rms),crown:currentCue?.scene == .climax ? energy : 0,stage:energy > 0.65 ? .climax : .melody)
        if !preview { manager.submitRhythmColor(light.color) }
    }

    func direct(using client: DirectorClient) async {
        guard !analyzing,!cues.isEmpty else { return };analyzing=true;defer { analyzing=false }
        let original=cues;let token=importGeneration
        do {
            let plan=try await client.plan(cues:original,bins:bins)
            guard token==importGeneration,cues==original else { return }
            cues=try PerformanceScore.apply(plan,to:original);saveSong();status="AI 情绪与歌词分镜已应用。"
        } catch { status=error.localizedDescription }
    }

    func review(using client: DirectorClient) async {
        guard !analyzing,!frames.isEmpty,!isSessionActive else { return };analyzing=true;defer { analyzing=false }
        let token=takeGeneration, samples=evidence, assessment=PracticeAssessment.evaluate(frames)
        do {
            let result=try await client.review(frames:samples,assessment:assessment,externalMusic:externalMusic,title:title)
            guard token==takeGeneration,!isSessionActive else { return }
            report=assessment.text+"\n\n"+result
        } catch {
            guard token==takeGeneration,!isSessionActive else { return }
            report=assessment.text+"\n\n"+VocalMetrics.report(frames)+"\n\n"+error.localizedDescription
        }
    }
    private func saveSong() {
        guard !preview,!externalMusic,let assetURL,assetURL.deletingLastPathComponent().standardizedFileURL == songDirectory.standardizedFileURL,
              let data=try? JSONEncoder().encode(SavedSong(file:assetURL.lastPathComponent,title:title,cues:cues)) else { return }
        UserDefaults.standard.set(data,forKey:"stage.song")
    }
}
