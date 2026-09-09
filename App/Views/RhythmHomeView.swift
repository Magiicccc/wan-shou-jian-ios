import SwiftUI
import UIKit

enum Atmosphere {
    static let silver = Color(red: 0.88, green: 0.89, blue: 0.92)
    static let muted = Color(red: 0.56, green: 0.59, blue: 0.64)
    static let ice = Color(red: 0.60, green: 0.73, blue: 0.97)
    static let gold = Color(red: 0.88, green: 0.75, blue: 0.53)
    static let background = Color(red: 0.012, green: 0.018, blue: 0.028)
    static let metal = LinearGradient(colors: [.white, silver, Color(white: 0.40), silver], startPoint: .topLeading, endPoint: .bottomTrailing)

    static func color(_ rgb: LightRGB) -> Color {
        Color(red: Double(rgb.red) / 255, green: Double(rgb.green) / 255, blue: Double(rgb.blue) / 255)
    }

    static func title(_ size: CGFloat) -> Font {
        .custom("WSJDisplay-ExtraLight", size: size, relativeTo: .title2)
    }
}

@MainActor
struct RhythmHomeView: View {
    @ObservedObject var manager: LightstickManager
    @ObservedObject var session: RhythmSession
    @ObservedObject var karaoke: KaraokeSession
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var tab = 0
    @State private var immersive = false
    @State private var pendingImmersion = false
    @State private var manual = false
    private var preview: Bool { ProcessInfo.processInfo.arguments.contains("--preview") }

