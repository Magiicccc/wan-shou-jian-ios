import XCTest
@testable import WanShouJian

final class AudioProcessingTests: XCTestCase {
    private func tone(_ frequency: Double, amplitude: Double, frame: Int) -> [Float] {
        (0..<800).map { Float(sin(Double(frame * 800 + $0) * 2 * .pi * frequency / 16_000) * amplitude) }
    }

    private func calibrated() -> AudioFeatureAnalyzer {
        var analyzer = AudioFeatureAnalyzer()
        for _ in 0..<42 { _ = analyzer.process(samples: [Float](repeating: 0, count: 800), sampleRate: 16_000) }
        return analyzer
    }

    func testTwoSecondCalibrationAndQuietFloor() {
        var analyzer = AudioFeatureAnalyzer()
        var result = AudioFeatures()
        for _ in 0..<30 { result = analyzer.process(samples: [Float](repeating: 0, count: 800), sampleRate: 16_000) }
        XCTAssertEqual(result.calibrationProgress, 0.75, accuracy: 0.001)
        XCTAssertFalse(result.hasSound)
        for _ in 0..<12 { result = analyzer.process(samples: [Float](repeating: 0, count: 800), sampleRate: 16_000) }
        XCTAssertEqual(result.calibrationProgress, 1)
        XCTAssertEqual(result.fastEnergy, 0)
        XCTAssertGreaterThan(result.noiseFloor, 0)
        analyzer.reset()
        XCTAssertLessThan(analyzer.process(samples: [0], sampleRate: 16_000).calibrationProgress, 0.01)
    }

    func testFrequencyBandsSeparateBassAndTreble() {
        var bass = calibrated(), treble = calibrated(), middle = calibrated()
        var low = AudioFeatures(), high = AudioFeatures(), mid = AudioFeatures()
        for frame in 0..<12 {
            low = bass.process(samples: tone(80, amplitude: 0.3, frame: frame), sampleRate: 16_000)
            mid = middle.process(samples: tone(900, amplitude: 0.3, frame: frame), sampleRate: 16_000)
            high = treble.process(samples: tone(5_000, amplitude: 0.3, frame: frame), sampleRate: 16_000)
        }
        XCTAssertGreaterThan(low.low, high.low * 4)
        XCTAssertGreaterThan(high.high, low.high * 3)
        XCTAssertGreaterThan(mid.mid, 0.4)
        XCTAssertTrue(low.hasSound)
    }

    func testStrongWeakAndSilenceRemainDistinct() {
        var weak = calibrated(), strong = calibrated()
        var quiet = AudioFeatures(), loud = AudioFeatures()
        for frame in 0..<60 {
            quiet = weak.process(samples: tone(500, amplitude: 0.015, frame: frame), sampleRate: 16_000)
            loud = strong.process(samples: tone(500, amplitude: 0.4, frame: frame), sampleRate: 16_000)
        }
        XCTAssertGreaterThan(loud.slowEnergy - quiet.slowEnergy, 0.5)
        for _ in 0..<80 { loud = strong.process(samples: [Float](repeating: 0, count: 800), sampleRate: 16_000) }
        XCTAssertFalse(loud.hasSound)
        XCTAssertLessThan(loud.fastEnergy, 0.01)
        XCTAssertLessThan(loud.slowEnergy, 0.02)
    }

    func testLowFrequencyAttackCreatesTransientThenSettles() {
        var analyzer = calibrated()
        let attack = analyzer.process(samples: tone(80, amplitude: 0.6, frame: 0), sampleRate: 16_000)
        var settled = attack
        for frame in 1..<50 { settled = analyzer.process(samples: tone(80, amplitude: 0.6, frame: frame), sampleRate: 16_000) }
        XCTAssertGreaterThan(attack.transient, 0.3)
        XCTAssertLessThan(settled.transient, attack.transient * 0.2)
    }

    func testInvalidSamplesAndRatesStayFinite() {
        var analyzer = calibrated()
        let output = analyzer.process(samples: [.nan, .infinity, -.infinity, 0], sampleRate: 16_000)
        XCTAssertTrue(output.rms.isFinite)
        XCTAssertTrue(output.fastEnergy.isFinite)
        XCTAssertEqual(analyzer.process(samples: [1], sampleRate: .nan), output)
        XCTAssertEqual(analyzer.process(samples: [], sampleRate: 16_000), output)
    }

    func testAntiFlashBoundsColorSlewAndBeatRate() {
        var engine = LightEffectEngine()
        let feature = AudioFeatures(rms: 0.3, low: 0.8, mid: 0.2, high: 0.1, fastEnergy: 0.8,
                                    slowEnergy: 0.8, transient: 0.8, noiseFloor: 0.002,
                                    calibrationProgress: 1, hasSound: true)
        var previous = LightState.idle
        var pulses = 0
        for _ in 0..<80 {
            let current = engine.update(feature, duration: 0.05, brightnessLimit: 0.4, antiFlash: true)
            if current.beat > previous.beat + 0.05 { pulses += 1 }
            let a = [previous.color.red, previous.color.green, previous.color.blue]
            let b = [current.color.red, current.color.green, current.color.blue]
            for index in 0..<3 {
                XCTAssertLessThanOrEqual(abs(Int(a[index]) - Int(b[index])), 6)
                XCTAssertLessThanOrEqual(Int(b[index]), 102)
            }
            previous = current
        }
        XCTAssertLessThanOrEqual(pulses, 8)
        XCTAssertGreaterThan(pulses, 2)
        XCTAssertEqual(previous.stage, .climax)
        XCTAssertGreaterThan(previous.crown, 0.5)
        XCTAssertEqual(engine.update(feature, duration: 0.05, brightnessLimit: 0).color, LightRGB(red: 0, green: 0, blue: 0))
    }

