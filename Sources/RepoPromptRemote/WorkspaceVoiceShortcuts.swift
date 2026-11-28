import AppIntents
import Foundation

enum WorkspaceVoiceLaunch {
    static let requestTimestampKey = "RepoPromptRemote.workspaceVoiceLaunchTimestamp"
}

struct StartWorkspaceVoiceIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Workspace Voice"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: WorkspaceVoiceLaunch.requestTimestampKey)
        return .result()
    }
}

struct RepoPromptRemoteShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartWorkspaceVoiceIntent(),
            phrases: [
                "Talk to \(.applicationName)",
                "Start workspace voice in \(.applicationName)"
            ],
            shortTitle: "Start Voice",
            systemImageName: "waveform"
        )
    }
}
