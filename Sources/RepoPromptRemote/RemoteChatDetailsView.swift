import SwiftUI
import RepoPromptRemoteProtocol

struct RemoteChatDetailsView: View {
    @EnvironmentObject private var model: RemoteAppModel
    @Environment(\.dismiss) private var dismiss

    let session: SessionRow
    let onSelectSession: (UUID) -> Void

    private var workflow: RemoteWorkflowDescriptor? {
        if let workflowID = session.workflowID,
           let descriptor = model.workflowCatalog.first(where: { $0.id == workflowID }) {
            return descriptor
        }
        if let name = session.workflow {
            return model.workflowCatalog.first(where: { $0.displayName == name })
        }
        return nil
    }

    private var agentName: String? {
        guard let agent = session.agent else { return nil }
        return model.agentCatalog.first(where: { $0.id == agent })?.displayName ?? agent
    }

    var body: some View {
        NavigationStack {
            List {
                RemoteConnectionSection()

                Section("Run") {
                    HStack(spacing: 10) {
                        RemoteRunStateBadge(state: session.runState)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.status).font(.headline)
                        }
                    }
                    if let activity = session.latestMeaningfulActivity {
                        LabeledContent("Activity", value: activity)
                    }
                    if let started = session.runStartedAt {
                        LabeledContent("Started") {
                            Text(started, format: .dateTime.month().day().hour().minute())
                        }
                    }
                }

                if workflow != nil || session.workflow != nil {
                    Section("Workflow") {
                        if let workflow {
                            Label {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(workflow.displayName)
                                    if let description = workflow.descriptionText {
                                        Text(description)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            } icon: {
                                Image(systemName: workflow.iconName ?? "sparkles")
                                    .foregroundStyle(Color(remoteHex: workflow.accentColorHex) ?? .remoteWarmOrange)
                            }
                        } else if let legacyName = session.workflow {
                            LabeledContent("Workflow", value: legacyName)
                        }
                    }
                }

                Section("Agent") {
                    optionalContent("Agent", agentName)
                    optionalContent("Model", session.model)
                    optionalContent("Reasoning", session.reasoningEffort)
                }

                if session.worktreeSummary != nil || session.mergeAttention != nil {
                    Section("Workspace state") {
                        optionalLabel("Worktree", session.worktreeSummary, icon: "arrow.triangle.branch")
                        optionalLabel("Merge", session.mergeAttention, icon: "arrow.triangle.merge")
                    }
                }

                if let failure = session.failureSummary {
                    Section("Failure") {
                        Label(failure, systemImage: "exclamationmark.octagon.fill")
                            .foregroundStyle(Color.remoteFailure)
                    }
                }

                if session.parentSessionID != nil || !session.childSessionIDs.isEmpty {
                    Section("Lineage") {
                        if let parentID = session.parentSessionID {
                            lineageButton(id: parentID, relationship: "Parent", icon: "arrow.turn.up.left")
                        }
                        ForEach(session.childSessionIDs, id: \.self) { childID in
                            lineageButton(id: childID, relationship: "Child agent", icon: "arrow.turn.down.right")
                        }
                    }
                }
            }
            .navigationTitle("Chat details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func optionalContent(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty { LabeledContent(label, value: value) }
    }

    @ViewBuilder
    private func optionalLabel(_ label: String, _ value: String?, icon: String) -> some View {
        if let value, !value.isEmpty {
            Label {
                LabeledContent(label, value: value)
            } icon: {
                Image(systemName: icon)
            }
        }
    }

    private func lineageButton(id: UUID, relationship: String, icon: String) -> some View {
        let target = model.sessions.first(where: { $0.id == id })
        return Button {
            dismiss()
            onSelectSession(id)
        } label: {
            Label(target?.title ?? relationship, systemImage: icon)
        }
        .disabled(target == nil)
    }
}

/// The paired Mac and its connection state, shown at the top of the details sheet.
struct RemoteConnectionSection: View {
    @EnvironmentObject private var model: RemoteAppModel

    private var color: Color {
        if model.connectionState == .connected { return .green }
        return model.isRecovering ? .yellow : .red
    }

    var body: some View {
        Section("Mac") {
            HStack(spacing: 10) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                    .frame(width: 24)
                    .accessibilityHidden(true)
                Text(model.snapshot?.desktop.displayName ?? "Paired Mac")
                Spacer(minLength: 12)
                Text(model.pairingProgress ?? model.connectionStatusLabel)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
            if let lastSyncAt = model.lastSyncAt {
                LabeledContent("Last sync") {
                    Text(lastSyncAt, format: .dateTime.month().day().hour().minute())
                }
            }
            if model.connectionState != .connected {
                if let issue = model.connectionIssue {
                    Text(issue)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if !model.isRecovering {
                    Button("Reconnect", action: model.retryConnection)
                }
            }
        }
    }
}

struct RemoteRunStateBadge: View {
    let state: RemoteRunState

    var body: some View {
        Group {
            switch state {
            case .opening, .working:
                ProgressView().controlSize(.small).tint(Color.remoteWarmOrange)
            case .waitingForInput:
                Image(systemName: "hand.raised.circle.fill").foregroundStyle(Color.remoteSuccess)
            case .blocked:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.remoteWarmOrange)
            case .completed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.remoteSuccess)
            case .failed:
                Image(systemName: "xmark.octagon.fill").foregroundStyle(Color.remoteFailure)
            case .cancelled:
                Image(systemName: "xmark.circle").foregroundStyle(.secondary)
            case .idle:
                Image(systemName: "circle").foregroundStyle(.secondary)
            }
        }
        .frame(width: 24, height: 24)
    }
}
