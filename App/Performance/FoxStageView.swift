import RealityKit
import SwiftUI
import UIKit
import Combine

struct FoxStageView: View {
    var light: LightState
    var time: Double
    var active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    private var modelURL: URL? { Bundle.main.url(forResource:"fox",withExtension:"usdz",subdirectory:"PrivateVisuals") }
    var body: some View {
        ZStack {
            if let url=modelURL {
                FoxRealityView(url:url,light:light,time:time,active:active && scenePhase == .active,motion:!reduceMotion)
            } else {
                FoxVisualView(light:light,active:active)
            }
            GeometryReader { proxy in
                let side=min(proxy.size.width,proxy.size.height)*0.90
                let tint=Atmosphere.color((active ? light.stage == .idle ? SongMood.reflective.rgb : normalized(light.color) : SongMood.reflective.rgb))
                Circle().trim(from:0.04,to:0.93).stroke(tint.opacity(0.35),style:StrokeStyle(lineWidth:0.6,dash:[3,11]))
                    .frame(width:side,height:side).rotationEffect(.degrees(reduceMotion ? 0 : time*1.5))
                    .position(x:proxy.size.width/2,y:proxy.size.height/2)
                Circle().trim(from:0.2,to:0.48).stroke(tint.opacity(active ? 0.75 : 0.20),lineWidth:1)
                    .frame(width:side*1.03,height:side*1.03).rotationEffect(.degrees(reduceMotion ? 0 : -time*8))
                    .position(x:proxy.size.width/2,y:proxy.size.height/2)
                if light.crown > 0.1 {
                    Image(systemName:"crown").font(.system(size:38,weight:.ultraLight))
                        .foregroundStyle(tint.opacity(light.crown)).shadow(color:tint.opacity(0.5),radius:14)
                        .position(x:proxy.size.width/2,y:proxy.size.height*0.08)
                }
            }.allowsHitTesting(false)
        }
        .accessibilityLabel(modelURL == nil ? "白狐资源预览" : "三维白狐舞台")
    }
    private func normalized(_ rgb:LightRGB)->LightRGB {
        let peak=max(rgb.red,max(rgb.green,rgb.blue))
        guard peak>0 else { return SongMood.reflective.rgb }
        return .init(red:UInt8(Double(rgb.red)/Double(peak)*255),green:UInt8(Double(rgb.green)/Double(peak)*255),blue:UInt8(Double(rgb.blue)/Double(peak)*255))
    }
}

private struct FoxRealityView: UIViewRepresentable {
    let url: URL
    var light: LightState
    var time: Double
    var active: Bool
    var motion: Bool
    func makeCoordinator()->Coordinator { Coordinator() }
    func makeUIView(context:Context)->ARView {
        let view=ARView(frame:.zero,cameraMode:.nonAR,automaticallyConfigureSession:false)
        view.environment.background = .color(.black)
        view.renderOptions.insert(.disableMotionBlur)
        let anchor=AnchorEntity(world:.zero)
        let camera=PerspectiveCamera();camera.camera.fieldOfViewInDegrees=34;camera.position=[0,0.05,4.6];anchor.addChild(camera)
        let key=DirectionalLight();key.light.intensity=1700;key.light.color=UIColor(red:0.75,green:0.85,blue:1,alpha:1)
        key.look(at:[0,0,0],from:[-2,3,3],relativeTo:nil);anchor.addChild(key)
        let fill=DirectionalLight();fill.light.intensity=550;fill.light.color=UIColor(red:0.55,green:0.66,blue:1,alpha:1)
        fill.look(at:[0,0,0],from:[2,1,-2],relativeTo:nil);anchor.addChild(fill)
        view.scene.addAnchor(anchor)
        context.coordinator.load=Entity.loadAsync(contentsOf:url).receive(on:DispatchQueue.main).sink(
            receiveCompletion: { result in
                if case .failure = result { view.accessibilityLabel="三维模型加载失败" }
            }, receiveValue: { entity in
                let bounds=entity.visualBounds(relativeTo:nil)
                let dimension=max(bounds.extents.x,max(bounds.extents.y,bounds.extents.z))
                let pivot=Entity()
                let scale:Float=2.05/max(0.01,dimension)
                entity.scale *= scale;entity.position = -bounds.center*scale
                pivot.addChild(entity);anchor.addChild(pivot)
                context.coordinator.pivot=pivot;context.coordinator.model=entity
                context.coordinator.setBlink(true)
            })
        return view
    }
    func updateUIView(_ view:ARView,context:Context) {
        guard let pivot=context.coordinator.pivot,let model=context.coordinator.model else { return }
        let amplitude:Float=active && motion ? Float(0.025+light.energy*0.055) : 0
        pivot.orientation=simd_quatf(angle:Float(sin(time*0.48))*amplitude,axis:[0,1,0]) * simd_quatf(angle:Float(sin(time*0.7))*amplitude*0.25,axis:[1,0,0])
        for label in ["L","R"] {
            model.findEntity(named:"Ear_"+label)?.orientation=simd_quatf(angle:Float(light.beat)*amplitude*(label == "L" ? 1 : -1),axis:[0,0,1])
        }
        context.coordinator.setBlink(!active || light.eyeOpening<0.25 || (motion && time.truncatingRemainder(dividingBy:5.7)>5.54))
    }
    static func dismantleUIView(_ view:ARView,coordinator:Coordinator) { coordinator.load?.cancel();view.scene.anchors.removeAll() }
    @MainActor final class Coordinator {
        var pivot:Entity?
        var model:Entity?
        var load:AnyCancellable?
        func setBlink(_ closed:Bool) {
            for name in ["Head","DirectionalFur"] {
                model?.findEntity(named:name)?.isEnabled = !closed
                model?.findEntity(named:name+"Closed")?.isEnabled = closed
            }
        }
    }
}
