import Foundation

enum LightStage: String, CaseIterable {
    case idle = "待机", calibrating = "校准", melody = "旋律"
    case rhythm = "节奏", climax = "高潮", decay = "回落"

    var palette: LightRGB {
        switch self {
        case .idle: return LightRGB(red: 12, green: 65, blue: 214)
        case .calibrating: return LightRGB(red: 24, green: 112, blue: 234)
        case .melody: return LightRGB(red: 12, green: 112, blue: 255)
        case .rhythm: return LightRGB(red: 150, green: 16, blue: 255)
        case .climax: return LightRGB(red: 255, green: 120, blue: 8)
        case .decay: return LightRGB(red: 16, green: 78, blue: 215)
        }
    }

    var breathingPeriod: Double {
        switch self {
        case .idle, .calibrating, .decay: return 5
        case .melody: return 3.5
        case .rhythm, .climax: return 2
        }
    }
}

struct LightState: Equatable {
    var color = LightRGB(red: 0, green: 0, blue: 0)
    var energy: Double = 0
    var beat: Double = 0
    var eyeOpening: Double = 0.08
    var crown: Double = 0
    var stage: LightStage = .idle
    static let idle = LightState()

    var disconnected: LightState {
        var copy = self
        copy.color = color.scaled(brightness: 0.12)
        copy.energy *= 0.2
        copy.eyeOpening *= 0.25
        copy.crown = 0
        return copy
    }
}

struct LightEffectEngine {
    private(set) var state = LightState.idle
    private var time = 0.0
    private var lastBeat = -100.0
    private var beatTimes: [Double] = []
    private var candidate: LightStage = .idle
    private var candidateTime = 0.0
    private var colorChannels = [0.0, 0.0, 0.0]
    private var level = 0.0
    private var breathingPhase = 0.0

    mutating func reset() { self = LightEffectEngine() }

    mutating func update(_ features: AudioFeatures, duration: Double, intensity: Double = 1,
                         brightnessLimit: Double = 0.55, antiFlash: Bool = true) -> LightState {
        let dt = duration.isFinite ? min(0.2, max(0.001, duration)) : 0.05
        time += dt
        let gain = intensity.isFinite ? min(2, max(0.3, intensity)) : 1
        let limit = unit(brightnessLimit)
        let calibrating = features.calibrationProgress < 1
        let energy = calibrating ? 0 : unit(features.slowEnergy * gain)
        state.energy = follow(state.energy, energy, dt, 0.24)
        state.beat *= exp(-dt / 0.28)
        if !calibrating, features.hasSound, features.transient * gain > 0.13,
           time - lastBeat >= (antiFlash ? 0.5 : 0.25) {
            state.beat = unit(features.transient * gain)
            lastBeat = time
            beatTimes.append(time)
        }
        beatTimes.removeAll { time - $0 > 2 }
        let next: LightStage
        if calibrating { next = .calibrating }
        else if !features.hasSound { next = state.energy > 0.06 ? .decay : .idle }
        else if features.fastEnergy < features.slowEnergy * 0.55 { next = .decay }
        else if energy > 0.68 { next = .climax }
        else if beatTimes.count >= 3 { next = .rhythm }
        else { next = .melody }
        if next != candidate { candidate = next; candidateTime = 0 }
        candidateTime += dt
        if calibrating || state.stage == .calibrating || candidateTime >= (next == .climax ? 1 : 0.4) {
            state.stage = next
        }

        let tint = state.stage.palette
        let palette = [Double(tint.red), Double(tint.green), Double(tint.blue)]
        // Integrating phase keeps a continuous breath when musical stages change tempo.
        breathingPhase = (breathingPhase + dt * 2 * .pi / state.stage.breathingPeriod).truncatingRemainder(dividingBy: 2 * .pi)
        let breath = sin(breathingPhase) * (0.012 + state.energy * 0.09)
        let targetLevel = calibrating ? 0 : unit(0.025 + state.energy * 0.78 + breath + state.beat * (antiFlash ? 0.08 : 0.16)) * limit
        // Slew limits bound contrast changes even when the input contains abrupt transients.
        let speed = targetLevel > level ? (antiFlash ? 0.7 : 1.5) : 0.9
        level += min(speed * dt, max(-speed * dt, targetLevel - level))
        level = min(level, limit)
        let deltas = (0..<3).map { palette[$0] * level - colorChannels[$0] }
        let largestDelta = deltas.map { abs($0) }.max() ?? 0
        let step = (antiFlash ? 110.0 : 260.0) * dt
        // A shared interpolation fraction preserves RGB ratios when rising from black.
        let fraction = largestDelta > 0 ? min(1, step / largestDelta) : 1
        for index in 0..<3 {
            colorChannels[index] += deltas[index] * fraction
            colorChannels[index] = min(colorChannels[index], 255 * limit)
        }
        if calibrating || limit == 0 { colorChannels = [0, 0, 0] }
        state.color = LightRGB(red: UInt8(colorChannels[0].rounded()), green: UInt8(colorChannels[1].rounded()), blue: UInt8(colorChannels[2].rounded()))
        state.eyeOpening = follow(state.eyeOpening, calibrating ? 0.12 : 0.08 + state.energy * 0.88, dt, 0.3)
        let crown = state.stage == .climax ? state.energy : (state.stage == .rhythm ? state.energy * 0.4 : 0)
        state.crown = follow(state.crown, crown, dt, 0.5)
        return state
    }
}

struct RhythmLifecycle {
    private(set) var generation: UInt64 = 0
    private(set) var wantsRunning = false
    private(set) var interrupted = false
    private(set) var resumeAllowed = true
    private(set) var mediaAvailable = true
    var isBackground = false
    var backgroundEnabled = true
    var canRun: Bool { wantsRunning && !interrupted && resumeAllowed && mediaAvailable && (!isBackground || backgroundEnabled) }

    @discardableResult mutating func begin() -> UInt64 {
        generation &+= 1; wantsRunning = true; interrupted = false; resumeAllowed = true; mediaAvailable = true
        return generation
    }
    mutating func stop() { generation &+= 1; wantsRunning = false; resumeAllowed = false }
    @discardableResult mutating func invalidate() -> UInt64 { generation &+= 1; return generation }
    mutating func interrupt() { invalidate(); interrupted = true }
    mutating func endInterruption(shouldResume: Bool) { interrupted = false; resumeAllowed = shouldResume }
    mutating func mediaLost() { invalidate(); mediaAvailable = false }
    mutating func mediaReset() { mediaAvailable = true; resumeAllowed = false }
    func accepts(_ token: UInt64) -> Bool { token == generation && canRun }
}
