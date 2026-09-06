import Foundation

struct LightRGB: Equatable, Codable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    init(red: UInt8, green: UInt8, blue: UInt8) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    func scaled(brightness: Double) -> LightRGB {
        let level = brightness.isFinite ? min(1, max(0, brightness)) : 0
        func channel(_ value: UInt8) -> UInt8 {
            UInt8((Double(value) * level).rounded(.toNearestOrAwayFromZero))
        }
        return LightRGB(red: channel(red), green: channel(green), blue: channel(blue))
    }

    var hex: String {
        String(format: "#%02X%02X%02X", Int(red), Int(green), Int(blue))
    }

    static func parse(hex: String) -> LightRGB? {
        let bytes = Array(hex.utf8)
        guard bytes.count == 7, bytes[0] == 0x23 else { return nil }
        func nibble(_ byte: UInt8) -> UInt8? {
            switch byte {
            case 0x30...0x39: return byte - 0x30
            case 0x41...0x46: return byte - 0x41 + 10
            case 0x61...0x66: return byte - 0x61 + 10
            default: return nil
            }
        }
        var channels = [UInt8]()
        for offset in stride(from: 1, to: 7, by: 2) {
            guard let high = nibble(bytes[offset]), let low = nibble(bytes[offset + 1]) else {
                return nil
            }
            channels.append((high << 4) | low)
        }
        return LightRGB(red: channels[0], green: channels[1], blue: channels[2])
    }
}

/// Wire formats observed on firmware v0.20.14. Transport owns randomness and response verification.
enum LightstickProtocol {
    static let lightingService = "0000ffe0-0000-1000-8000-00805f9b34fb"
    static let colorWrite = "0000ffe1-0000-1000-8000-00805f9b34fb"
    static let compatibilityService = "ac1f3d00-61a7-4824-a645-045b11d22d73"
    static let challengeWrite = "ac1f3d01-61a7-4824-a645-045b11d22d73"
    static let challengeResponseRead = "ac1f3d0a-61a7-4824-a645-045b11d22d73"
    static let macRead = "ac1f3d07-61a7-4824-a645-045b11d22d73"
    static let firmwareRead = "ac1f3d02-61a7-4824-a645-045b11d22d73"

    enum EncodingError: Error, Equatable, LocalizedError {
        case invalidMACLength(Int)
        case invalidNonceLength(Int)

        var errorDescription: String? {
            switch self {
            case .invalidMACLength(let length):
                return "设备地址需要 6 字节，当前收到 \(length) 字节。"
            case .invalidNonceLength(let length):
                return "设备确认随机数需要 16 字节，当前收到 \(length) 字节。"
            }
        }
    }

    /// CRC-32/ISO-HDLC: reflected polynomial 0xEDB88320, initial/final XOR 0xFFFFFFFF.
    static func crc32(_ bytes: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in bytes {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xEDB88320 : 0)
            }
        }
        return crc ^ 0xFFFFFFFF
    }

    /// MAC is the original six-byte 3D07 value; the caller supplies a fresh secure 16-byte nonce.
    static func challenge(mac: Data, nonce: Data) throws -> Data {
        guard mac.count == 6 else { throw EncodingError.invalidMACLength(mac.count) }
        guard nonce.count == 16 else { throw EncodingError.invalidNonceLength(nonce.count) }
        var body = littleEndian(0)
        body.append(contentsOf: [0xF0, 0x1D, 0xF5])
        body.append(mac)
        body.append(contentsOf: [0x00, 0x00, 0xFF, 0x00, 0x00, 0x00])
        body.append(nonce)
        return appendingCRC(to: body)
    }

    static func solid(sequence: UInt32, rgb: LightRGB) -> Data {
        var body = littleEndian(sequence)
        body.append(contentsOf: [0x00, rgb.red, rgb.green, rgb.blue])
        return appendingCRC(to: body)
    }

    static func displayMAC(_ bytes: Data) throws -> String {
        guard bytes.count == 6 else { throw EncodingError.invalidMACLength(bytes.count) }
        return bytes.reversed().map { String(format: "%02X", Int($0)) }.joined(separator: ":")
    }

    private static func appendingCRC(to body: Data) -> Data {
        var packet = body
        packet.append(littleEndian(crc32(body)))
        return packet
    }

    private static func littleEndian(_ value: UInt32) -> Data {
        Data([
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 24),
        ])
    }
}