    var body: some View {
        ZStack {
            Atmosphere.background.ignoresSafeArea()
            if tab == 0 { home }
            else if tab == 1 { devices }
            else if tab == 3 { KaraokeView(session:karaoke) }
            else { settings }
        }
        .foregroundStyle(Atmosphere.silver)
        .tint(Atmosphere.ice)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 14) {
                if tab == 0 { wakeButton.padding(.horizontal, 30) }
                navigation
            }
            .padding(.top, 10)
            .background(LinearGradient(colors: [Atmosphere.background.opacity(0), Atmosphere.background, .black], startPoint: .top, endPoint: .bottom))
        }
        .fullScreenCover(isPresented: $immersive) {
            ImmersiveRhythmView(manager: manager, session: session, preview: preview)
        }
        .sheet(isPresented: $manual) {
            NavigationStack {
                ControlView(manager: manager)
                    .navigationTitle("手动试灯")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { manual = false } } }
            }
            .preferredColorScheme(.dark)
        }
        .onChange(of: session.isRunning) { _, running in
            if running && pendingImmersion { pendingImmersion = false; immersive = true }
        }
    }

    private var home: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("万兽共鸣").font(Atmosphere.title(29)).tracking(5).foregroundStyle(Atmosphere.metal)
                            Text("让音乐，唤醒你的光").font(.caption).tracking(2).foregroundStyle(Atmosphere.muted)
                        }
                        Spacer()
                        Button { tab = 2 } label: {
                            Image(systemName: "slider.horizontal.3").font(.system(size: 18, weight: .light)).frame(width: 44, height: 44)
                        }.accessibilityLabel("律动设置").accessibilityIdentifier("open-settings")
                    }
                    .padding(.top, 15)
                    .padding(.bottom, 20)
                    connectionStrip
                    FoxRhythmStageView(light: session.light, active: session.isRunning && (manager.canControl || preview))
                        .frame(height: geometry.size.height < 560
                               ? max(170, geometry.size.height * 0.34)
                               : min(355, geometry.size.height * 0.48))
                        .padding(.top, 6)
                        .accessibilityLabel("白狐光效，\(session.light.stage.rawValue)")
                        .accessibilityIdentifier("fox-visual")
                    VStack(spacing: 6) {
                        Text(session.isRunning ? session.light.stage.rawValue : "静候，下一次共鸣")
                            .font(Atmosphere.title(21)).tracking(3)
                            .foregroundStyle(session.light.crown > 0.25 ? Atmosphere.gold : Atmosphere.silver)
                        Text(preview ? "视觉预览 · 合成音乐演示" : (session.phase != .idle || session.mediaPauseResult != .idle ? session.message : "听见房间里的音乐，让光自然流动"))
                            .font(.caption).foregroundStyle(Atmosphere.muted)
                            .multilineTextAlignment(.center)
                            .accessibilityIdentifier("rhythm-message")
                    }
                    .padding(.bottom, 22)
                    RhythmAdjustments(session: session, compact: true)
                }
                .padding(.horizontal, 26)
                .padding(.bottom, 12)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }.scrollIndicators(.hidden)
        }
    }

    private var connectionStrip: some View {
        Button { tab = 1 } label: {
            HStack(spacing: 10) {
                Image(systemName: manager.canControl && !preview ? "wave.3.right" : "link")
                    .font(.system(size: 14, weight: .light))
                Text(connectionTitle).font(.caption.weight(.medium))
                Spacer()
                Text(preview ? "屏幕演示" : (session.isRunning && session.backgroundEnabled ? "后台已开启" : "家中聆听"))
                    .font(.system(size: 10)).foregroundStyle(Atmosphere.muted)
                Image(systemName: "chevron.right").font(.system(size: 10))
            }
            .padding(.horizontal, 14).frame(minHeight: 40)
            .background(.white.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.white.opacity(0.12), lineWidth: 0.6))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("connection-status")
    }

    private var connectionTitle: String {
        if preview { return "白狐视觉预览" }
        switch manager.phase {
        case .ready: return manager.deviceName.isEmpty ? "宝宝剑已连接" : manager.deviceName
        case .scanning: return "正在寻找宝宝剑"
        case .connecting, .initializing: return "正在唤醒宝宝剑"
        case .disconnecting: return "正在断开连接"
        case .failed: return "连接待恢复"
        case .idle: return "连接你的宝宝剑"
        }
    }

    private var wakeButton: some View {
        Button {
            if session.isRunning { immersive = true }
            else if preview { pendingImmersion = true; session.startPreview() }
            else if manager.canControl { pendingImmersion = true; session.start() }
            else { tab = 1; manager.scan() }
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: session.isRunning ? "waveform" : "sparkle").font(.system(size: 16, weight: .light))
                Text(session.isRunning ? "回到共鸣" : (preview ? "预览律动" : "唤醒万兽"))
                    .font(Atmosphere.title(21)).tracking(4)
            }
            .foregroundStyle(Color(red: 0.12, green: 0.13, blue: 0.15))
            .frame(maxWidth: .infinity, minHeight: 57)
            .background(LinearGradient(colors: [Color(white: 0.95), Color(red: 0.68, green: 0.70, blue: 0.75), Color(white: 0.91)], startPoint: .topLeading, endPoint: .bottomTrailing), in: Capsule())
            .overlay(Capsule().inset(by: 3).strokeBorder(.black.opacity(0.15), lineWidth: 0.6))
            .shadow(color: Atmosphere.ice.opacity(0.10), radius: 22, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(session.isRunning ? "回到共鸣" : (preview ? "预览律动" : "唤醒万兽"))
        .accessibilityIdentifier("wake-rhythm")
    }

    private var navigation: some View {
        HStack {
            navigationItem(0, "律动", "waveform")
            navigationItem(3, "舞台", "music.mic")
            navigationItem(1, "设备", "antenna.radiowaves.left.and.right")
            navigationItem(2, "设置", "slider.horizontal.3")
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 4)
        .overlay(alignment: .top) { Rectangle().fill(.white.opacity(0.06)).frame(height: 0.5).padding(.horizontal, 26) }
    }

    private func navigationItem(_ index: Int, _ title: String, _ symbol: String) -> some View {
        Button {
            if index == 3 { session.stop() }
            else if tab == 3 { karaoke.pause() }
            tab = index
        } label: {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 17, weight: .light))
                Text(title).font(.system(size: 10)).tracking(2)
            }
            .foregroundStyle(tab == index ? Atmosphere.silver : Atmosphere.muted)
            .frame(maxWidth: .infinity, minHeight: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(tab == index ? "已选择" : "")
        .accessibilityIdentifier("tab-\(index)")
    }

    private var devices: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                pageHeading("你的宝宝剑", subtitle: "一把剑，与房间里的音乐共鸣")
                VStack(alignment: .leading, spacing: 14) {
                    Label(connectionTitle, systemImage: "antenna.radiowaves.left.and.right").font(.headline)
                    Text(manager.message).font(.footnote).foregroundStyle(Atmosphere.muted)
                    if !manager.firmware.isEmpty {
                        Text("固件 \(manager.firmware)").font(.caption.monospaced()).foregroundStyle(Atmosphere.muted)
                    }
                    if manager.phase == .ready && !preview {
                        Button("断开连接") { session.stop(); manager.disconnect() }
                            .buttonStyle(.bordered).accessibilityIdentifier("device-disconnect")
                    } else {
                        Button(manager.phase == .scanning ? "正在搜索" : "搜索宝宝剑") { manager.scan() }
                            .buttonStyle(.borderedProminent)
                            .disabled(preview || manager.phase == .connecting || manager.phase == .initializing || manager.phase == .disconnecting)
                            .accessibilityIdentifier("scan-devices")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading).padding(22)
                .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
                ForEach(manager.devices) { device in
                    Button { manager.connect(device.id) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(device.name).font(.body)
                                Text("信号 \(device.rssi) dBm").font(.caption.monospaced()).foregroundStyle(Atmosphere.muted)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                        }.frame(minHeight: 58).contentShape(Rectangle())
                    }.disabled(manager.phase == .ready || manager.phase == .connecting || manager.phase == .initializing || manager.phase == .disconnecting)
                }
                Button { session.stop(); manual = true } label: {
                    HStack {
                        Label("手动试灯", systemImage: "sun.max")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption)
                    }.frame(minHeight: 52).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("open-manual")
                Text("先让官方小程序和 LightBlue 释放连接，再将宝宝剑设为白光闪烁。首次试灯可依次确认红、绿、蓝与明暗变化。")
                    .font(.footnote).foregroundStyle(Atmosphere.muted).lineSpacing(5)
                if !manager.lastSubmitted.isEmpty {
                    Text("最近提交\n\(manager.lastSubmitted)").font(.caption.monospaced()).foregroundStyle(Atmosphere.muted)
                }
            }.padding(26).frame(maxWidth: 560).frame(maxWidth: .infinity)
        }
    }

    private var settings: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                pageHeading("聆听偏好", subtitle: "保留音乐的层次，让光自在呼吸")
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("后台律动", isOn: $session.backgroundEnabled).accessibilityIdentifier("background-toggle")
                    Text("开启后，已启动的音乐会话在切换 App 和锁屏时继续拾音、分析与控灯。返回页面会显示当前状态。")
                        .font(.footnote).foregroundStyle(Atmosphere.muted).lineSpacing(4)
                }
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("柔和脉冲", isOn: $session.antiFlash).accessibilityIdentifier("anti-flash-toggle")
                    Text("鼓点采用有间隔的柔和提亮，回落平滑，适合居家长时间听歌。")
                        .font(.footnote).foregroundStyle(Atmosphere.muted).lineSpacing(4)
                }
                RhythmAdjustments(session: session, compact: false)
                VStack(alignment: .leading, spacing: 14) {
                    Text("声音来自哪里").font(Atmosphere.title(22))
                    Text("手机麦克风聆听电视、电脑、音箱或另一台手机的外放音乐。音频短帧只在本机内存中分析。")
                        .font(.footnote).foregroundStyle(Atmosphere.muted).lineSpacing(5)
                    Text("同机外放可单独测试音量和路由兼容性。耳机内的音乐需要改用外放，让手机麦克风能够听到。")
                        .font(.footnote).foregroundStyle(Atmosphere.muted).lineSpacing(5)
                }
                Button("重新校准房间声音") { session.recalibrate() }
                    .buttonStyle(.bordered).disabled(!session.isRunning).accessibilityIdentifier("recalibrate")
                Text(session.message).font(.caption).foregroundStyle(Atmosphere.muted)
                if session.phase != .idle {
                    Button("暂停音乐并熄灯") { session.stopFromUser() }.buttonStyle(.bordered).accessibilityIdentifier("settings-stop")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("连续运行验证").font(.footnote.weight(.medium))
                    Text("后台会话与恢复逻辑已接入。锁屏、来电、切换 App 及 30 / 60 分钟连续体验，需在你的 iPhone 与实剑上逐项核验。")
                        .font(.caption).foregroundStyle(Atmosphere.muted).lineSpacing(4)
                }
            }.padding(26).frame(maxWidth: 560).frame(maxWidth: .infinity)
        }
    }

    private func pageHeading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(Atmosphere.title(30)).tracking(3).foregroundStyle(Atmosphere.metal)
            Text(subtitle).font(.caption).foregroundStyle(Atmosphere.muted)
        }.padding(.top, 15)
    }
}

