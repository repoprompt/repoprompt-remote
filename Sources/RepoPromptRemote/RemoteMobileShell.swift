import SwiftUI
import RepoPromptRemoteProtocol

/// Active phone route: one conversation surface with a project/session drawer and
/// an in-navigation workflow launch state. Authoritative state remains in
/// `RemoteAppModel`; this view owns only navigation presentation.
struct RemoteMobileShell: View {
    @EnvironmentObject private var model: RemoteAppModel
    @State private var drawerIsOpen = false
    @State private var selectedWorkspaceID: String?
    @State private var selectedSessionID: UUID?
    @State private var allowsInitialChatSelection = true
    @State private var showingWorkflowLaunch = false
    @State private var showingSettings = false
    @State private var showingChatDetails = false
    @State private var showingConnectionDetails = false

    private var preferredWorkspace: RemoteWorkspaceSummary? {
        model.workspaces.first(where: \.isOpen) ?? model.workspaces.first
    }

    private var selectedWorkspace: RemoteWorkspaceSummary? {
        guard let selectedWorkspaceID else { return preferredWorkspace }
        return model.workspaces.first(where: { $0.workspaceID == selectedWorkspaceID }) ?? preferredWorkspace
    }

    private var chats: [RemoteChatListItem] {
        guard let workspaceID = selectedWorkspace?.workspaceID else { return [] }
        return model.chatList(for: workspaceID)
    }

    private var navigationRows: [RemoteSessionNavigationRow] {
        guard let workspaceID = selectedWorkspace?.workspaceID else { return [] }
        return model.navigationRows(for: workspaceID, selectedSessionID: selectedSessionID)
    }

    private var history: RemoteWorkspaceHistory? {
        selectedWorkspace.flatMap { model.workspaceHistory[$0.workspaceID] }
    }

    private var selectedChat: RemoteChatListItem? {
        guard let selectedSessionID else { return nil }
        return chats.first(where: { $0.id == selectedSessionID })
    }

    var body: some View {
        ZStack(alignment: .leading) {
            NavigationStack {
                VStack(spacing: 0) {
                    if let error = model.transientError {
                        RemoteErrorBanner(message: error)
                            .padding(.horizontal, 12)
                    }
                    if showingWorkflowLaunch, let workspace = selectedWorkspace {
                        RemoteWorkflowLaunchView(workspace: workspace, onCancel: closeWorkflowLaunch)
                            .id(workspace.workspaceID)
                            .environmentObject(model)
                    } else if let chat = selectedChat {
                        if chat.isProvisional {
                            MobileProvisionalSessionView(
                                title: chat.title,
                                onRetry: { model.refreshRemoteState() }
                            )
                        } else {
                            RemoteChatView(
                                sessionID: chat.id,
                                workspaceID: chat.workspaceID,
                                title: chat.title,
                                initialRunState: chat.runState
                            )
                            .id(chat.id)
                            .environmentObject(model)
                        }
                    } else {
                        MobileProjectEmptyView(
                            workspaceName: selectedWorkspace?.name,
                            historyPhase: history?.phase,
                            hasChats: !chats.isEmpty,
                            onShowChats: openDrawer,
                            onRetry: model.retryChatList,
                            onNewSession: openWorkflowLaunch
                        )
                    }
                }
                .navigationTitle(navigationTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button(action: openDrawer) {
                            Image(systemName: "line.3.horizontal")
                                .font(.body.weight(.semibold))
                        }
                        .accessibilityLabel("Open projects and chats")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 12) {
                            connectionIndicator
                            if !showingWorkflowLaunch {
                                if let session = model.sessions.first(where: { $0.id == selectedSessionID }) {
                                    Button { showingChatDetails = true } label: {
                                        Image(systemName: "info.circle")
                                    }
                                    .accessibilityLabel("Chat details, \(session.status)")
                                }
                                Button(action: openWorkflowLaunch) {
                                    Image(systemName: "square.and.pencil")
                                        .font(.body.weight(.semibold))
                                        .frame(width: 32, height: 32, alignment: .center)
                                }
                                .accessibilityLabel("New session")
                                .disabled(selectedWorkspace == nil)
                            }
                        }
                    }
                }
            }

