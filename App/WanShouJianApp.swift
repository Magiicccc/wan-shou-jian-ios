import SwiftUI
import UIKit

@MainActor
final class AppRuntime: ObservableObject {
    static let shared = AppRuntime()
    let manager: LightstickManager
    let session: RhythmSession

    private init() {
        let preview = ProcessInfo.processInfo.arguments.contains("--preview")
        let manager = LightstickManager(preview: preview)
        self.manager = manager
        session = RhythmSession(manager: manager, preview: preview)
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if let identifiers = launchOptions?[.bluetoothCentrals] as? [String] {
            AppRuntime.shared.manager.restoreIfRequested(identifiers: identifiers)
        }
        return true
    }
}

@main
@MainActor
struct WanShouJianApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var runtime = AppRuntime.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RhythmHomeView(manager: runtime.manager, session: runtime.session)
                .preferredColorScheme(.dark)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .background {
                        runtime.session.sceneChanged(isBackground: true)
                        runtime.manager.applicationDidEnterBackground()
                    } else if phase == .active {
                        runtime.manager.applicationWillEnterForeground()
                        runtime.session.sceneChanged(isBackground: false)
                    }
                }
        }
    }
}