@MainActor
struct RhythmAdjustments: View {
    @ObservedObject var session: RhythmSession
    let compact: Bool
    var identifierPrefix = "rhythm"
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(spacing: compact ? 13 : 22) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) { Text("律动强度").font(.caption); Spacer(); intensity }
                VStack(alignment: .leading, spacing: 12) { Text("律动强度").font(.caption); intensity }
            }
            VStack(spacing: 0) {
                HStack {
                    Text("亮度上限").font(.caption)
                    Spacer()
                    Text("\(Int(session.brightnessLimit * 100))%")
                        .font(.caption.monospacedDigit()).foregroundStyle(Atmosphere.ice)
                        .accessibilityIdentifier("\(identifierPrefix)-brightness-value")
                }
                Slider(value: $session.brightnessLimit, in: 0...1, step: 0.01)
                    .frame(minHeight: 36).tint(Atmosphere.ice)
                    .accessibilityLabel("律动亮度上限").accessibilityIdentifier("\(identifierPrefix)-brightness")
            }
        }.foregroundStyle(Atmosphere.silver)
    }

    private var intensity: some View {
        HStack(spacing: 4) {
            intensityButton("柔和", value: 0.6)
            intensityButton("标准", value: 1.0)
            intensityButton("强烈", value: 1.5)
        }
    }

    private func intensityButton(_ title: String, value: Double) -> some View {
        Button { session.intensity = value } label: {
            Text(title).font(.caption).padding(.horizontal, 14).frame(minHeight: 36)
                .background(.white.opacity(abs(session.intensity - value) < 0.1 ? 0.12 : 0), in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(abs(session.intensity - value) < 0.1 ? 0.18 : 0), lineWidth: 0.7))
        }.buttonStyle(.plain)
            .accessibilityValue(abs(session.intensity - value) < 0.1 ? "已选择" : "")
            .accessibilityIdentifier("\(identifierPrefix)-intensity-\(title)")
    }
}

