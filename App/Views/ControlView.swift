import SwiftUI
import UIKit

@MainActor
struct ControlView: View {
    @ObservedObject var manager: LightstickManager
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let presets = [
        ColorPreset(id: "green", title: "绿色", hex: "#00FF00"),
        ColorPreset(id: "red", title: "红色", hex: "#FF0000"),
        ColorPreset(id: "blue", title: "蓝色", hex: "#0000FF"),
        ColorPreset(id: "silver", title: "银白", hex: "#E9EAED")
    ]
    private var isPreview: Bool {
        ProcessInfo.processInfo.arguments.contains("--preview")
    }
    private var lightColor: Color { Self.color(manager.colorHex) }
    private var isTransitioning: Bool {
        switch manager.phase {
        case .scanning, .connecting, .initializing, .disconnecting: return true
        default: return false
        }
    }
    private var canStart: Bool {
        !isPreview && !isTransitioning && !manager.isSending
    }
    private var canChooseDevice: Bool {
        guard !isPreview else { return false }
        switch manager.phase {
        case .idle, .scanning, .failed: return true
        default: return false
        }
    }
    private var phaseTitle: String {
        if isPreview { return "界面演示" }
        switch manager.phase {
        case .idle: return "待连接"
        case .scanning: return "正在扫描"
        case .connecting: return "正在连接"
        case .initializing: return "正在握手"
        case .ready: return "手动控剑就绪"
        case .disconnecting: return "正在释放连接"
        case .failed: return "连接待恢复"
        }
    }
    private var primaryTitle: String {
        if isPreview { return "界面演示" }
        switch manager.phase {
        case .idle: return "扫描宝宝剑"
        case .scanning: return "扫描中，请选择设备"
        case .connecting: return "正在连接宝宝剑"
        case .initializing: return "正在完成设备握手"
        case .ready: return manager.isSending ? "正在提交光色" : "试灯"
        case .disconnecting: return "正在释放连接"
        case .failed: return "重新扫描"
        }
    }

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Palette.background, Color(hex: 0x17191D), Palette.background],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 22) {
                    colorControls
                    connectionControls
                    footer
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 20)
                .padding(.top, 24)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .tint(Palette.silver)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            primaryButton
                .frame(maxWidth: 520)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
                .overlay(alignment: .top) {
                    Rectangle().fill(.white.opacity(0.08)).frame(height: 1)
                }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 13, weight: .medium))
                    Text("掌心调光")
                        .font(.subheadline.weight(.medium))
                        .tracking(2)
                }
                .foregroundStyle(Palette.muted)
                Spacer(minLength: 8)
                phasePill
            }
            Text("万兽共鸣")
                .font(.largeTitle.weight(.semibold))
                .tracking(5)
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white, Palette.silver, Color(hex: 0x9198A4)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .accessibilityAddTraits(.isHeader)
            Text("给你的宝宝剑，一束专属光色。")
                .font(.subheadline)
                .foregroundStyle(Palette.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var phasePill: some View {
        HStack(spacing: 6) {
            if isTransitioning && !isPreview {
                ProgressView().controlSize(.mini)
            } else {
                Circle()
                    .fill(manager.canControl && !isPreview ? Color(hex: 0xA3E0C3) : Palette.muted)
                    .frame(width: 5, height: 5)
            }
            Text(phaseTitle)
                .font(.caption.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Palette.silver)
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(.white.opacity(0.045), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.1), lineWidth: 1))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connection-status")
    }

    private var swordPreview: some View {
        VStack(spacing: 0) {
            HStack {
                Text("光色预览")
                    .tracking(2)
                Spacer()
                Text(isPreview ? "演示模式" : "手动模式")
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(Palette.muted)
            .padding(20)

            ZStack {
                Ellipse()
                    .fill(lightColor.opacity(0.15 * manager.brightness))
                    .frame(width: 170, height: 180)
                    .blur(radius: 38)
                Ellipse()
                    .fill(.white.opacity(0.05))
                    .frame(width: 90, height: 7)
                    .blur(radius: 5)
                    .offset(y: 111)
                SwordIllustration(color: lightColor, brightness: manager.brightness)
                    .frame(width: 98, height: 237)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 250)
            .accessibilityLabel("屏幕剑光示意，颜色 \(manager.colorHex)，亮度 \(Int((manager.brightness * 100).rounded()))%")
            .accessibilityIdentifier("sword-preview")

            HStack(alignment: .lastTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(manager.brightness == 0 ? "静候下一束光" : "此刻，你的光")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Palette.silver)
                    Text("屏幕示意 · 实际灯色以剑身为准")
                        .font(.caption2)
                        .foregroundStyle(Palette.muted)
                }
                Spacer(minLength: 12)
                Text(manager.colorHex.uppercased())
                    .font(.caption.monospaced())
                    .foregroundStyle(Palette.silver)
            }
            .padding(20)
        }
        .background(
            LinearGradient(
                colors: [Color(hex: 0x23262C), Color(hex: 0x15171B)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 24)
        )
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(.white.opacity(0.1), lineWidth: 1))
    }

    private var colorControls: some View {
        ControlCard {
            VStack(alignment: .leading, spacing: 20) {
                sectionTitle("选择光色", subtitle: manager.canControl && !isPreview ? "调节实时提交" : "先在屏幕上预览")

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: dynamicTypeSize.isAccessibilitySize ? 2 : 4),
                    spacing: 8
                ) {
                    ForEach(presets) { preset in
                        let selected = manager.colorHex.uppercased() == preset.hex
                        Button {
                            manager.applyColor(preset.hex)
                        } label: {
                            VStack(spacing: 9) {
                                Circle()
                                    .fill(Self.color(preset.hex))
                                    .frame(width: 17, height: 17)
                                    .overlay(Circle().strokeBorder(.white.opacity(0.22), lineWidth: 1))
                                Text(preset.title)
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(Palette.silver)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(.white.opacity(selected ? 0.09 : 0.025), in: RoundedRectangle(cornerRadius: 13))
                            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(selected ? 0.5 : 0.08), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("选择\(preset.title)")
                        .accessibilityValue(selected ? "已选择" : "")
                        .accessibilityIdentifier("preset-\(preset.id)")
                    }
                }

                HStack(spacing: 12) {
                    Text("自选光色")
                        .font(.subheadline)
                        .foregroundStyle(Palette.silver)
                    Spacer(minLength: 8)
                    Text(manager.colorHex.uppercased())
                        .font(.caption.monospaced())
                        .foregroundStyle(Palette.muted)
                    ColorPicker("自选光色", selection: Binding(
                        get: { lightColor },
                        set: { color in
                            if let hex = Self.hex(color) { manager.applyColor(hex) }
                        }
                    ), supportsOpacity: false)
                    .labelsHidden()
                    .frame(width: 44, height: 44)
                    .accessibilityIdentifier("custom-color")
                }

                Rectangle().fill(.white.opacity(0.07)).frame(height: 1)

                VStack(spacing: 7) {
                    HStack {
                        Label("亮度", systemImage: "sun.max")
                            .font(.subheadline)
                            .foregroundStyle(Palette.silver)
                        Spacer()
                        Text("\(Int((manager.brightness * 100).rounded()))%")
                            .font(.title3.monospacedDigit().weight(.medium))
                            .foregroundStyle(Palette.silver)
                            .accessibilityIdentifier("brightness-value")
                    }
                    Slider(value: Binding(
                        get: { manager.brightness },
                        set: { manager.applyBrightness($0) }
                    ), in: 0...1, step: 0.01)
                    .frame(minHeight: 44)
                    .accessibilityLabel("试灯亮度")
                    .accessibilityValue("\(Int((manager.brightness * 100).rounded()))%")
                    .accessibilityIdentifier("brightness-slider")
                    HStack {
                        Text("0% · 熄灯")
                        Spacer()
                        Text("100%")
                    }
                    .font(.caption2)
                    .foregroundStyle(Palette.muted)
                }
            }
        }
    }

    private var connectionControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            if isPreview {
                Label("当前为界面演示，光色变化显示在屏幕中。", systemImage: "eye")
                    .font(.footnote)
                    .foregroundStyle(Palette.muted)
                    .accessibilityIdentifier("preview-mode-notice")
            }

            if manager.phase == .scanning || (!manager.devices.isEmpty && canChooseDevice) {
                deviceList
            }

            if isPreview ? !manager.lastSubmitted.isEmpty : !manager.deviceName.isEmpty {
                ControlCard {
                    VStack(alignment: .leading, spacing: 14) {
                        sectionTitle(isPreview ? "屏幕预览" : "这把宝宝剑", subtitle: isPreview ? "当前光色" : "设备信息")
                        if !isPreview {
                            detailRow("名称", value: manager.deviceName)
                            detailRow("固件", value: manager.firmware.isEmpty ? "待读取" : manager.firmware)
                            detailRow("地址", value: manager.mac.isEmpty ? "待读取" : manager.mac)
                        }
                        if !manager.lastSubmitted.isEmpty {
                            detailRow(isPreview ? "屏幕预览颜色" : "最近提交", value: manager.lastSubmitted)
                                .accessibilityIdentifier("last-submitted")
                            Text(isPreview ? "当前颜色已显示在屏幕预览中。" : "颜色已提交至蓝牙，请观察剑身实际变化。")
                                .font(.caption)
                                .foregroundStyle(Palette.muted)
                        }
                    }
                }
            }

            if !manager.message.isEmpty {
                HStack(alignment: .top, spacing: 9) {
                    Image(systemName: manager.phase == .failed ? "exclamationmark.circle" : "info.circle")
                    Text(manager.message)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.footnote)
                .foregroundStyle(manager.phase == .failed ? Color(hex: 0xF0C7A1) : Palette.muted)
                .padding(14)
                .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("connection-message")
            }

            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 10) { secondaryButtons }
            } else {
                HStack(spacing: 10) { secondaryButtons }
            }
        }
    }

    private var deviceList: some View {
        ControlCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionTitle("附近的宝宝剑", subtitle: "点选连接")
                if manager.devices.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().controlSize(.small)
                        Text("让宝宝剑进入配对状态，并靠近手机。")
                            .font(.footnote)
                            .foregroundStyle(Palette.muted)
                    }
                    .padding(.vertical, 8)
                } else {
                    ForEach(manager.devices) { device in
                        Button {
                            manager.connect(device.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(.body)
                                    .foregroundStyle(Palette.muted)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(device.name)
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(Palette.silver)
                                    Text("信号 \(device.rssi) dBm")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(Palette.muted)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Palette.muted)
                            }
                            .frame(minHeight: 48)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!canChooseDevice)
                        .accessibilityLabel("连接 \(device.name)，信号 \(device.rssi) dBm")
                        .accessibilityIdentifier("device-\(device.id.uuidString)")
                    }
                }
            }
        }
        .accessibilityIdentifier("device-list")
    }

    private var primaryButton: some View {
        Button {
            if manager.canControl { manager.sendCurrent() }
            else { manager.scan() }
        } label: {
            HStack(spacing: 10) {
                if isTransitioning || manager.isSending {
                    ProgressView().tint(Palette.background)
                } else {
                    Image(systemName: manager.canControl ? "sun.max.fill" : "antenna.radiowaves.left.and.right")
                }
                Text(primaryTitle)
                    .font(.body.weight(.semibold))
            }
            .foregroundStyle(Palette.background)
            .frame(maxWidth: .infinity, minHeight: 55)
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .background(
                LinearGradient(colors: [.white, Color(hex: 0xB6BDC7)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 16)
            )
            .opacity(canStart ? 1 : 0.55)
        }
        .buttonStyle(.plain)
        .disabled(!canStart)
        .accessibilityLabel(primaryTitle)
        .accessibilityIdentifier("primary-control")
    }

    @ViewBuilder
    private var secondaryButtons: some View {
        Button {
            manager.turnOff()
        } label: {
            Label("熄灯", systemImage: "power")
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .buttonStyle(.bordered)
        .tint(Palette.silver)
        .disabled(isPreview || !manager.canControl)
        .accessibilityHint("将亮度设为零并提交到宝宝剑")
        .accessibilityIdentifier("turn-off")

        Button {
            manager.disconnect()
        } label: {
            Label(manager.phase == .scanning ? "停止扫描" : (manager.phase == .failed ? "重试释放" : "断开连接"), systemImage: "xmark.circle")
                .frame(maxWidth: .infinity, minHeight: 48)
        }
        .disabled(isPreview || manager.phase == .idle || manager.phase == .disconnecting)
        .accessibilityIdentifier("disconnect")
        .buttonStyle(.bordered)
        .tint(Palette.silver)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "iphone")
                Text("逐项观察剑身变化")
                    .fontWeight(.medium)
            }
            .font(.footnote)
            .foregroundStyle(Palette.silver)
            Text("本页用于固定颜色与亮度验证。返回律动页启动音乐会话后，可按设置继续后台拾音与控灯。")
                .font(.caption)
                .foregroundStyle(Palette.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text("手动控制 · 实物验证")
                .font(.caption2)
                .foregroundStyle(Palette.muted)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private func sectionTitle(_ title: String, subtitle: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.silver)
                Spacer(minLength: 12)
                Text(subtitle).font(.caption).foregroundStyle(Palette.muted)
            }
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Palette.silver)
                Text(subtitle).font(.caption).foregroundStyle(Palette.muted)
            }
        }
        .accessibilityAddTraits(.isHeader)
    }

    private func detailRow(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(Palette.muted)
            Text(value).font(.subheadline.monospaced()).foregroundStyle(Palette.silver)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private static func color(_ hex: String) -> Color {
        Color(hex: UInt32(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0x00FF00)
    }

    private static func hex(_ color: Color) -> String? {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return nil }
        let channels = [red, green, blue].map { Int((min(1, max(0, $0)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channels[0], channels[1], channels[2])
    }
}

private enum Palette {
    static let background = Color(hex: 0x101114)
    static let silver = Color(hex: 0xE9EAED)
    static let muted = Color(hex: 0xA0A6B0)
}

private struct ColorPreset: Identifiable {
    let id: String
    let title: String
    let hex: String
}

private extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}

private struct ControlCard<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.white.opacity(0.08), lineWidth: 1))
    }
}