    func testStageHysteresisAndSilenceDecay() {
        var engine = LightEffectEngine()
        _ = engine.update(AudioFeatures(), duration: 0.05)
        var feature = AudioFeatures(fastEnergy: 0.4, slowEnergy: 0.4, calibrationProgress: 1, hasSound: true)
        XCTAssertEqual(engine.update(feature, duration: 0.05).stage, .melody)
        for index in 0..<20 {
            feature.slowEnergy = index.isMultiple(of: 2) ? 0.9 : 0.4
            feature.fastEnergy = feature.slowEnergy
            XCTAssertEqual(engine.update(feature, duration: 0.05).stage, .melody)
        }
        var result = LightState.idle
        for _ in 0..<100 { result = engine.update(AudioFeatures(calibrationProgress: 1), duration: 0.05) }
        XCTAssertEqual(result.stage, .idle)
        XCTAssertLessThan(result.energy, 0.01)
        XCTAssertLessThan(result.eyeOpening, 0.1)
    }

    func testSyntheticAudioExercisesRealAnalyzerAndEffectPipeline() {
        var generator = SyntheticRhythmAudio()
        var analyzer = AudioFeatureAnalyzer()
        var engine = LightEffectEngine()
        var stages = Set<String>()
        var sawBeat = false
        for _ in 0..<240 {
            let features = analyzer.process(samples: generator.nextFrame(), sampleRate: generator.sampleRate)
            let light = engine.update(features, duration: 0.05)
            stages.insert(light.stage.rawValue)
            sawBeat = sawBeat || light.beat > 0.1
        }
        XCTAssertTrue(stages.contains(LightStage.calibrating.rawValue))
        XCTAssertGreaterThan(stages.count, 2)
        XCTAssertTrue(sawBeat)
    }

    func testStagePaletteUsesSilverIceVioletAndChampagneGold() {
        XCTAssertEqual(LightStage.idle.palette, LightRGB(red: 178, green: 194, blue: 214))
        XCTAssertEqual(LightStage.melody.palette, LightRGB(red: 148, green: 207, blue: 255))
        XCTAssertEqual(LightStage.rhythm.palette, LightRGB(red: 164, green: 143, blue: 255))
        XCTAssertEqual(LightStage.climax.palette, LightRGB(red: 255, green: 211, blue: 142))
        XCTAssertEqual(LightStage.decay.palette, LightRGB(red: 150, green: 177, blue: 215))
        var engine = LightEffectEngine()
        let high = AudioFeatures(fastEnergy: 0.9, slowEnergy: 0.9, calibrationProgress: 1, hasSound: true)
        var light = LightState.idle
        for _ in 0..<160 { light = engine.update(high, duration: 0.05) }
        XCTAssertEqual(light.stage, .climax)
        let scale = Double(light.color.red) / 255
        XCTAssertEqual(Double(light.color.green), 211 * scale, accuracy: 1)
        XCTAssertEqual(Double(light.color.blue), 142 * scale, accuracy: 1)
    }

    func testSteadyMelodyBreathesWithBoundedSlopeAndIndependentBrightnessCap() {
        var engine = LightEffectEngine()
        let sustained = AudioFeatures(fastEnergy: 0.4, slowEnergy: 0.4, calibrationProgress: 1, hasSound: true)
        var levels: [Int] = []
        for index in 0..<300 {
            let light = engine.update(sustained, duration: 0.05, brightnessLimit: 0.55)
            if index > 100 { levels.append(Int(light.color.blue)); XCTAssertEqual(light.stage, .melody) }
        }
        XCTAssertGreaterThan(levels.max()! - levels.min()!, 10)
        for index in 1..<levels.count { XCTAssertLessThanOrEqual(abs(levels[index] - levels[index - 1]), 2) }
        for _ in 0..<80 {
            XCTAssertEqual(engine.update(sustained, duration: 0.05, brightnessLimit: 0).color,
                           LightRGB(red: 0, green: 0, blue: 0))
        }
    }

    func testSilenceKeepsSlowLowLevelBreathing() {
        var engine = LightEffectEngine()
        let silence = AudioFeatures(calibrationProgress: 1)
        var levels: [Int] = []
        for index in 0..<240 {
            let light = engine.update(silence, duration: 0.05)
            XCTAssertEqual(light.stage, .idle)
            XCTAssertLessThanOrEqual(light.color.blue, 5)
            if index > 30 { levels.append(Int(light.color.blue)) }
        }
        XCTAssertGreaterThan(levels.max()! - levels.min()!, 1)
        XCTAssertGreaterThan(levels.min()!, 0)
        XCTAssertEqual(LightStage.idle.breathingPeriod, 5)
        XCTAssertEqual(LightStage.melody.breathingPeriod, 3.5)
        XCTAssertEqual(LightStage.rhythm.breathingPeriod, 2)
    }
}
