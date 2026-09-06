import Foundation
import XCTest
@testable import WanShouJian

final class LightstickProtocolTests: XCTestCase {
    // Synthetic locally administered address: 02:11:22:33:44:55.
    private let mac = Data([0x55, 0x44, 0x33, 0x22, 0x11, 0x02])

    func testRGBParsesSixHexDigitsAndFormatsUppercase() {
        let rgb = LightRGB(red: 0x01, green: 0xAB, blue: 0xEF)
        XCTAssertEqual(rgb.hex, "#01ABEF")
        XCTAssertEqual(LightRGB.parse(hex: "#01abef"), rgb)
        XCTAssertEqual(LightRGB.parse(hex: "#01AbEf"), rgb)
        XCTAssertEqual(LightRGB.parse(hex: rgb.hex), rgb)
        XCTAssertEqual(LightRGB.parse(hex: "#000000"), LightRGB(red: 0, green: 0, blue: 0))
        XCTAssertEqual(LightRGB.parse(hex: "#FFFFFF"), LightRGB(red: 255, green: 255, blue: 255))
    }

    func testRGBParsingRequiresCompleteASCIIHexInput() {
        for invalid in ["", "#", "#abc", "010203", "#00000000", "#GG0000", "#01+203",
                        " #010203", "#010203 ", "#010203\n", "#01020\0", "＃010203", "#００００００"] {
            XCTAssertNil(LightRGB.parse(hex: invalid), "Input: \(invalid.debugDescription)")
        }
    }

    func testQuarterBrightnessMatchesObservedGreenChannel() {
        let original = LightRGB(red: 0, green: 255, blue: 0)
        XCTAssertEqual(original.scaled(brightness: 0.25), LightRGB(red: 0, green: 64, blue: 0))
        XCTAssertEqual(original.green, 255)
        XCTAssertEqual(
            hex(LightstickProtocol.solid(sequence: 1, rgb: original.scaled(brightness: 0.25))),
            "0100000000004000f290f159"
        )
    }

    func testBrightnessClampsFiniteValuesAndRoundsHalfUp() {
        let rgb = LightRGB(red: 1, green: 127, blue: 255)
        XCTAssertEqual(rgb.scaled(brightness: 0.5), LightRGB(red: 1, green: 64, blue: 128))
        XCTAssertEqual(rgb.scaled(brightness: -0.5), LightRGB(red: 0, green: 0, blue: 0))
        XCTAssertEqual(rgb.scaled(brightness: 0), LightRGB(red: 0, green: 0, blue: 0))
        XCTAssertEqual(rgb.scaled(brightness: 1), rgb)
        XCTAssertEqual(rgb.scaled(brightness: 2), rgb)
    }

