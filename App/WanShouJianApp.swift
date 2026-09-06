import SwiftUI

@main
@MainActor
struct WanShouJianApp: App {
    @StateObject private var manager = LightstickManager(
        preview: ProcessInfo.processInfo.arguments.contains("--preview")
    )
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ControlView(manager: manager)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        manager.pauseForBackground()
                    }
                }
        }
    }
}
