import SwiftUI
import UniformTypeIdentifiers
import AVKit

struct KaraokeView: View {
    @ObservedObject var session:KaraokeSession
    @State private var importer=false
    @State private var lyricsImport=false
    @State private var console=false
    @State private var ai=false
    @State private var showingReport=false
    @State private var menu=false
    @State private var controls=true
    @State private var externalSetup=false
    @State private var lyricsSheet=false
    @State private var songTitle=""
    @State private var lastTouch=Date()
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    var body: some View {
        GeometryReader { g in
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing:0) {
                    header.padding(.horizontal,24).padding(.top,12).zIndex(2)
                    if !session.isSessionActive {
                        Button { externalSetup=true } label: {
                            Label("网易云 / 外部播放",systemImage:"music.note.list").font(.system(size:13))
                                .padding(.vertical,9).frame(maxWidth:.infinity)
                                .background(.white.opacity(0.06),in:RoundedRectangle(cornerRadius:12))
                        }.padding(.horizontal,24).padding(.top,8).accessibilityIdentifier("external-music")
                    }
                    FoxStageView(light:session.light,time:session.position,active:session.playing)
                        .frame(height:max(140,(g.size.height-265)*0.56)).clipped().allowsHitTesting(false)
                    Group {
                        if session.externalMusic {
                            ExternalLyricStage(lyrics:session.externalLyrics,energy:session.energy,time:session.position) { lyricsSheet=true }
                        } else { KineticLyricsView(cue:session.currentCue,time:session.position,energy:session.energy,nextCue:session.nextCue) }
                    }.frame(height:max(150,(g.size.height-265)*0.44)).padding(.horizontal,28).clipped()
                    Spacer(minLength:4)
                    if controls || !session.playing || voiceOver { transport.padding(.horizontal,24).transition(.opacity) }
                }
            }
            .foregroundStyle(Atmosphere.silver)
            .contentShape(Rectangle())
            .onTapGesture { controls=true;lastTouch=Date() }
            .task(id:session.playing) {
                while session.playing && !Task.isCancelled {
                    try? await Task.sleep(nanoseconds:1_000_000_000)
                    if Date().timeIntervalSince(lastTouch)>8 && !voiceOver { withAnimation { controls=false } }
                }
            }
        }
        .fileImporter(isPresented:$importer,allowedContentTypes:lyricsImport ? [.data,.plainText] : [.audio]) { result in
            if case .success(let url)=result { if lyricsImport { session.importLyrics(url) } else { session.importAudio(url) } }
        }
        .sheet(isPresented:$console) { mixingConsole.presentationDetents([.medium,.large]) }
        .sheet(isPresented:$ai) { DirectorSettingsView() }
        .sheet(isPresented:$showingReport) { reportSheet }
        .sheet(isPresented:$externalSetup) { externalSheet }
        .sheet(isPresented:$lyricsSheet,onDismiss:{ controls=true;lastTouch=Date() }) { LyricsSheet(lyrics:session.externalLyrics) }
        .confirmationDialog("舞台菜单",isPresented:$menu,titleVisibility:.visible) {
            Button("导入音频") { lyricsImport=false;importer=true }
            Button("网易云 / 外部播放") { externalSetup=true }
            if session.externalMusic { Button("歌词与同步") { lyricsSheet=true } }
            Button("导入 LRC 歌词") { lyricsImport=true;importer=true }
            Button("原创演示") { session.useDemo() }
            Button("AI 接口设置") { ai=true }
            Button("AI 编排本曲") { Task { await session.direct(using:client) } }
            Button("演唱复盘") { showingReport=true }
        }
    }

    private var header:some View {
        HStack(alignment:.top) {
            VStack(alignment:.leading,spacing:5) {
                Text("私 人 舞 台").font(.system(size:10,weight:.medium)).tracking(4).foregroundStyle(Atmosphere.muted)
                Text(session.externalMusic ? session.externalLyrics.track?.title ?? session.title : session.title).font(Atmosphere.title(21)).lineLimit(1)
            }
            Spacer()
            Button { menu=true } label: { Image(systemName:"ellipsis").frame(width:44,height:44).contentShape(Rectangle()) }
            .accessibilityLabel("舞台菜单").accessibilityIdentifier("stage-menu")
        }
    }

    private var transport:some View {
        VStack(spacing:10) {
            HStack {
                Text(clock(session.position)).monospacedDigit()
                if session.externalMusic {
                    Spacer()
                    Text("自由演唱 · 最长 20 分钟").accessibilityIdentifier("external-elapsed")
                } else {
                    Slider(value:Binding(get:{session.position},set:{session.seek($0)}),in:0...max(1,session.duration))
                        .tint(Atmosphere.silver).accessibilityLabel("播放进度").accessibilityIdentifier("stage-progress")
                    Text(clock(session.duration)).monospacedDigit()
                }
            }.font(.caption2).foregroundStyle(Atmosphere.muted)
            HStack(spacing:28) {
                Button { console=true } label: { Image(systemName:"slider.vertical.3").frame(width:44,height:44) }.accessibilityLabel("混音控制")
                Button { lastTouch=Date();if session.isSessionActive { session.pauseFromUser() } else { session.start() } } label: {
                    Image(systemName:session.isSessionActive ? "pause.fill" : "play.fill").font(.system(size:20,weight:.light))
                        .frame(width:64,height:64).background(.white.opacity(0.06),in:Circle())
                        .overlay(Circle().strokeBorder(Atmosphere.metal,lineWidth:1))
                }.accessibilityLabel(session.isSessionActive ? "暂停舞台" : "开始舞台").accessibilityIdentifier("stage-play")
                Button { session.finish();showingReport=true } label: { Image(systemName:"stop").frame(width:44,height:44) }.accessibilityLabel("结束并复盘").accessibilityIdentifier("stage-finish")
            }
            Text(session.analyzing ? "AI 正在分析，舞台保持本地运行" : session.status)
                .font(.system(size:10)).foregroundStyle(Atmosphere.muted).lineLimit(2).multilineTextAlignment(.center)
                .accessibilityIdentifier("stage-status")
        }.padding(.bottom,12)
    }

    private var mixingConsole:some View {
        NavigationStack {
            Form {
                Section("声音") {
                    LabeledContent("播放设备") { AudioOutputPicker().frame(width:44,height:44) }
                    Text(session.route).font(.footnote)
                    if !session.externalMusic { LabeledContent("伴奏音量") { Slider(value:$session.accompanimentVolume,in:0...1) } }
                    Toggle("人声实时返送",isOn:$session.monitorEnabled).disabled(session.externalMusic)
                    LabeledContent("返送音量") { Slider(value:$session.monitorVolume,in:0...0.3) }
                    LabeledContent("房间混响") { Slider(value:$session.reverbAmount,in:0...0.3) }
                    Text("手机自身外放：返送从低音量开始。出现回声或尖锐声时关闭返送；声线分析仍可继续。").font(.footnote).foregroundStyle(.secondary)
                }
                Section("光") { LabeledContent("亮度上限") { Slider(value:$session.brightness,in:0...1) } }
                if session.externalMusic { Section("歌曲氛围") { Picker("配色",selection:$session.externalMood) { ForEach(SongMood.allCases,id:\.self) { Text($0.rawValue).tag($0) } } } }
                if session.externalMusic {
                    Section("媒体暂停实验") {
                        Text(session.mediaPauseResult.message).font(.footnote).accessibilityIdentifier("media-pause-result")
                        Button("暂停舞台与当前音乐") { session.pauseFromUser() }.accessibilityIdentifier("media-pause-test")
                        Text("作用于这台 iPhone 的当前音乐播放器。播放状态请在音乐 App 核对；继续唱歌时，在音乐 App 恢复播放。").font(.footnote)
                    }
                }
                Section("实时测量") {
                    LabeledContent("麦克风",value:session.hasMicrophone ? "正在收音" : "已关闭")
                    LabeledContent("声线频率",value:session.vocal.pitch>0 ? "\(Int(session.vocal.pitch)) Hz" : "等待稳定声线")
                    LabeledContent("置信度",value:"\(Int(session.vocal.confidence*100))%")
                }
            }.modifier(StudioSurface()).navigationTitle("声音与光").toolbar { Button("完成") { console=false } }
        }.preferredColorScheme(.dark)
    }
    private var reportSheet:some View {
        NavigationStack {
            ScrollView {
                VStack(alignment:.leading,spacing:24) {
                    Text("这一段，听见自己").font(Atmosphere.title(26))
                    Text(session.title).font(.subheadline).foregroundStyle(Atmosphere.muted)
                    HStack(spacing:12) {
                        scoreCard("声线稳定度",value:session.assessment.steadiness)
                        scoreCard("电平余量",value:session.assessment.levelHeadroom)
                    }
                    HStack {
                        Label("\(session.assessment.validSamples) 个有效采样",systemImage:"waveform.path")
                        Spacer()
                        Text("\(Int(session.assessment.measuredSeconds)) 秒").monospacedDigit()
                    }.font(.caption).foregroundStyle(Atmosphere.muted)
                    Text(session.evidence.isEmpty ? "开始一次演唱，让手机听到持续的声音，再回到这里查看练习参考。" : "这次练习的参考分来自手机收音。靠近麦克风、降低原唱音量，有助于观察自己的声线变化。")
                        .font(.system(size:14)).lineSpacing(5).foregroundStyle(Atmosphere.muted)
                    Button { Task { await session.review(using:client) } } label: {
                        HStack { Image(systemName:"sparkles");Text(session.analyzing ? "正在整理练习建议" : "AI 解读这一段");Spacer();Image(systemName:"arrow.up.right") }
                            .padding(18).background(.white.opacity(0.06),in:RoundedRectangle(cornerRadius:16))
                    }.disabled(session.analyzing || session.isSessionActive || session.evidence.isEmpty)
                    DisclosureGroup("测量依据与完整复盘") {
                        Text(session.report).font(.system(size:14)).lineSpacing(6).textSelection(.enabled).padding(.top,12)
                    }.font(.subheadline)
                    Text("发送内容为带时间戳的声线与电平指标。原始声音保留在本机音频链路中。").font(.footnote).foregroundStyle(.secondary)
                }.padding(26)
            }.modifier(StudioSurface()).navigationTitle("演唱复盘").toolbar { Button("完成") { showingReport=false } }
        }.preferredColorScheme(.dark)
    }
    private var externalSheet: some View {
        NavigationStack {
            Form {
                Section("网易云 / 外部播放") {
                    TextField("歌名（可选）",text:$songTitle).accessibilityIdentifier("external-title")
                    Text("1. 点击下方开始收音。\n2. 切到网易云音乐，选择歌曲播放并跟唱。\n3. 唱完返回，点击结束并复盘。")
                    Text("音箱使用系统蓝牙，宝宝剑保持 App 内连接。返回舞台可查看歌词，并在「歌词与同步」中选择版本或对齐当前句。")
                    LabeledContent("选择播放设备") { AudioOutputPicker().frame(width:44,height:44) }
                }
                Section("评分范围") {
                    Text("提供声线稳定度、电平参考及 AI 练习建议。选择伴奏版、降低音箱音量并靠近手机，有助于减少原唱对测量的影响。")
                }
            }
            .safeAreaInset(edge:.bottom) {
                Button("开始外部音乐演唱") {
                    let name=songTitle.trimmingCharacters(in:.whitespacesAndNewlines)
                    session.useExternalMusic(title:name.isEmpty ? "网易云 · 自由演唱" : name)
                    session.start(); externalSetup=false; controls=true; lastTouch=Date()
                }.font(.headline).frame(maxWidth:.infinity).padding(.vertical,16)
                    .foregroundStyle(.black).background(Atmosphere.silver,in:RoundedRectangle(cornerRadius:16))
                    .padding(.horizontal,20).padding(.vertical,12).background(.ultraThinMaterial)
                    .accessibilityIdentifier("external-start")
            }
            .modifier(StudioSurface()).navigationTitle("跟着网易云唱").toolbar { Button("完成") { externalSetup=false } }
        }.preferredColorScheme(.dark)
    }
    private var client:DirectorClient { let s=DirectorSettings.load();return .init(settings:s,key:DirectorKeychain.read(for:s.credentialID)) }
    private func scoreCard(_ title:String,value:Int?)->some View {
        VStack(alignment:.leading,spacing:16) {
            Text(title).font(.system(size:12)).foregroundStyle(Atmosphere.muted)
            Text(value.map(String.init) ?? "待测").font(.system(size:value==nil ? 24 : 38,weight:.light,design:.rounded)).monospacedDigit()
            Text(value==nil ? "等待有效收音" : "练习参考 / 100").font(.system(size:10)).foregroundStyle(Atmosphere.muted)
        }.frame(maxWidth:.infinity,alignment:.leading).padding(18)
            .background(.white.opacity(0.045),in:RoundedRectangle(cornerRadius:18))
            .overlay(RoundedRectangle(cornerRadius:18).strokeBorder(.white.opacity(0.07)))
    }
    private func clock(_ value:Double)->String { String(format:"%02d:%02d",Int(value)/60,Int(value)%60) }
}