    func testNonFiniteBrightnessFallsBackToZero() {
        let rgb = LightRGB(red: 255, green: 255, blue: 255)
        for value in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertEqual(rgb.scaled(brightness: value), LightRGB(red: 0, green: 0, blue: 0))
        }
    }

    func testRGBCodablePreservesChannelsAndValidatesUInt8Range() throws {
        let rgb = LightRGB(red: 0, green: 64, blue: 255)
        XCTAssertEqual(try JSONDecoder().decode(LightRGB.self, from: JSONEncoder().encode(rgb)), rgb)
        for invalid in ["{\"red\":256,\"green\":0,\"blue\":0}",
                        "{\"red\":-1,\"green\":0,\"blue\":0}",
                        "{\"red\":0.5,\"green\":0,\"blue\":0}"] {
            XCTAssertThrowsError(try JSONDecoder().decode(LightRGB.self, from: Data(invalid.utf8)))
        }
    }

    func testCRCMatchesISOHDLCCheckValuesAndDataSlices() {
        XCTAssertEqual(LightstickProtocol.crc32(Data()), 0)
        XCTAssertEqual(LightstickProtocol.crc32(Data("123456789".utf8)), 0xCBF43926)
        let backing = data("ff313233343536373839ee")
        XCTAssertEqual(LightstickProtocol.crc32(backing.dropFirst().dropLast()), 0xCBF43926)
    }

    func testChallengeMatchesIndependentStructAndZlibVector() throws {
        // Synthetic fixture independently calculated with Python struct/zlib.
        let nonce = Data((0..<16).map { UInt8($0) })
        let packet = try LightstickProtocol.challenge(mac: mac, nonce: nonce)
        XCTAssertEqual(packet.count, 39)
        XCTAssertEqual(
            hex(packet),
            "00000000f01df55544332211020000ff000000000102030405060708090a0b0c0d0e0feb91f027"
        )
        XCTAssertEqual(packet.prefix(4), Data(repeating: 0, count: 4))
        XCTAssertEqual(Data(packet[7..<13]), mac)
        XCTAssertEqual(Data(packet[13..<19]), data("0000ff000000"))
        XCTAssertEqual(Data(packet[19..<35]), nonce)
    }

    func testChallengeMatchesSecondSyntheticNonceVector() throws {
        let packet = try LightstickProtocol.challenge(mac: mac, nonce: Data(repeating: 0xA5, count: 16))
        XCTAssertEqual(
            hex(packet),
            "00000000f01df55544332211020000ff000000a5a5a5a5a5a5a5a5a5a5a5a5a5a5a5a578188b52"
        )
    }

    func testChallengeReadsDataSlicesAndCopiesInputs() throws {
        var macBacking = data("00554433221102ff")
        var nonceBacking = data("ff000102030405060708090a0b0c0d0e0fff")
        let packet = try LightstickProtocol.challenge(
            mac: macBacking.dropFirst().dropLast(),
            nonce: nonceBacking.dropFirst().dropLast()
        )
        macBacking[1] = 0
        nonceBacking[1] = 255
        XCTAssertEqual(
            hex(packet),
            "00000000f01df55544332211020000ff000000000102030405060708090a0b0c0d0e0feb91f027"
        )
        XCTAssertEqual(mac, data("554433221102"))
    }

    func testChallengeRequiresExactlySixMACBytes() {
        for length in [0, 1, 5, 7, 12] {
            XCTAssertThrowsError(try LightstickProtocol.challenge(
                mac: Data(repeating: 0, count: length), nonce: Data(repeating: 0, count: 16)
            )) { error in
                XCTAssertEqual(error as? LightstickProtocol.EncodingError, .invalidMACLength(length))
            }
        }
    }

    func testChallengeRequiresExactlySixteenNonceBytes() {
        for length in [0, 1, 15, 17, 32] {
            XCTAssertThrowsError(try LightstickProtocol.challenge(mac: mac, nonce: Data(repeating: 0, count: length))) { error in
                XCTAssertEqual(error as? LightstickProtocol.EncodingError, .invalidNonceLength(length))
            }
        }
    }

    func testSolidFramesMatchIndependentVectorsAndUInt32Endpoints() {
        let vectors: [(UInt32, LightRGB, String)] = [
            (0, LightRGB(red: 0, green: 0, blue: 0), "000000000000000069df2265"),
            (0, LightRGB(red: 0, green: 64, blue: 0), "00000000000040006c905b95"),
            (1, LightRGB(red: 0, green: 64, blue: 0), "0100000000004000f290f159"),
            (UInt32.max, LightRGB(red: 255, green: 0, blue: 255), "ffffffff00ff00ff9f24656c"),
            (0x12345678, LightRGB(red: 1, green: 2, blue: 3), "78563412000102039751a475"),
        ]
        for (sequence, rgb, expected) in vectors {
            let packet = LightstickProtocol.solid(sequence: sequence, rgb: rgb)
            XCTAssertEqual(packet.count, 12)
            XCTAssertEqual(packet[4], 0)
            XCTAssertEqual(hex(packet), expected)
        }
    }

    func testDisplayMACReversesDeviceBytesAndPreservesInput() throws {
        let backing = data("00554433221102ff")
        XCTAssertEqual(try LightstickProtocol.displayMAC(mac), "02:11:22:33:44:55")
        XCTAssertEqual(try LightstickProtocol.displayMAC(backing.dropFirst().dropLast()), "02:11:22:33:44:55")
        XCTAssertEqual(try LightstickProtocol.displayMAC(Data(repeating: 0, count: 6)), "00:00:00:00:00:00")
        XCTAssertEqual(hex(backing), "00554433221102ff")
        for length in [0, 5, 7] {
            XCTAssertThrowsError(try LightstickProtocol.displayMAC(Data(repeating: 0, count: length))) { error in
                XCTAssertEqual(error as? LightstickProtocol.EncodingError, .invalidMACLength(length))
            }
        }
    }

    func testUUIDsPreserveObservedEndpoints() {
        XCTAssertEqual(LightstickProtocol.lightingService, "0000ffe0-0000-1000-8000-00805f9b34fb")
        XCTAssertEqual(LightstickProtocol.colorWrite, "0000ffe1-0000-1000-8000-00805f9b34fb")
        XCTAssertEqual(LightstickProtocol.compatibilityService, "ac1f3d00-61a7-4824-a645-045b11d22d73")
        XCTAssertEqual(LightstickProtocol.challengeWrite, "ac1f3d01-61a7-4824-a645-045b11d22d73")
        XCTAssertEqual(LightstickProtocol.challengeResponseRead, "ac1f3d0a-61a7-4824-a645-045b11d22d73")
        XCTAssertEqual(LightstickProtocol.macRead, "ac1f3d07-61a7-4824-a645-045b11d22d73")
        XCTAssertEqual(LightstickProtocol.firmwareRead, "ac1f3d02-61a7-4824-a645-045b11d22d73")
    }

    private func data(_ hex: String) -> Data {
        precondition(hex.count.isMultiple(of: 2))
        return Data(stride(from: 0, to: hex.count, by: 2).map { offset in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)!
        })
    }

    private func hex(_ bytes: Data) -> String {
        bytes.map { String(format: "%02x", Int($0)) }.joined()
    }
}