@MainActor
struct ImmersiveRhythmView: View {
    @ObservedObject var manager: LightstickManager
    @ObservedObject var session: RhythmSession
    let preview: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var controls = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.ignoresSafeArea()
                FoxRhythmStageView(light: session.light, active: session.isRunning && (manager.canControl || preview))
                    .frame(width: geometry.size.width * 0.94,
                           height: min(geometry.size.width * 0.96, geometry.size.height * 0.47))
                    .contentShape(Rectangle())
                    .onLongPressGesture(minimumDuration: 1.5) { stop() }
                    .accessibilityLabel("沉浸白狐，\(session.light.stage.rawValue)")
                    .accessibilityAction(named: Text("停止律动")) { stop() }
                    .accessibilityIdentifier("immersive-fox")
                    .position(x: geometry.size.width / 2, y: geometry.size.height * 0.36)
                if controls || voiceOver {
                    VStack {
                        HStack {
                            Button { dismiss() } label: { Image(systemName: "chevron.down").frame(width: 44, height: 44) }
                                .accessibilityLabel("返回控制页").accessibilityIdentifier("exit-immersive")
                            Spacer()
                            Text(preview ? "合成音乐预览" : (session.backgroundEnabled ? "后台律动已开启" : "前台律动"))
                                .font(.caption).foregroundStyle(Atmosphere.muted)
                        }.padding(.horizontal, 16)
                        Spacer()
                        VStack(spacing: 14) {
                            VStack(spacing: 7) {
                                Text(session.light.stage.rawValue)
                                    .font(Atmosphere.title(22)).tracking(4)
                                    .foregroundStyle(session.light.crown > 0.25 ? Atmosphere.gold : Atmosphere.silver)
                                    .accessibilityIdentifier("immersive-stage")
                                Text(session.message)
                                    .font(.caption).multilineTextAlignment(.center)
                                    .foregroundStyle(Atmosphere.muted)
                            }
                            RhythmAdjustments(session: session, compact: true, identifierPrefix: "immersive")
                            HStack(spacing: 20) {
                                Button { session.recalibrate(); showControls() } label: {
                                    Image(systemName: "waveform.badge.mic").frame(width: 48, height: 48)
                                }.accessibilityLabel("重新校准")
                                Button { stop() } label: {
                                    Label("停止律动", systemImage: "pause.fill").font(.body)
                                        .frame(maxWidth: .infinity, minHeight: 51)
                                        .background(.white.opacity(0.075), in: Capsule())
                                        .overlay(Capsule().strokeBorder(Atmosphere.silver.opacity(0.5), lineWidth: 0.7))
                                }.accessibilityIdentifier("stop-rhythm")
                            }
                            Text("轻触显示控制 · 长按白狐停止").font(.system(size: 10)).foregroundStyle(Atmosphere.muted)
                        }.padding(24).background(LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom))
                    }.transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { showControls() }
            .foregroundStyle(Atmosphere.silver).tint(Atmosphere.ice)
        }
        .statusBarHidden(!controls)
        .onAppear { showControls() }
        .onDisappear { hideTask?.cancel() }
        .onChange(of: session.isRunning) { _, running in if !running { dismiss() } }
    }

    private func showControls() {
        hideTask?.cancel()
        withAnimation(.easeInOut(duration: 0.45)) { controls = true }
        guard !voiceOver else { return }
        hideTask = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            withAnimation(.easeInOut(duration: 1.2)) { controls = false }
        }
    }

    private func stop() { hideTask?.cancel(); session.stopFromUser(); dismiss() }
}
