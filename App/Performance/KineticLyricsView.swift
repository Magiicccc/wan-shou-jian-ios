import SwiftUI

struct KineticLyricsView: View {
    var cue: LyricCue?
    var time: Double
    var energy: Double
    var nextCue:LyricCue? = nil
    @Environment(\.accessibilityReduceMotion) private var reduced

    var body: some View {
        GeometryReader { geometry in
            if let cue {
                let progress = unit((time-cue.start)/max(0.1,cue.end-cue.start))
                let fade = min(1,min(progress*9,(1-progress)*10))
                let lyricHeight=max(70,geometry.size.height-34)
                let side: CGFloat = min(geometry.size.width,430,lyricHeight*1.55)
                VStack(spacing:12) {
                  ZStack {
                    if cue.scene == .echo {
                        LyricEcho(word:cue.emphasis,side:side,color:Atmosphere.color(cue.mood.rgb))
                    }
                    LyricPhrase(cue:cue,side:side,height:lyricHeight,energy:energy,reduced:reduced)
                        .rotationEffect(.degrees(reduced ? 0 : cue.scene == .confrontation ? -3 : 0))
                        .offset(y:reduced ? 0 : cue.scene == .falling ? progress*20 : (1-fade)*10)
                  }.opacity(reduced ? 1 : max(0.35,fade)).frame(maxHeight:.infinity)
                  if let nextCue {
                    Text(nextCue.text).font(.system(size:12,weight:.regular)).tracking(1)
                        .foregroundStyle(Atmosphere.muted.opacity(0.8)).lineLimit(1)
                        .accessibilityIdentifier("stage-next-lyric")
                  }
                }
                .frame(maxWidth:.infinity,maxHeight:.infinity)
                .accessibilityElement(children:.ignore).accessibilityLabel(cue.text)
                .accessibilityIdentifier("stage-current-lyric")
            } else {
                Text("听见此刻").font(Atmosphere.title(28)).tracking(8).foregroundStyle(Atmosphere.muted)
                    .frame(maxWidth:.infinity,maxHeight:.infinity)
            }
        }
    }
}

private struct LyricEcho: View {
    var word: String
    var side: CGFloat
    var color: Color
    var body: some View {
        ForEach(1..<3,id:\.self) { index in
            Text(word).font(Atmosphere.title(side*0.13))
                .foregroundStyle(color.opacity(0.11/Double(index)))
                .offset(x:CGFloat(index)*13,y:CGFloat(index)*18)
        }
    }
}

private struct LyricPhrase: View {
    var cue: LyricCue
    var side: CGFloat
    var height: CGFloat
    var energy: Double
    var reduced: Bool
    private var parts: [String] { cue.text.components(separatedBy:cue.emphasis) }
    private var color: Color { Atmosphere.color(cue.mood.rgb) }
    var body: some View {
        if cue.scene == .confrontation || cue.scene == .rising { vertical }
        else { horizontal }
    }
    private var verticalFont: CGFloat {
        let available = (height-20)/CGFloat(max(1,cue.emphasis.count))/1.4
        return min(62,side*0.15,available)
    }
    private var vertical: some View {
        HStack(alignment:.center,spacing:18) {
            subtitle(parts.first ?? "")
            Text(cue.emphasis.map(String.init).joined(separator:"\n"))
                .font(Atmosphere.title(verticalFont)).lineSpacing(0).foregroundStyle(color)
                .scaleEffect(reduced ? 1 : 1+energy*0.045)
            subtitle(parts.dropFirst().joined(separator:cue.emphasis))
        }
    }
    private var horizontal: some View {
        VStack(spacing:8) {
            subtitle(parts.first ?? "")
            Text(cue.emphasis).font(Atmosphere.title(side*(cue.scene == .climax ? 0.19 : 0.145)))
                .tracking(cue.scene == .intimate ? 10 : 3)
                .lineLimit(1).minimumScaleFactor(0.5).foregroundStyle(color)
                .scaleEffect(reduced ? 1 : 1+energy*0.04)
                .shadow(color:color.opacity(0.18),radius:12)
            if let last=parts.last,!last.isEmpty,parts.count>1 { subtitle(last) }
        }
    }
    private func subtitle(_ text: String) -> some View {
        Text(text).font(.system(size:max(13,side*0.065),weight:.regular)).tracking(2)
            .foregroundStyle(Atmosphere.silver.opacity(0.82)).lineLimit(2).minimumScaleFactor(0.75)
    }
}