            if drawerIsOpen {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { closeDrawer() }

                RemoteNavigationDrawer(
                    selectedWorkspace: selectedWorkspace,
                    historyPhase: history?.phase,
                    rows: navigationRows,
                    selectedSessionID: selectedSessionID,
                    onSelectWorkspace: selectWorkspace,
                    onSelectChat: selectChat,
                    onNewSession: {
                        closeDrawer()
                        openWorkflowLaunch()
                    },
                    onSettings: {
                        closeDrawer()
                        showingSettings = true
                    },
                    onClose: closeDrawer
                )
                .environmentObject(model)
                .transition(.move(edge: .leading))
                .zIndex(1)
            }
        }
        .sheet(isPresented: $showingSettings) {
            PermissionsView().environmentObject(model)
        }
        .sheet(isPresented: $showingChatDetails) {
            if let session = model.sessions.first(where: { $0.id == selectedSessionID }) {
                RemoteChatDetailsView(session: session, onSelectSession: selectSession(id:))
                    .environmentObject(model)
            }
        }
        .onAppear {
            synchronizeSelection()
            routePendingSessionIfResolvable()
            model.setVisibleSessionID(showingWorkflowLaunch ? nil : selectedSessionID)
        }
        .onChange(of: model.workspaces) { _, _ in
            synchronizeSelection()
            routePendingSessionIfResolvable()
        }
        .onChange(of: model.sessions) { _, _ in
            synchronizeSelection()
            routePendingSessionIfResolvable()
        }
        .onChange(of: selectedWorkspace?.workspaceID, initial: true) { _, workspaceID in
            model.selectHistoryWorkspace(workspaceID)
        }
        .onChange(of: history?.entries) { _, _ in
            synchronizeSelection()
            routePendingSessionIfResolvable()
        }
        .onChange(of: model.pendingSessionID) { _, _ in
            routePendingSessionIfResolvable()
        }
        .onChange(of: selectedSessionID) { _, sessionID in
            model.setVisibleSessionID(showingWorkflowLaunch ? nil : sessionID)
        }
    }

    private var navigationTitle: String {
        if showingWorkflowLaunch { return "New chat" }
        return selectedChat?.title ?? selectedWorkspace?.name ?? "RepoPrompt Remote"
    }

    private func routePendingSessionIfResolvable() {
        guard let pendingID = model.pendingSessionID,
              let workspaceID = model.workspaceID(forPendingSessionID: pendingID)
        else { return }
        showingWorkflowLaunch = false
        allowsInitialChatSelection = false
        selectedWorkspaceID = workspaceID
        selectedSessionID = pendingID
        model.setVisibleSessionID(pendingID)
        drawerIsOpen = false
        _ = model.consumePendingSessionID()
    }

    private func synchronizeSelection() {
        let workspace = selectedWorkspace ?? preferredWorkspace
        selectedWorkspaceID = workspace?.workspaceID
        let availableChats = workspace.map { model.chatList(for: $0.workspaceID) } ?? []
        selectedSessionID = RemoteSessionNavigationProjection.selectionID(
            current: selectedSessionID,
            chatIDs: availableChats.map(\.id),
            allowsInitialSelection: allowsInitialChatSelection && !drawerIsOpen && !showingWorkflowLaunch
        )
        if selectedSessionID != nil { allowsInitialChatSelection = false }
    }

    private func selectWorkspace(_ workspaceID: String) {
        if selectedWorkspace?.workspaceID == workspaceID {
            model.refreshChatList()
            return
        }
        allowsInitialChatSelection = false
        selectedWorkspaceID = workspaceID
        showingWorkflowLaunch = false
        selectedSessionID = nil
        model.setVisibleSessionID(nil)
    }

    private func selectChat(_ chat: RemoteChatListItem) {
        allowsInitialChatSelection = false
        selectedWorkspaceID = chat.workspaceID
        selectedSessionID = chat.id
        showingWorkflowLaunch = false
        model.setVisibleSessionID(chat.id)
        closeDrawer()
    }

    private func selectSession(id: UUID) {
        guard let chat = chats.first(where: { $0.id == id }) else { return }
        selectChat(chat)
    }

    private func openWorkflowLaunch() {
        guard selectedWorkspace != nil else { return }
        showingWorkflowLaunch = true
        model.setVisibleSessionID(nil)
    }

    private func closeWorkflowLaunch() {
        showingWorkflowLaunch = false
        model.setVisibleSessionID(selectedSessionID)
    }

    private func openDrawer() {
        withAnimation(.easeOut(duration: 0.22)) { drawerIsOpen = true }
    }

    private func closeDrawer() {
        withAnimation(.easeOut(duration: 0.22)) { drawerIsOpen = false }
    }

    private var connectionTitle: String {
        model.pairingProgress ?? model.connectionStatusLabel
    }

    private var connectionColor: Color {
        if model.connectionState == .connected { return .green }
        if model.isRecovering { return .yellow }
        return .red
    }

    private var connectionIndicator: some View {
        Button {
            showingConnectionDetails = true
        } label: {
            Circle()
                .fill(connectionColor)
                .frame(width: 9, height: 9)
                .frame(width: 32, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Connection status")
        .accessibilityValue(connectionTitle)
        .accessibilityHint("Shows connection details")
        .popover(isPresented: $showingConnectionDetails) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(connectionColor)
                        .frame(width: 8, height: 8)
                        .accessibilityHidden(true)
                    Text(connectionTitle).font(.subheadline.weight(.semibold))
                }
                if model.connectionState != .connected, model.snapshot != nil {
                    Text("Showing last sync").font(.footnote).foregroundStyle(.secondary)
                }
                if model.connectionState != .connected {
                    if let issue = model.connectionIssue {
                        Text(issue).font(.footnote).foregroundStyle(.secondary)
                    }
                    if !model.isRecovering {
                        Button("Reconnect") { model.retryConnection() }.font(.footnote.weight(.medium))
                    }
                }
            }
            .padding(16)
            .frame(idealWidth: 220, maxWidth: 260, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .presentationCompactAdaptation(.popover)
        }
    }

}

