import SwiftUI

struct KineticLyricsView:View {
    var cue:LyricCue?
    var time:Double
    var energy:Double
    var nextCue:LyricCue? = nil
    @Environment(\.accessibilityReduceMotion) private var reduced
    var body:some View {
        GeometryReader { g in
            VStack(spacing:16) {
                if let cue {
                    let progress=unit((time-cue.start)/max(0.1,cue.end-cue.start))
                    LyricComposition(cue:cue,width:g.size.width,height:max(60,g.size.height-40))
                        .scaleEffect(reduced ? 1 : 1+unit(energy)*0.025)
                        .offset(y:reduced ? 0 : (1-min(1,progress*8))*7)
                        .opacity(reduced ? 1 : 0.5+0.5*min(1,progress*8))
                        .frame(maxWidth:.infinity,maxHeight:.infinity)
                        .accessibilityElement(children:.ignore).accessibilityLabel(cue.text)
                        .accessibilityIdentifier("stage-current-lyric")
                } else {
                    Text("听见此刻").font(Atmosphere.title(28)).foregroundStyle(Atmosphere.muted)
                        .frame(maxWidth:.infinity,maxHeight:.infinity)
                }
                if let nextCue {
                    Text(nextCue.text).font(.system(size:13)).foregroundStyle(Atmosphere.muted)
                        .lineLimit(1).minimumScaleFactor(0.8).accessibilityIdentifier("stage-next-lyric")
                }
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }
    }
}

private struct LyricComposition:View {
    var cue:LyricCue
    var width:CGFloat
    var height:CGFloat
    private var groups:[String] { cue.groups ?? [cue.text] }
    private var color:Color {
        let palette=cue.palette ?? (cue.mood == .sorrow ? .rose : cue.mood == .tense ? .wine : cue.mood == .warm ? .champagne : .silver)
        switch palette {
        case .silver:return Color(red:0.89,green:0.9,blue:0.9)
        case .mist:return Color(red:0.68,green:0.67,blue:0.76)
        case .rose:return Color(red:0.83,green:0.59,blue:0.65)
        case .wine:return Color(red:0.88,green:0.24,blue:0.34)
        case .amber:return Color(red:0.92,green:0.7,blue:0.4)
        case .champagne:return Color(red:0.94,green:0.84,blue:0.64)
        }
    }
    private var fontSize:CGFloat {
        let target:CGFloat=cue.scene == .climax ? 38 : 30
        let rows=max(groups.count,Int(ceil(Double(cue.text.count)/10)))
        return min(target,width*0.092,max(16,height/CGFloat(max(1,rows))/1.6))
    }
    private var alignment:HorizontalAlignment {
        switch cue.scene { case .narrative,.rising,.confrontation:return .leading
        case .falling:return .trailing
        default:return .center }
    }
    var body:some View {
        ZStack {
            if cue.scene == .climax || cue.scene == .echo {
                Ellipse().fill(color.opacity(0.09)).blur(radius:28).frame(height:60)
            }
            if cue.scene == .intimate,groups.count==2,groups[0].count<=4,height>=150 {
                HStack(spacing:24) {
                    Text(groups[0].map(String.init).joined(separator:"\n"))
                        .font(Atmosphere.title(min(40,height/CGFloat(groups[0].count)/1.4))).foregroundStyle(color)
                    phrase(groups[1],index:1).lineLimit(4).minimumScaleFactor(0.7)
                }
            } else {
            VStack(alignment:alignment,spacing:10) {
                ForEach(Array(groups.enumerated()),id:\.offset) { index,group in
                    phrase(group,index:index)
                        .multilineTextAlignment(alignment == .leading ? .leading : alignment == .trailing ? .trailing : .center)
                        .lineLimit(4).minimumScaleFactor(0.65)
                        .padding(.leading,cue.scene == .rising ? CGFloat(index)*16 : 0)
                        .padding(.trailing,cue.scene == .falling ? CGFloat(groups.count-index-1)*12 : 0)
                }
            }.frame(maxWidth:.infinity,alignment:alignment == .leading ? .leading : alignment == .trailing ? .trailing : .center)
            }
        }
    }
    private func phrase(_ group:String,index:Int)->Text {
        var text=AttributedString(group)
        text.font = .system(size:fontSize,weight:cue.scene == .climax ? .semibold : .regular)
        text.foregroundColor=color.opacity(0.9)
        let base=groups.prefix(index).reduce(0){$0+$1.count}
        let focus=cue.focusStart ?? cue.text.range(of:cue.emphasis).map{cue.text.distance(from:cue.text.startIndex,to:$0.lowerBound)} ?? 0
        if !cue.emphasis.isEmpty,focus>=base,focus+cue.emphasis.count<=base+group.count {
            let start=text.index(text.startIndex,offsetByCharacters:focus-base)
            let end=text.index(start,offsetByCharacters:cue.emphasis.count)
            text[start..<end].font = .system(size:min(52,fontSize*1.35),weight:.semibold)
            text[start..<end].foregroundColor=color
        }
        return Text(text)
    }
}
