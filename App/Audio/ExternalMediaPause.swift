import Darwin
import Foundation

enum MediaPauseResult: Equatable {
    case idle, preview, unavailable, rejected, submitted

    var message: String {
        switch self {
        case .idle: return "实验性媒体暂停 · 点击暂停时向当前音乐播放器发送请求。"
        case .preview: return "界面演示：已跳过系统媒体请求。"
        case .unavailable: return "当前系统未开放媒体暂停入口，请在控制中心暂停音乐。"
        case .rejected: return "系统返回暂停请求失败，请在控制中心暂停音乐。"
        case .submitted: return "暂停请求已提交，请确认音乐是否停止。"
        }
    }
}

@MainActor
enum ExternalMediaPause {
    // Theos MediaRemote.h declares an enum (int) and a Boolean (unsigned char).
    // https://github.com/theos/headers/blob/master/MediaRemote/MediaRemote.h
    private typealias SendCommand = @convention(c) (Int32, CFDictionary?) -> UInt8
    static let pauseCommand: Int32 = 1

    // Keep the image loaded for the process lifetime, including async XPC delivery.
    private static let handle = dlopen(
        "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
        RTLD_LAZY | RTLD_LOCAL
    )

    static func send(preview: Bool) -> MediaPauseResult {
        guard !preview else { return .preview }
        #if targetEnvironment(simulator)
        return .unavailable
        #else
        guard let handle, let symbol = dlsym(handle, "MRMediaRemoteSendCommand") else {
            return .unavailable
        }
        let send = unsafeBitCast(symbol, to: SendCommand.self)
        // An accepted request is not a playback-state acknowledgement.
        return send(pauseCommand, nil) != 0 ? .submitted : .rejected
        #endif
    }
}