private struct MobileProvisionalSessionView: View {
    let title: String
    let onRetry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: "arrow.triangle.2.circlepath")
        } description: {
            Text("The run was accepted. Waiting for the Mac to publish the authoritative session state.")
        } actions: {
            Button("Retry", action: onRetry).buttonStyle(.bordered)
        }
    }
}

private struct MobileProjectEmptyView: View {
    let workspaceName: String?
    let historyPhase: RemoteWorkspaceHistory.Phase?
    let hasChats: Bool
    let onShowChats: () -> Void
    let onRetry: () -> Void
    let onNewSession: () -> Void

    var body: some View {
        if !hasChats, workspaceName != nil, historyPhase == nil || historyPhase == .loading {
            ProgressView("Loading saved chats…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label(workspaceName ?? "No project selected", systemImage: "bubble.left.and.bubble.right")
            } description: {
                Text(description)
            } actions: {
                if hasChats {
                    Button("Show chats", action: onShowChats).buttonStyle(.borderedProminent)
                } else if historyPhase == .failed {
                    Button("Retry", action: onRetry).buttonStyle(.borderedProminent)
                } else if workspaceName != nil {
                    Button("New session", action: onNewSession).buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var description: String {
        guard workspaceName != nil else { return "Pair with your Mac to load projects and chats." }
        if hasChats { return "Choose a chat to continue." }
        switch historyPhase {
        case .failed?: return "The Mac could not load this project’s saved chats."
        case .limited?: return "Update RepoPrompt on the Mac to see all saved chats."
        default: return "There are no saved chats in this project yet."
        }
    }
}

private struct RemoteNavigationDrawer: View {
    @EnvironmentObject private var model: RemoteAppModel
    let selectedWorkspace: RemoteWorkspaceSummary?
    let historyPhase: RemoteWorkspaceHistory.Phase?
    let rows: [RemoteSessionNavigationRow]
    let selectedSessionID: UUID?
    let onSelectWorkspace: (String) -> Void
    let onSelectChat: (RemoteChatListItem) -> Void
    let onNewSession: () -> Void
    let onSettings: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Workspace")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(1.2)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("Close navigation")
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 12)

            workspaceMenu

            Divider().padding(.vertical, 16)

            HStack {
                Text("Chats")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .tracking(1.2)
                Spacer()
                Button(action: onNewSession) {
                    Image(systemName: "plus")
                        .font(.footnote.weight(.bold))
                        .frame(width: 32, height: 32)
                }
                .accessibilityLabel("New session")
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 6)

            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 1) {
                    ForEach(rows) { row in
                        Button { onSelectChat(row.item) } label: {
                            MobileSessionDrawerRow(row: row, isSelected: selectedSessionID == row.id)
                        }
                        .buttonStyle(.plain)
                    }

                    historyFooter
                }
            }
            .id(selectedWorkspace?.workspaceID)

            Spacer(minLength: 16)
            connectionFooter
        }
        .padding(.top, 12)
        .padding(.horizontal, 16)
        .padding(.bottom, 14)
        .frame(maxWidth: 350)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
        .overlay(alignment: .trailing) { Rectangle().fill(.quaternary).frame(width: 1) }
        .shadow(color: .black.opacity(0.18), radius: 24, x: 10, y: 0)
    }

    @ViewBuilder
    private var historyFooter: some View {
        switch historyPhase {
        case .loading?, nil:
            if selectedWorkspace != nil {
                ProgressView("Loading saved chats…")
                    .controlSize(.small)
                    .padding(8)
            }
        case .failed?:
            Button("Retry loading saved chats", action: model.retryChatList)
                .font(.footnote)
                .padding(8)
        case .limited?:
            Text("Update the Mac to see all saved chats.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(8)
        default:
            if rows.isEmpty {
                Text("No chats in this project yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(8)
            }
        }
    }

    private var workspaceMenu: some View {
        Menu {
            ForEach(model.workspaces, id: \.workspaceID) { workspace in
                Button { onSelectWorkspace(workspace.workspaceID) } label: {
                    Label(workspace.name, systemImage: workspace.isOpen ? "folder.fill" : "folder")
                }
            }
        } label: {
            HStack(spacing: 10) {
                WorkspaceMark(isOpen: selectedWorkspace?.isOpen == true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Project").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(selectedWorkspace?.name ?? "Choose a project")
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.down").font(.caption.weight(.bold)).foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).stroke(.quaternary, lineWidth: 1) }
        }
        .disabled(model.workspaces.isEmpty)
    }

    private var connectionFooter: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Circle()
                    .fill(model.connectionState == .connected ? Color.remoteSuccess : Color.remoteWarmOrange)
                    .frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.snapshot?.desktop.displayName ?? "Paired Mac")
                        .font(.footnote.weight(.semibold)).lineLimit(1)
                    Text(model.connectionStatusLabel)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))

            Button(action: onSettings) {
                HStack(spacing: 10) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 28, height: 28)
                    Text("Settings")
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .frame(minHeight: 42)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .font(.subheadline.weight(.medium))
    }
}

private struct MobileSessionDrawerRow: View {
    let row: RemoteSessionNavigationRow
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            RemoteSessionStatusPlate(row: row)
            Text(row.item.title)
                .font(.subheadline.weight(isSelected ? .semibold : .medium))
                .lineLimit(1)
        }
        .padding(.leading, CGFloat(min(row.depth, 5)) * 12)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .contentShape(Rectangle())
        .background(isSelected ? Color.remoteWarmOrange.opacity(0.13) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct WorkspaceMark: View {
    let isOpen: Bool

    var body: some View {
        Image(systemName: isOpen ? "folder.fill" : "folder")
            .font(.title3.weight(.semibold))
            .foregroundStyle(Color.remoteWarmOrange)
            .frame(width: 34, height: 34)
            .background(Color.remoteWarmOrange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}