private struct SwordIllustration: View {
    let color: Color
    let brightness: Double

    var body: some View {
        ZStack {
            BladeShape()
                .fill(Color(hex: 0x343B43))
            BladeShape()
                .fill(LinearGradient(
                    colors: [color.opacity(0.35), .white, color, color.opacity(0.5)],
                    startPoint: .leading,
                    endPoint: .trailing
                ))
                .opacity(brightness)
                .shadow(color: color.opacity(0.8 * brightness), radius: 15)
                .shadow(color: color.opacity(0.5 * brightness), radius: 5)
            BladeShape()
                .stroke(.white.opacity(0.3), lineWidth: 0.8)

            GeometryReader { geometry in
                let width = geometry.size.width
                let height = geometry.size.height
                Path { path in
                    path.move(to: CGPoint(x: width * 0.11, y: height * 0.72))
                    path.addLine(to: CGPoint(x: width * 0.34, y: height * 0.78))
                    path.addLine(to: CGPoint(x: width * 0.5, y: height * 0.755))
                    path.addLine(to: CGPoint(x: width * 0.66, y: height * 0.78))
                    path.addLine(to: CGPoint(x: width * 0.89, y: height * 0.72))
                    path.addLine(to: CGPoint(x: width * 0.77, y: height * 0.835))
                    path.addLine(to: CGPoint(x: width * 0.5, y: height * 0.81))
                    path.addLine(to: CGPoint(x: width * 0.23, y: height * 0.835))
                    path.closeSubpath()
                }
                .fill(LinearGradient(colors: [Color(hex: 0x464D57), .white, Color(hex: 0x6F7782)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(colors: [Color(hex: 0x272B32), Color(hex: 0x929AA7), Color(hex: 0x2B2F36)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: width * 0.15, height: height * 0.155)
                        .position(x: width * 0.5, y: height * 0.885)
                }
            }
        }
    }
}

private struct BladeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let points: [(CGFloat, CGFloat)] = [
            (0.5, 0.015), (0.61, 0.11), (0.595, 0.735),
            (0.5, 0.79), (0.405, 0.735), (0.39, 0.11)
        ]
        path.move(to: CGPoint(x: rect.width * points[0].0, y: rect.height * points[0].1))
        for point in points.dropFirst() {
            path.addLine(to: CGPoint(x: rect.width * point.0, y: rect.height * point.1))
        }
        path.closeSubpath()
        return path
    }
}
