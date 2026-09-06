import SwiftUI

struct KineticLyricsView: View {
    var cue: LyricCue?
    var time: Double
    var energy: Double
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body: some View {
        GeometryReader { geometry in
            if let cue {
                let progress=unit((time-cue.start)/max(0.1,cue.end-cue.start))
                let fade=min(1,min(progress*9,(1-progress)*10))
                let accent=Atmosphere.color(cue.mood.rgb)
                let emphasis=cue.emphasis
                let parts=cue.text.components(separatedBy:emphasis)
                let side=min(geometry.size.width,430)
                ZStack {
                    if cue.scene == .echo {
                        ForEach(1..<3,id:\.self) { index in
                            Text(emphasis).font(Atmosphere.title(side*0.13))
                                .foregroundStyle(accent.opacity(0.11/Double(index)))
                                .offset(x:CGFloat(index)*13,y:CGFloat(index)*18)
                        }
                    }
                    VStack(spacing:12) {
                        if cue.scene == .confrontation || cue.scene == .rising {
                            HStack(alignment:.center,spacing:18) {
                                Text(parts.first ?? "").font(Atmosphere.title(side*0.065)).foregroundStyle(Atmosphere.muted)
                                Text(emphasis.map(String.init).joined(separator:"\n"))
                                    .font(Atmosphere.title(min(62,side*0.15))).lineSpacing(0).foregroundStyle(accent)
                                    .scaleEffect(reduced ? 1 : 1+energy*0.045)
                                Text(parts.dropFirst().joined(separator:emphasis)).font(Atmosphere.title(side*0.065)).foregroundStyle(Atmosphere.muted)
                            }
                        } else {
                            Text(parts.first ?? "").font(Atmosphere.title(side*0.065)).tracking(5).foregroundStyle(Atmosphere.muted)
                            Text(emphasis).font(Atmosphere.title(side*(cue.scene == .climax ? 0.19 : 0.145)))
                                .tracking(cue.scene == .intimate ? 10 : 3)
                                .foregroundStyle(accent)
                                .scaleEffect(reduced ? 1 : 1+energy*0.04)
                                .shadow(color:accent.opacity(0.18),radius:12)
                            if let last=parts.last,!last.isEmpty,parts.count>1 { Text(last).font(Atmosphere.title(side*0.062)).tracking(4).foregroundStyle(Atmosphere.silver) }
                        }
                    }
                    .rotationEffect(.degrees(reduced ? 0 : cue.scene == .confrontation ? -3 : 0))
                    .offset(y:reduced ? 0 : cue.scene == .falling ? progress*20 : (1-fade)*10)
                }
                .opacity(reduced ? 1 : fade)
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
