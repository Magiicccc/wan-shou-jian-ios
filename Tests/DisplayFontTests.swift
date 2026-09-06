import CoreText
import UIKit
import XCTest
@testable import WanShouJian

final class DisplayFontTests: XCTestCase {
    @MainActor
    func testBundledDisplayFontUsesItsExactPostScriptName() async throws {
        let font = try XCTUnwrap(UIFont(name: "WSJDisplay-ExtraLight", size: 32))
        XCTAssertEqual(font.fontName, "WSJDisplay-ExtraLight")
        let registered = Bundle.main.object(forInfoDictionaryKey: "UIAppFonts") as? [String] ?? []
        XCTAssertTrue(registered.contains { ($0 as NSString).lastPathComponent == "WSJDisplay-ExtraLight.otf" })
    }

    @MainActor
    func testDisplayFontContainsCriticalChineseTitleGlyphs() async throws {
        let font = try XCTUnwrap(UIFont(name: "WSJDisplay-ExtraLight", size: 32))
        let coreFont = CTFontCreateWithName(font.fontName as CFString, 32, nil)
        XCTAssertEqual(CTFontCopyPostScriptName(coreFont) as String, "WSJDisplay-ExtraLight")
        var characters = Array("万兽共鸣音乐律动宝宝剑后台连接".utf16)
        let count = characters.count
        var glyphs = [CGGlyph](repeating: 0, count: count)
        XCTAssertTrue(CTFontGetGlyphsForCharacters(coreFont, &characters, &glyphs, count))
        XCTAssertTrue(glyphs.allSatisfy { $0 != 0 })
    }
}
