import XCTest
import RealityKit
import UIKit
@testable import WanShouJian

@MainActor final class FoxModelAppearanceTests: XCTestCase {
    func testLegacyModelKeepsItsMaterials() {
        let root = Entity()
        root.addChild(ModelEntity(mesh: .generateSphere(radius: 0.1),
                                  materials: [PhysicallyBasedMaterial()]))
        XCTAssertTrue(FoxModelAppearance.prepare(root).isEmpty)
    }

    func testBakedModelIncludesBothBlinkStates() {
        let root = Entity()
        let marker = Entity()
        marker.name = "MobileFoxRoot"
        root.addChild(marker)
        for name in ["Head", "HeadClosed"] {
            let part = ModelEntity(mesh: .generateSphere(radius: 0.1),
                                   materials: [PhysicallyBasedMaterial()])
            part.name = name
            marker.addChild(part)
        }
        let parts = FoxModelAppearance.prepare(root)
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue(parts.allSatisfy { $0.model?.materials.first is UnlitMaterial })
        FoxModelAppearance.tint(parts, color: .init(red: 0, green: 0, blue: 0),
                                energy: -1, active: false)
        for part in parts {
            let material = part.model!.materials[0] as! UnlitMaterial
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            XCTAssertTrue(material.color.tint.getRed(&red, green: &green, blue: &blue, alpha: &alpha))
            XCTAssertEqual(red, 0.38 * 0.82, accuracy: 0.001)
            XCTAssertEqual(alpha, 1)
        }
    }
}
