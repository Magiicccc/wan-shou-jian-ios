import Foundation

struct AudioFeatures: Equatable, Sendable {
    var rms: Double = 0
    var low: Double = 0
    var mid: Double = 0
    var high: Double = 0
    var fastEnergy: Double = 0
    var slowEnergy: Double = 0
    var transient: Double = 0
    var noiseFloor: Double = 0.002
    var calibrationProgress: Double = 0
    var hasSound = false
}

/// Streaming, DC-rejected three-band envelopes. PCM is consumed and never retained.
struct AudioFeatureAnalyzer {
    private var elapsed: Double = 0
    private var calibrationLevels: [Double] = []
    private var dc: Double = 0
    private var bass: Double = 0
    private var body: Double = 0
    private var slowBass: Double = 0
    private var silenceTime: Double = 0
    private var state = AudioFeatures()

    mutating func reset() { self = AudioFeatureAnalyzer() }

    mutating func process(samples: [Float], sampleRate: Double) -> AudioFeatures {
        guard sampleRate.isFinite, sampleRate >= 8_000, !samples.isEmpty else { return state }
        let duration = Double(samples.count) / sampleRate
        let dcAlpha = 1 - exp(-2 * .pi * 25 / sampleRate)
        let bassAlpha = 1 - exp(-2 * .pi * 180 / sampleRate)
        let bodyAlpha = 1 - exp(-2 * .pi * 2_500 / sampleRate)
        var fullPower = 0.0, lowPower = 0.0, midPower = 0.0, highPower = 0.0
        for value in samples {
            let sample = value.isFinite ? min(1, max(-1, Double(value))) : 0
            dc += dcAlpha * (sample - dc)
            let clean = sample - dc
            bass += bassAlpha * (clean - bass)
            body += bodyAlpha * (clean - body)
            fullPower += clean * clean
            lowPower += bass * bass
            midPower += (body - bass) * (body - bass)
            highPower += (clean - body) * (clean - body)
        }
        let count = Double(samples.count)
        let rms = sqrt(fullPower / count)
        let lowRMS = sqrt(lowPower / count)
        state.rms = rms
        state.low = unit(lowRMS / max(rms, 0.00001))
        state.mid = unit(sqrt(midPower / count) / max(rms, 0.00001))
        state.high = unit(sqrt(highPower / count) / max(rms, 0.00001))
        elapsed += duration
        state.calibrationProgress = unit(elapsed / 2)
        if state.calibrationProgress < 1 {
            calibrationLevels.append(rms)
            state.hasSound = false
            return state
        }
        if !calibrationLevels.isEmpty {
            calibrationLevels.sort()
            let quiet = calibrationLevels[calibrationLevels.count / 4]
            state.noiseFloor = min(0.035, max(0.0015, quiet * 1.5))
            calibrationLevels.removeAll(keepingCapacity: false)
        }
        let target = unit(sqrt(max(0, rms - state.noiseFloor) / 0.22))
        state.fastEnergy = follow(state.fastEnergy, target, duration, target > state.fastEnergy ? 0.045 : 0.22)
        state.slowEnergy = follow(state.slowEnergy, target, duration, 0.8)
        state.transient = unit((lowRMS - slowBass * 1.5 - state.noiseFloor) * 9)
        slowBass = follow(slowBass, lowRMS, duration, 0.35)
        if rms > state.noiseFloor * 1.8 {
            state.hasSound = true
            silenceTime = 0
        } else if rms < state.noiseFloor * 1.25 {
            silenceTime += duration
            if silenceTime >= 0.6 { state.hasSound = false }
        }
        return state
    }
}

func unit(_ value: Double) -> Double { value.isFinite ? min(1, max(0, value)) : 0 }
func follow(_ previous: Double, _ target: Double, _ duration: Double, _ time: Double) -> Double {
    previous + (target - previous) * (1 - exp(-max(0, duration) / max(0.001, time)))
}

struct SyntheticRhythmAudio {
    private var cursor = 0
    let sampleRate = 16_000.0

    mutating func nextFrame(count: Int = 800) -> [Float] {
        let values = (0..<count).map { offset -> Float in
            let time = Double(cursor + offset) / sampleRate
            guard time >= 2 else { return 0 }
            let songTime = time - 2
            let kick = exp(-songTime.truncatingRemainder(dividingBy: 0.5) * 24)
            let swell = 0.06 + 0.09 * (1 + sin(songTime * 0.5))
            return Float(sin(time * 2 * .pi * 85) * kick * 0.32 + sin(time * 2 * .pi * 520) * swell)
        }
        cursor += count
        return values
    }
}
