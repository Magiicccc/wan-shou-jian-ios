import AVFoundation

@MainActor
enum HomeAudioRouting {
    static let captureOptions: AVAudioSession.CategoryOptions = [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP]

    static func activate(capture: Bool) throws {
        let session = AVAudioSession.sharedInstance()
        let category: AVAudioSession.Category = capture ? .playAndRecord : .playback
        let options: AVAudioSession.CategoryOptions = capture ? captureOptions : [.mixWithOthers]
        // Reapplying an unchanged category can itself produce route notifications.
        if session.category != category || session.mode != .default || session.categoryOptions != options {
            try session.setCategory(category, mode: .default, options: options)
        }
        try session.setActive(true)
        if capture, let mic = session.availableInputs?.first(where: { $0.portType == .builtInMic }),
           session.currentRoute.inputs.first?.uid != mic.uid {
            try session.setPreferredInput(mic)
        }
    }

    static var summary: String {
        let route = AVAudioSession.sharedInstance().currentRoute
        let input = route.inputs.map(\.portName).joined(separator: "、")
        let output = route.outputs.map(\.portName).joined(separator: "、")
        return "收音：\(input.isEmpty ? "等待麦克风" : input) · 播放：\(output.isEmpty ? "系统选择" : output)"
    }
}
