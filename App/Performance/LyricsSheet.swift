import SwiftUI

struct StudioSurface: ViewModifier {
    func body(content:Content) -> some View {
        content.scrollContentBackground(.hidden)
            .background(Atmosphere.background)
            .foregroundStyle(Atmosphere.silver)
            .tint(Atmosphere.ice)
            .navigationBarTitleDisplayMode(.inline)
            .environment(\.defaultMinListRowHeight,48)
    }
}

struct LyricsSheet: View {
    @ObservedObject var lyrics:ExternalLyrics
    @State private var query=""
    @State private var artist=""
    @State private var aligning=false
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        NavigationStack {
          ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment:.leading,spacing:24) {
                    VStack(alignment:.leading,spacing:8) {
                        Text("让文字，跟上这一刻").font(Atmosphere.title(27))
                        Text("网易云继续播放，歌词留在你的舞台。")
                            .font(.subheadline).foregroundStyle(Atmosphere.muted)
                    }
                    VStack(spacing:12) {
                        TextField("歌名",text:$query).accessibilityIdentifier("lyrics-query")
                        Divider().overlay(.white.opacity(0.07))
                        TextField("歌手（可选）",text:$artist).accessibilityIdentifier("lyrics-artist")
                        Button { lyrics.find(title:query,artist:artist) } label: {
                            HStack { Image(systemName:"magnifyingglass");Text(lyrics.busy ? "搜索中" : "搜索歌词");Spacer();Image(systemName:"arrow.right") }
                                .font(.system(size:14,weight:.medium)).padding(.vertical,10)
                        }.disabled(lyrics.busy || query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                            .accessibilityIdentifier("lyrics-search")
                    }.padding(18).background(.white.opacity(0.045),in:RoundedRectangle(cornerRadius:18))
                    Text(lyrics.message).font(.system(size:12)).foregroundStyle(Atmosphere.muted).lineSpacing(4)
                        .accessibilityIdentifier("lyrics-message")
                    if !lyrics.cues.isEmpty {
                        VStack(alignment:.leading,spacing:14) {
                            HStack {
                                Label(lyrics.syncing,systemImage:"waveform.path").font(.caption)
                                Spacer()
                                Text(time(lyrics.position())).monospacedDigit().font(.caption)
                            }
                            Button { aligning.toggle() } label: {
                                HStack { Text("点选当前唱到的一句");Spacer();Image(systemName:aligning ? "chevron.up" : "chevron.down") }
                            }.accessibilityIdentifier("lyrics-align")
                            HStack {
                                Text("时间微调").font(.caption)
                                Spacer()
                                Text(String(format:"%+.1f 秒",lyrics.offset)).font(.caption.monospacedDigit())
                            }
                            Slider(value:$lyrics.offset,in:-10...10,step:0.1).accessibilityLabel("歌词时间微调")
                            Text("歌词偏早时向左调，偏晚时向右调。音箱延迟随播放设备调整。")
                                .font(.caption2).foregroundStyle(Atmosphere.muted)
                            Button("重新跟随播放器") { lyrics.followPlayer() }.font(.caption)
                        }.padding(18).background(.white.opacity(0.045),in:RoundedRectangle(cornerRadius:18))
                        if aligning || !lyrics.hasPosition {
                            LazyVStack(alignment:.leading,spacing:0) {
                                ForEach(lyrics.cues) { cue in
                                    Button { lyrics.align(to:cue);dismiss() } label: {
                                        HStack(alignment:.top,spacing:16) {
                                            Text(time(cue.start)).font(.caption.monospacedDigit()).foregroundStyle(Atmosphere.muted)
                                            Text(cue.text).font(.system(size:15)).multilineTextAlignment(.leading)
                                            Spacer(minLength:0)
                                        }.padding(.vertical,14).frame(maxWidth:.infinity,alignment:.leading).contentShape(Rectangle())
                                    }.accessibilityIdentifier("lyric-line-\(cue.id)")
                                    Divider().overlay(.white.opacity(0.04))
                                }
                            }.id("lyric-lines")
                        }
                    }
                    LazyVStack(alignment:.leading,spacing:12) {
                        ForEach(lyrics.results) { record in
                            Button { lyrics.choose(record);aligning=true } label: {
                                HStack(spacing:14) {
                                    Image(systemName:lyrics.selectedID==record.id ? "checkmark.circle.fill" : "music.note")
                                        .foregroundStyle(lyrics.selectedID==record.id ? Atmosphere.ice : Atmosphere.muted)
                                    VStack(alignment:.leading,spacing:6) {
                                        Text(record.trackName).font(.system(size:16,weight:.medium))
                                        Text("\(record.artistName) · \(record.albumName ?? "单曲")").font(.caption).foregroundStyle(Atmosphere.muted)
                                        Text("\(time(record.duration)) · \(record.hasTiming ? "时间轴歌词" : "纯文本")").font(.caption2).foregroundStyle(Atmosphere.muted)
                                    }
                                    Spacer(minLength:0)
                                    Image(systemName:"chevron.right").font(.caption)
                                }.padding(16).frame(maxWidth:.infinity,alignment:.leading)
                                    .background(.white.opacity(0.035),in:RoundedRectangle(cornerRadius:16))
                            }.buttonStyle(.plain).accessibilityIdentifier("lyrics-result-\(record.id)")
                        }
                    }
                    if lyrics.cues.isEmpty,!lyrics.plainText.isEmpty {
                        Text(lyrics.plainText).font(.body).lineSpacing(9).textSelection(.enabled)
                    }
                    VStack(alignment:.leading,spacing:8) {
                        Text("歌词来自 LRCLIB，选用的版本缓存在本机。搜索发送歌名与歌手，声音继续在本机处理。")
                        Text("播放器同步为侧载实验能力；手动对齐适用于自动读取暂时不可用的情况。带时间轴的歌词按句同步。")
                    }.font(.caption2).foregroundStyle(Atmosphere.muted).lineSpacing(4)
                    if ProcessInfo.processInfo.arguments.contains("--preview") {
                        Button("载入原创歌词演示") { lyrics.loadPreview();aligning=true }
                            .accessibilityIdentifier("lyrics-preview")
                    }
                }.padding(24)
            }.modifier(StudioSurface()).navigationTitle("歌词与同步")
                .toolbar { Button("完成") { dismiss() } }
                .onChange(of:lyrics.selectedID) { _,_ in
                    if !lyrics.cues.isEmpty {
                        DispatchQueue.main.async { withAnimation { proxy.scrollTo("lyric-lines",anchor:.top) } }
                    }
                }
          }
        }.preferredColorScheme(.dark)
        .onAppear { query=lyrics.track?.title ?? "";artist=lyrics.track?.artist ?? "" }
    }
    private func time(_ value:Double)->String { String(format:"%02d:%02d",Int(max(0,value))/60,Int(max(0,value))%60) }
}

