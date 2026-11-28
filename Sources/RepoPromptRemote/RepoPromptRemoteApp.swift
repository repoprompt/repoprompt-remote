import SwiftUI

@main
struct RepoPromptRemoteApp: App {
    @StateObject private var model = RemoteAppModel()
    @StateObject private var voice = RemoteWorkspaceVoiceController()
    @UIApplicationDelegateAdaptor(RemoteNotificationDelegate.self) private var notificationDelegate
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(WorkspaceVoiceLaunch.requestTimestampKey) private var voiceLaunchTimestamp: Double = 0

    init() {
        RemotePairingTelemetry.start()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .background { RemoteWindowAppearance() }
                .environmentObject(voice)
                .onOpenURL { voice.requestLaunch(from: $0) }
                .onChange(of: voiceLaunchTimestamp, initial: true) { _, timestamp in
                    guard timestamp != 0 else { return }
                    voiceLaunchTimestamp = 0
                    if (0 ... 30).contains(Date().timeIntervalSince1970 - timestamp) {
                        voice.requestLaunch()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    model.setSceneActive(phase == .active)
                }
                .onChange(of: model.connectionState) { _, state in
                    if state == .unpaired { voice.end() }
                }
        }
    }
}
