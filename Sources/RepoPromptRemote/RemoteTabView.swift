import SwiftUI

/// The tab entry intentionally contains only the active phone shell. The former
/// project/chat/modal-new-chat surfaces were bypassed by `RootView` and have been
/// removed so parity work cannot silently land on an inactive route.
struct RemoteTabView: View {
    var body: some View {
        RemoteMobileShell()
    }
}

struct RemoteErrorBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.white)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.red, in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 4, y: 2)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct PermissionsView: View {
    @EnvironmentObject private var model: RemoteAppModel

    var body: some View {
        NavigationStack {
            Form {
                if model.isPaired {
                    Section {
                        LabeledContent(
                            "Desktop authority",
                            value: model.snapshot.map {
                                RemoteAppModel.Authority($0.authorization.defaultLevel).rawValue.capitalized
                            } ?? "Unknown"
                        )
                    } footer: {
                        Text("Your Mac enforces authorization for every command. Change it on the Mac; the phone cannot elevate itself.")
                    }

                    Section("Pairing") {
                        LabeledContent(
                            "Status",
                            value: model.connectionStatusLabel
                        )
                        if model.connectionState != .connected {
                            Button("Reconnect") { model.retryConnection() }
                        }
                        Button("Unpair", role: .destructive) { model.unpair() }
                    }

                    Section {
                        TextField("Relay URL (optional)", text: $model.notificationRelayURL)
                            .textInputAutocapitalization(.never)
                            .keyboardType(.URL)
                            .autocorrectionDisabled()
                        Button("Enable attention notifications") { model.enableNotifications() }
                        LabeledContent("Status", value: model.notificationStatus)
                    } header: {
                        Text("Notifications")
                    } footer: {
                        Text("The relay receives only encrypted notification bytes and routing metadata. Leave the URL blank when no relay is configured.")
                    }

                    if let diagnostics = model.diagnostics {
                        Section("Diagnostics") {
                            LabeledContent("Connection", value: model.lastConnectionEvent)
                            LabeledContent("Transport", value: model.transportStatus)
                            if model.transportStatus == "Iroh" {
                                LabeledContent("Iroh path", value: model.irohPathStatus)
                            }
                            LabeledContent("Network", value: model.networkStatus)
                            LabeledContent(
                                "Last snapshot",
                                value: diagnostics.lastSnapshotAt.map { Self.dateFormatter.string(from: $0) } ?? "Never"
                            )
                            if let error = diagnostics.notificationLastError {
                                Text(error).font(.caption).foregroundStyle(.red)
                            }
                            Button("Refresh diagnostics") { model.refreshDiagnostics() }
                        }
                    }
                } else {
                    Section {
                        Button { model.beginPairing() } label: {
                            Label("Pair with Mac", systemImage: "qrcode.viewfinder")
                        }
                    } footer: {
                        Text("Scan the pairing code shown in RepoPrompt Settings on your Mac.")
                    }
                }
            }
            .navigationTitle("Settings")
            .task {
                if model.isPaired { model.refreshDiagnostics() }
            }
        }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
}
