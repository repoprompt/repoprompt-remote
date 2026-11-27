import SwiftUI

@main
struct RepoPromptRemoteApp: App {
    @StateObject private var model = RemoteAppModel()
    @UIApplicationDelegateAdaptor(RemoteNotificationDelegate.self) private var notificationDelegate
    @Environment(\.scenePhase) private var scenePhase

    init() {
        RemotePairingTelemetry.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .background { RemoteWindowAppearance() }
                .onChange(of: scenePhase) { _, phase in
                    model.setSceneActive(phase == .active)
                }
        }
    }
}
