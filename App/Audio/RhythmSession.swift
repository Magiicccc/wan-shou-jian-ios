import Combine
import CoreFoundation
import Foundation

enum RhythmPhase: String {
    case idle = "待机", requestingPermission = "等待授权", calibrating = "环境校准"
    case listening = "正在聆听", interrupted = "音频中断", recovering = "恢复声音"
    case paused = "已暂停", failed = "等待重试", preview = "合成试听"
}

@MainActor
final class RhythmSession: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var phase: RhythmPhase = .idle
    @Published private(set) var message = "开启后使用麦克风感知音乐，先进行两秒环境校准。"
    @Published private(set) var light = LightState.idle
    @Published private(set) var features = AudioFeatures()
    @Published var intensity: Double = 1 {
        didSet {
            let validated = Self.sanitize(intensity, in: 0.3...2, fallback: 1)
            if intensity != validated { intensity = validated }
            preferences.set(validated, forKey: "rhythm.intensity")
        }
    }
    @Published var brightnessLimit: Double = 0.55 {
        didSet {
            let validated = Self.sanitize(brightnessLimit, in: 0...1, fallback: 0.55)
            if brightnessLimit != validated { brightnessLimit = validated }
            preferences.set(validated, forKey: "rhythm.brightnessLimit")
        }
    }
    @Published var antiFlash = true {
        didSet { preferences.set(antiFlash, forKey: "rhythm.antiFlash") }
    }
    @Published var backgroundEnabled = true {
        didSet {
            preferences.set(backgroundEnabled, forKey: "rhythm.backgroundEnabled")
            lifecycle.backgroundEnabled = backgroundEnabled
            if !synthetic { manager.setBackgroundRhythmEnabled(backgroundEnabled) }
            if lifecycle.isBackground { sceneChanged(isBackground: true) }
        }
    }

    private let manager: LightstickManager
    private let preview: Bool
    private let preferences: UserDefaults
    private var source: RhythmAudioSource?
    private var lifecycle = RhythmLifecycle()
    private var engine = LightEffectEngine()
    private var lastState = LightState.idle
    private var synthetic = false
    private var permissionGranted = false
    private var eventIntent: UInt64 = 0
    private var hasSubmittedToManager = false
    private var previewTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var connectionObserver: AnyCancellable?
    private var submittedColorObserver: AnyCancellable?
    private var recentSubmittedColor: LightRGB?
    private let recoveryDelayNanoseconds: UInt64

    init(manager: LightstickManager, preview: Bool = false, source: RhythmAudioSource? = nil,
         recoveryDelayNanoseconds: UInt64 = 400_000_000, preferences: UserDefaults = .standard) {
        self.manager = manager
        self.preview = preview
        self.preferences = preferences
        self.source = source
        self.synthetic = preview
        self.recoveryDelayNanoseconds = recoveryDelayNanoseconds
        _intensity = Published(initialValue: Self.readNumber(preferences, key: "rhythm.intensity", in: 0.3...2, fallback: 1))
        _brightnessLimit = Published(initialValue: Self.readNumber(preferences, key: "rhythm.brightnessLimit", in: 0...1, fallback: 0.55))
        _antiFlash = Published(initialValue: Self.readBoolean(preferences, key: "rhythm.antiFlash", fallback: true))
        _backgroundEnabled = Published(initialValue: Self.readBoolean(preferences, key: "rhythm.backgroundEnabled", fallback: true))
        lifecycle.backgroundEnabled = backgroundEnabled
        recentSubmittedColor = manager.lastRhythmColor
        connectionObserver = manager.$phase.sink { [weak self] phase in
            guard let self else { return }
            self.refreshPresentation(isReady: phase == .ready)
        }
        submittedColorObserver = manager.$lastRhythmColor.sink { [weak self] color in
            guard let self else { return }
            self.recentSubmittedColor = color
            self.refreshPresentation()
        }
    }

    deinit {
        previewTask?.cancel()
        recoveryTask?.cancel()
        let capture = source
        Task { @MainActor in capture?.stop() }
    }

    func start() {
        if preview { startPreview(); return }
        guard !isRunning, phase != .requestingPermission else { return }
        stopResources(sendBlack: true)
        synthetic = false
        permissionGranted = false
        lifecycle.begin()
        let permissionIntent = eventIntent
        lifecycle.backgroundEnabled = backgroundEnabled
        manager.setBackgroundRhythmEnabled(backgroundEnabled)
        phase = .requestingPermission
        message = "请允许麦克风权限，声音数据在内存中分析。"
        if source == nil { source = MicrophoneAudioSource() }
        source?.requestPermission { [weak self] granted in
            guard let self, self.eventIntent == permissionIntent, self.lifecycle.wantsRunning else { return }
            guard granted else { self.fail("请在系统设置中允许麦克风权限后重新开启。"); return }
            self.permissionGranted = true
            guard self.lifecycle.canRun else { self.phase = .paused; return }
            self.startCapture()
        }
    }

    func startPreview() {
        stopResources(sendBlack: true)
        synthetic = true
        let token = lifecycle.begin()
        lifecycle.backgroundEnabled = backgroundEnabled
        engine.reset(); lastState = .idle; features = AudioFeatures()
        isRunning = true; phase = .preview
        message = "合成试听已开启，使用本机合成信号预览灯效。"
        previewTask = Task { [weak self] in
            var generator = SyntheticRhythmAudio()
            var analyzer = AudioFeatureAnalyzer()
            while !Task.isCancelled {
                guard self?.lifecycle.accepts(token) == true else { return }
                let values = analyzer.process(samples: generator.nextFrame(), sampleRate: generator.sampleRate)
                self?.receive(values, duration: 0.05, token: token)
                do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
            }
        }
    }

    func stop() {
        lifecycle.stop()
        stopResources(sendBlack: true, clearPersistedIntent: true)
        phase = .idle
        message = "律动已停止，麦克风与待发送灯效已释放。"
    }

    func recalibrate() {
        guard lifecycle.wantsRunning else { return }
        if synthetic { startPreview(); return }
        scheduleRecovery(message: "重新进行两秒环境校准，请暂时保持环境安静。")
    }

    func sceneChanged(isBackground: Bool) {
        lifecycle.isBackground = isBackground
        lifecycle.backgroundEnabled = backgroundEnabled
        guard lifecycle.wantsRunning else { return }
        if isBackground && (synthetic || !backgroundEnabled) {
            lifecycle.invalidate()
            previewTask?.cancel(); previewTask = nil
            recoveryTask?.cancel(); recoveryTask = nil
            // Keep interruption-end observers while releasing the engine and microphone.
            source?.pause(deactivateSession: !lifecycle.interrupted)
            if !synthetic && hasSubmittedToManager { manager.endRhythm(sendBlack: true) }
            hasSubmittedToManager = false
            isRunning = false; light = .idle; lastState = .idle
            phase = .paused
            message = "声音已暂停，回到前台后继续已开启的会话。"
        } else if !isBackground && lifecycle.canRun && !isRunning && phase != .requestingPermission {
            if synthetic { startPreview() }
            else if permissionGranted { scheduleRecovery(message: "正在恢复前台声音。") }
        }
    }

    private func startCapture() {
        guard lifecycle.canRun, permissionGranted, let source else { return }
        let token = lifecycle.invalidate()
        let intent = eventIntent
        engine.reset(); lastState = .idle; light = .idle; features = AudioFeatures()
        do {
            try source.start(onFeatures: { [weak self] values, duration in
                self?.receive(values, duration: duration, token: token)
            }, onEvent: { [weak self] event in
                guard let self, self.eventIntent == intent, self.lifecycle.wantsRunning else { return }
                self.handle(event)
            })
            guard lifecycle.accepts(token) else { source.pause(); return }
            isRunning = true
            phase = .calibrating
            message = "正在进行两秒环境校准，请暂时保持环境安静。"
            manager.submitRhythmColor(LightState.idle.color)
            hasSubmittedToManager = true
        } catch {
            fail("麦克风启动失败，请检查音频占用或耳机连接后重试。")
        }
    }

    private func receive(_ values: AudioFeatures, duration: Double, token: UInt64) {
        guard lifecycle.accepts(token), isRunning else { return }
        features = values
        let state = engine.update(values, duration: duration, intensity: intensity,
                                  brightnessLimit: brightnessLimit, antiFlash: antiFlash)
        lastState = state
        if !synthetic {
            phase = values.calibrationProgress < 1 ? .calibrating : .listening
            if values.calibrationProgress >= 1 {
                message = values.hasSound ? "正在跟随声音。设备就绪后实时提交光色。" : "正在聆听，安静时保持柔和底光。"
            }
            manager.submitRhythmColor(state.color)
            hasSubmittedToManager = true
        }
        refreshPresentation()
    }

    private func refreshPresentation(isReady: Bool? = nil) {
        if synthetic { light = lastState; return }
        var submitted = lastState
        // Features stay responsive; the rendered RGB advances only with actual BLE submissions.
        submitted.color = recentSubmittedColor ?? LightState.idle.color
        light = (isReady ?? manager.canControl) ? submitted : submitted.disconnected
    }

    private func handle(_ event: AudioCaptureEvent) {
        switch event {
        case .interruptionBegan:
            lifecycle.interrupt()
            suspendCapture()
            phase = .interrupted
            message = "声音会话被系统中断，等待系统允许恢复。"
        case .interruptionEnded(let shouldResume):
            guard lifecycle.interrupted else { return }
            lifecycle.endInterruption(shouldResume: shouldResume)
            if lifecycle.canRun { scheduleRecovery(message: "中断已结束，正在恢复声音。") }
            else { phase = .paused; message = "音频已暂停，可点击开启重新聆听。" }
        case .routeChanged, .configurationChanged:
            guard !lifecycle.interrupted, lifecycle.canRun else { return }
            scheduleRecovery(message: "音频路由已变化，正在重新校准输入。")
        case .mediaServicesLost:
            lifecycle.mediaLost(); suspendCapture()
            phase = .interrupted; message = "系统音频服务正在恢复。"
        case .mediaServicesReset:
            eventIntent &+= 1
            lifecycle.mediaReset()
            lifecycle.invalidate()
            suspendCapture()
            if hasSubmittedToManager { manager.endRhythm(sendBlack: true) }
            hasSubmittedToManager = false
            source?.stop()
            phase = .paused
            message = "系统音频服务已重置，点击开启后重建麦克风会话。"
        case .failed(let reason): fail(reason)
        }
    }

    private func scheduleRecovery(message: String) {
        guard lifecycle.wantsRunning else { return }
        let token = lifecycle.invalidate()
        suspendCapture()
        phase = .recovering; self.message = message
        let delay = recoveryDelayNanoseconds
        recoveryTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self, self.lifecycle.accepts(token) else { return }
            self.startCapture()
        }
    }

    private func suspendCapture() {
        recoveryTask?.cancel(); recoveryTask = nil
        source?.pause()
        // Temporary audio pauses keep the selected BLE session's existing user intent.
        if !synthetic && hasSubmittedToManager { manager.submitRhythmColor(LightState.idle.color) }
        isRunning = false; light = .idle; lastState = .idle
    }

    private func stopResources(sendBlack: Bool, clearPersistedIntent: Bool = false) {
        eventIntent &+= 1
        lifecycle.invalidate()
        previewTask?.cancel(); previewTask = nil
        recoveryTask?.cancel(); recoveryTask = nil
        source?.stop()
        if !synthetic && (hasSubmittedToManager || clearPersistedIntent) { manager.endRhythm(sendBlack: sendBlack) }
        hasSubmittedToManager = false
        engine.reset(); lastState = .idle; light = .idle; features = AudioFeatures()
        isRunning = false
    }

    private func fail(_ reason: String) {
        lifecycle.stop()
        stopResources(sendBlack: true, clearPersistedIntent: true)
        phase = .failed; message = reason
    }

    private static func sanitize(_ value: Double, in range: ClosedRange<Double>, fallback: Double) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : fallback
    }

    private static func readNumber(_ preferences: UserDefaults, key: String,
                                   in range: ClosedRange<Double>, fallback: Double) -> Double {
        guard let number = preferences.object(forKey: key) as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return fallback }
        let value = number.doubleValue
        return value.isFinite && range.contains(value) ? value : fallback
    }

    private static func readBoolean(_ preferences: UserDefaults, key: String, fallback: Bool) -> Bool {
        guard let number = preferences.object(forKey: key) as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return fallback }
        return number.boolValue
    }
}