private struct AudioOutputPicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker=AVRoutePickerView(); picker.tintColor = .lightGray; picker.activeTintColor = .white
        picker.prioritizesVideoDevices=false
        return picker
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct DirectorSettingsView: View {
    @State private var settings=DirectorSettings.load()
    @State private var key=""
    @State private var message="密钥按接口地址保存在本机钥匙串。"
    @State private var busy=false
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        NavigationStack {
            Form {
                Section("OpenAI 兼容接口") {
                    TextField("HTTPS Base URL",text:$settings.baseURL).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("模型名称",text:$settings.model).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("API Key",text:$key).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("保存到本机") { save() }
                    Button(busy ? "连接中" : "测试连接") {
                        guard save() else { return };busy=true
                        Task { do { try await DirectorClient(settings:settings,key:key).test();message="连接成功" } catch { message=error.localizedDescription };busy=false }
                    }.disabled(busy)
                    Text(message).font(.footnote)
                }
                Section("AI 的工作方式") {
                    Text("获取歌词后按需编排情绪与重点词，舞台按歌曲时间轴呈现。唱完后，AI 根据测量指标整理练习建议。")
                    Text("首次使用先填写接口。未配置时可使用本地编排和本机测量。")
                }.font(.footnote)
            }.modifier(StudioSurface()).navigationTitle("AI 导演").toolbar { Button("完成") { dismiss() } }
        }.preferredColorScheme(.dark)
        .onAppear { key=DirectorKeychain.read(for:settings.credentialID) }
        .onChange(of:settings.baseURL) { _,_ in key=DirectorKeychain.read(for:settings.credentialID) }
    }
    @discardableResult private func save()->Bool {
        do { try DirectorKeychain.save(key.trimmingCharacters(in:.whitespacesAndNewlines),for:settings.credentialID);settings.save();message="已保存";return true }
        catch { message=error.localizedDescription;return false }
    }
}
