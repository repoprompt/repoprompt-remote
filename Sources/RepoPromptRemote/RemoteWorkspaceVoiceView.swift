import RepoPromptRemoteProtocol
import SwiftUI

struct RemoteWorkspaceVoiceView: View {
    @EnvironmentObject private var model: RemoteAppModel
    @EnvironmentObject private var voice: RemoteWorkspaceVoiceController
    @Environment(\.dismiss) private var dismiss

    let scope: RemoteWorkspaceVoiceController.Scope?

    private var unavailableReason: String? {
        model.workspaceVoiceUnavailableReason(for: scope?.id)
    }

    var body: some View {
        VStack(spacing: 20) {
            header

            if let scope {
                Label(scope.name, systemImage: "folder")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary) }
            }

            switch voice.phase {
            case .idle:
                startContent(message: "Talk to any chat in this workspace.", title: "Start voice")
            case .connecting:
                ProgressView(voice.connectionMessage ?? "Connecting to Codex voice…")
                    .frame(maxHeight: .infinity)
                endButton("Cancel")
            case .connected:
                liveContent
                HStack(spacing: 12) {
                    Button {
                        voice.toggleMute()
                    } label: {
                        Image(systemName: voice.isMuted ? "mic.slash.fill" : "mic.fill")
                            .font(.title3.weight(.semibold))
                            .frame(minWidth: 70, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(voice.isMuted ? "Unmute microphone" : "Mute microphone")
                    endButton("End")
                }
            case let .failed(message):
                startContent(message: message, title: "Try again")
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 20)
        .presentationDetents(voice.phase == .connected ? [.fraction(0.68), .large] : [.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        HStack {
            Text("Workspace Voice")
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.callout.weight(.semibold))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Hide voice controls")
        }
    }

    private func startContent(message: String, title: String) -> some View {
        VStack(spacing: 20) {
            Spacer(minLength: 0)
            Text(unavailableReason ?? message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let scope, unavailableReason == nil {
                startButton(title, scope: scope)
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
    }

    private func startButton(_ title: String, scope: RemoteWorkspaceVoiceController.Scope) -> some View {
        Button {
            voice.start(in: scope, model: model)
        } label: {
            VStack(spacing: 10) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(Color.remoteWarmOrange, in: Circle())
                Text(title).font(.headline)
            }
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .disabled(voice.isEnding)
    }

    private var activityLabel: String {
        if let activity = voice.activity, activity != .listening {
            return activity.displayLabel
        }
        return voice.isMuted ? "Microphone muted" : voice.activity?.displayLabel ?? "Voice connected"
    }

    private var workingChatLabel: String? {
        guard let id = voice.workingChatID, let workspaceID = voice.scope?.id,
              let chat = model.snapshot?.sessions.first(where: { $0.sessionID == id && UUID(uuidString: $0.workspaceID) == workspaceID })
        else { return nil }
        let name = chat.sessionName ?? "Chat"
        if chat.pendingInteraction?.kind == .approval { return "\(name) is waiting for approval" }
        if chat.pendingInteraction != nil { return "\(name) needs your input" }
        return switch chat.runState {
        case .opening: "Opening \(name)…"
        case .working: "\(name) is working"
        case .waitingForInput, .blocked: "\(name) is waiting for input"
        case .completed: "\(name) finished"
        case .failed: "\(name) encountered an error"
        case .cancelled: "\(name) was cancelled"
        case .idle: nil
        }
    }

    private var liveContent: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform")
                .font(.system(size: 50, weight: .medium))
                .foregroundStyle(Color.remoteWarmOrange)
                .accessibilityHidden(true)
            Text(activityLabel)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            if let workingChatLabel {
                Text(workingChatLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(voice.transcript) { line in
                            Text(line.text)
                                .font(.callout)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(11)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                                .accessibilityLabel("\(line.speaker == .user ? "You" : "Workspace Voice"), \(line.text)")
                                .id(line.id)
                        }
                    }
                }
                .onChange(of: voice.transcript.last?.id) { _, id in
                    if let id { scroll.scrollTo(id, anchor: .bottom) }
                }
            }
        }
    }

    private func endButton(_ title: String) -> some View {
        Button(role: .destructive) {
            voice.end()
        } label: {
            Label(title, systemImage: "phone.down.fill")
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
    }
}