struct ExternalLyricStage:View {
    @ObservedObject var lyrics:ExternalLyrics
    var energy:Double
    var time:Double
    var open:()->Void
    var body:some View {
        VStack(spacing:10) {
            if !lyrics.cues.isEmpty,lyrics.hasPosition {
                KineticLyricsView(cue:lyrics.currentCue,time:lyrics.position(),energy:energy,nextCue:lyrics.nextCue)
            } else {
                VStack(spacing:12) {
                    Text(lyrics.cues.isEmpty ? "等一句，与你共鸣" : "歌词已就位").font(Atmosphere.title(26))
                    Text(lyrics.cues.isEmpty ? "识别当前播放器，或搜索你正在听的歌" : "点选当前句，开始同步")
                        .font(.system(size:12)).foregroundStyle(Atmosphere.muted)
                }.frame(maxWidth:.infinity,maxHeight:.infinity)
            }
            Button(action:open) {
                HStack(spacing:7) {
                    Circle().fill(lyrics.hasPosition ? Atmosphere.ice : Atmosphere.muted).frame(width:4,height:4)
                    Text(lyrics.busy ? "正在寻找歌词" : lyrics.syncing).lineLimit(1)
                    Text("·");Text("歌词与同步");Image(systemName:"chevron.right").font(.system(size:8))
                }.font(.system(size:11)).foregroundStyle(Atmosphere.muted).padding(.vertical,10)
            }.accessibilityIdentifier("open-lyrics")
        }
    }
}
