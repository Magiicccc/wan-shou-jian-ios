import SwiftUI
import UIKit

enum FoxArtwork {
    static let open = load("fox-open")
    static let closed = load("fox-closed")

    private static func load(_ name: String) -> UIImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "PrivateVisuals") else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}

struct FoxVisualView: View {
    let light: LightState
    let active: Bool
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var color: Color { active ? Atmosphere.color(light.color) : Atmosphere.ice }
    private var energy: Double { active ? light.energy : 0.07 }
    private var opening: Double { active ? light.eyeOpening : 0 }

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                RadialGradient(colors: [color.opacity(0.05 + energy * 0.11), .clear], center: .center, startRadius: side * 0.14, endRadius: side * 0.49)
                TimelineView(.animation(minimumInterval: 1.0 / 30, paused: scenePhase != .active || reduceMotion || !active)) { timeline in
                    HaloCanvas(time: reduceMotion || !active ? 0 : timeline.date.timeIntervalSinceReferenceDate,
                               energy: energy, beat: active ? light.beat : 0,
                               crown: active ? light.crown : 0, tint: color)
                }
                .frame(width: side * 0.97, height: side * 0.97)
                if let awake = FoxArtwork.open {
                    ZStack {
                        Image(uiImage: FoxArtwork.closed ?? awake).resizable().scaledToFit()
                        Image(uiImage: awake).resizable().scaledToFit().opacity(opening)
                    }
                    .frame(width: side * 0.97, height: side * 0.97)
                    .colorMultiply(Color(white: active ? 0.29 + energy * 0.69 : 0.38))
                    .blendMode(.screen)
                    .overlay {
                        if active {
                            HStack(spacing: side * 0.147) {
                                eyeGlow(rotation: -17, side: side)
                                eyeGlow(rotation: 17, side: side)
                            }
                            .offset(y: side * 0.034)
                            .opacity(opening * (0.25 + energy * 0.65))
                            .blendMode(.screen)
                        }
                    }
                } else {
                    VStack(spacing: 18) {
                        Image(systemName: "waveform").font(.system(size: side * 0.20, weight: .ultraLight))
                            .foregroundStyle(Atmosphere.metal)
                        Text("光随音乐而生").font(Atmosphere.title(16)).tracking(3).foregroundStyle(Atmosphere.muted)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .animation(.easeInOut(duration: 0.25), value: opening)
        }
        .accessibilityElement(children: .ignore)
    }

    private func eyeGlow(rotation: Double, side: CGFloat) -> some View {
        Ellipse().fill(color).frame(width: side * 0.047, height: side * 0.011)
            .rotationEffect(.degrees(rotation))
            .shadow(color: color, radius: side * 0.018)
    }
}

private struct HaloCanvas: View {
    let time: Double
    let energy: Double
    let beat: Double
    let crown: Double
    let tint: Color

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = side * 0.395
            let outer = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            context.stroke(Path(ellipseIn: outer), with: .color(Atmosphere.silver.opacity(0.26)), lineWidth: 0.6)
            context.stroke(Path(ellipseIn: outer.insetBy(dx: 5, dy: 5)), with: .color(tint.opacity(0.23 + energy * 0.30)), lineWidth: 0.8)
            context.stroke(Path(ellipseIn: outer.insetBy(dx: -9, dy: -9)), with: .color(tint.opacity(0.10 + energy * 0.15)), style: StrokeStyle(lineWidth: 0.7, dash: [1, 12]))
            for index in 0..<6 {
                let start = Double(index) * .pi / 3 + time * 0.035
                var arc = Path()
                arc.addArc(center: center, radius: radius + 3, startAngle: .radians(start), endAngle: .radians(start + 0.32 + energy * 0.18), clockwise: false)
                context.stroke(arc, with: .color(tint.opacity(0.25 + energy * 0.50)), lineWidth: 1)
            }
            for index in 0..<48 {
                let angle = Double(index) * .pi / 24
                let length = 2 + (0.5 + 0.5 * sin(angle * 7 + time * 1.2)) * energy * 11
                let r = radius + 15
                var tick = Path()
                tick.move(to: point(center, radius: r, angle: angle))
                tick.addLine(to: point(center, radius: r + length, angle: angle))
                context.stroke(tick, with: .color(tint.opacity(index % 4 == 0 ? 0.5 : 0.15)), lineWidth: 0.7)
            }
            if beat > 0.05 {
                let spread = (1 - beat) * side * 0.07
                context.stroke(Path(ellipseIn: outer.insetBy(dx: -spread, dy: -spread)), with: .color(tint.opacity(beat * 0.45)), lineWidth: 1.2)
            }
            for index in 0..<24 {
                let seed = Double(index)
                let angle = seed * 2.39996 + sin(time * 0.06 + seed) * 0.03
                let r = radius * (1.03 + Double(index % 5) * 0.044)
                let location = point(center, radius: r, angle: angle)
                let alpha = 0.10 + energy * (0.2 + 0.3 * sin(seed * 6 + time * 0.7))
                context.fill(Path(ellipseIn: CGRect(x: location.x, y: location.y, width: index % 3 == 0 ? 1.6 : 0.8, height: index % 3 == 0 ? 1.6 : 0.8)), with: .color(Atmosphere.silver.opacity(max(0.05, alpha))))
            }
            if crown > 0.03 {
                for index in -6...6 {
                    let offset = Double(index) / 6
                    let angle = -.pi / 2 + offset * 0.80
                    let height = (1 - abs(offset) * 0.5) * side * 0.09 * crown
                    var ray = Path()
                    ray.move(to: point(center, radius: radius - 7, angle: angle - 0.017))
                    ray.addLine(to: point(center, radius: radius + height, angle: angle))
                    ray.addLine(to: point(center, radius: radius - 7, angle: angle + 0.017))
                    context.stroke(ray, with: .color(Atmosphere.gold.opacity(crown * 0.8)), lineWidth: 1)
                }
            }
        }
    }

    private func point(_ center: CGPoint, radius: Double, angle: Double) -> CGPoint {
        CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }
}
