import AVFoundation
import Foundation

enum AudioCaptureEvent: Sendable {
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case routeChanged
    case configurationChanged
    case mediaServicesLost
    case mediaServicesReset
    case failed(String)
}

@MainActor
protocol RhythmAudioSource: AnyObject {
    func requestPermission(_ completion: @escaping @MainActor (Bool) -> Void)
    func start(onFeatures: @escaping @MainActor (AudioFeatures, Double) -> Void,
               onEvent: @escaping @MainActor (AudioCaptureEvent) -> Void) throws
    func pause(deactivateSession: Bool)
    func stop()
}

extension RhythmAudioSource {
    func pause() { pause(deactivateSession: false) }
}

private enum CaptureFailure: Error, LocalizedError {
    case unavailableInput
    var errorDescription: String? { "当前音频输入不可用，请检查麦克风或耳机后重试。" }
}

/// At most one copied PCM block or main-thread delivery is pending at any time.
private final class AudioProcessingGate: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.magiicccc.wanshoujian.audio-analysis", qos: .userInitiated)
    private var active = true
    private var busy = false
    private var analyzer = AudioFeatureAnalyzer()
    private var accumulatedDuration = 0.0

    func invalidate() { lock.lock(); active = false; lock.unlock() }
    private func isActive() -> Bool { lock.lock(); defer { lock.unlock() }; return active }
    private func finish() { lock.lock(); busy = false; lock.unlock() }

    func consume(_ buffer: AVAudioPCMBuffer, deliver: @escaping @MainActor (AudioFeatures, Double) -> Void) {
        lock.lock()
        guard active && !busy else { lock.unlock(); return }
        busy = true
        lock.unlock()
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else { finish(); return }
        let length = min(Int(buffer.frameLength), 8192)
        let channels = min(Int(buffer.format.channelCount), 4)
        guard channels > 0 else { finish(); return }
        let rate = buffer.format.sampleRate
        var samples = [Float](repeating: 0, count: length)
        for channel in 0..<channels {
            for index in 0..<length { samples[index] += channelData[channel][index] / Float(channels) }
        }
        let copiedSamples = samples
        queue.async { [self] in
            guard isActive() else { finish(); return }
            let features = analyzer.process(samples: copiedSamples, sampleRate: rate)
            accumulatedDuration += Double(length) / rate
            guard accumulatedDuration >= 0.05 else { finish(); return }
            let duration = accumulatedDuration
            accumulatedDuration = 0
            Task { @MainActor [self] in
                defer { self.finish() }
                guard self.isActive() else { return }
                deliver(features, duration)
            }
        }
    }
}

@MainActor
final class MicrophoneAudioSource: RhythmAudioSource {
    private var engine: AVAudioEngine?
    private var processing: AudioProcessingGate?
    private var observers: [NSObjectProtocol] = []
    private var configurationObserver: NSObjectProtocol?
    private var eventEpoch: UInt64 = 0
    private var engineEpoch: UInt64 = 0
    private var onEvent: (@MainActor (AudioCaptureEvent) -> Void)?

    func requestPermission(_ completion: @escaping @MainActor (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor in completion(granted) }
        }
    }

    func start(onFeatures: @escaping @MainActor (AudioFeatures, Double) -> Void,
               onEvent: @escaping @MainActor (AudioCaptureEvent) -> Void) throws {
        stopEngine()
        self.onEvent = onEvent
        let audio = AVAudioSession.sharedInstance()
        do {
            try audio.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
            try audio.setPreferredIOBufferDuration(0.02)
            try audio.setActive(true)
            installSessionObservers(audio)
            let created = AVAudioEngine()
            let input = created.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate.isFinite, format.sampleRate >= 8_000, format.channelCount > 0,
                  format.commonFormat == .pcmFormatFloat32, !format.isInterleaved else {
                throw CaptureFailure.unavailableInput
            }
            let processor = AudioProcessingGate()
            processing = processor
            engine = created
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                processor.consume(buffer, deliver: onFeatures)
            }
            created.prepare()
            try created.start()
            let token = engineEpoch
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: created, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.engineEpoch == token else { return }
                    self.onEvent?(.configurationChanged)
                }
            }
        } catch {
            stopEngine()
            try? audio.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
    }

    func pause(deactivateSession: Bool) {
        stopEngine()
        if deactivateSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func stop() {
        eventEpoch &+= 1
        onEvent = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        pause()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func stopEngine() {
        engineEpoch &+= 1
        processing?.invalidate(); processing = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
            engine.reset()
        }
        engine = nil
    }

    private func observe(_ name: Notification.Name, audio: AVAudioSession,
                         event: @escaping (Notification) -> AudioCaptureEvent?) {
        let token = eventEpoch
        observers.append(NotificationCenter.default.addObserver(forName: name, object: audio, queue: .main) { [weak self] notification in
            guard let event = event(notification) else { return }
            Task { @MainActor in
                guard let self, self.eventEpoch == token else { return }
                self.onEvent?(event)
            }
        })
    }

    private func installSessionObservers(_ audio: AVAudioSession) {
        guard observers.isEmpty else { return }
        observe(AVAudioSession.interruptionNotification, audio: audio) { notification in
            guard let number = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber,
                  let type = AVAudioSession.InterruptionType(rawValue: number.uintValue) else { return nil }
            if type == .began { return .interruptionBegan }
            let raw = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
            return .interruptionEnded(shouldResume: AVAudioSession.InterruptionOptions(rawValue: raw).contains(.shouldResume))
        }
        observe(AVAudioSession.routeChangeNotification, audio: audio) { notification in
            let raw = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue ?? 0
            guard let reason = AVAudioSession.RouteChangeReason(rawValue: raw), reason != .categoryChange else { return nil }
            return .routeChanged
        }
        observe(AVAudioSession.mediaServicesWereLostNotification, audio: audio) { _ in .mediaServicesLost }
        observe(AVAudioSession.mediaServicesWereResetNotification, audio: audio) { _ in .mediaServicesReset }
    }
}
