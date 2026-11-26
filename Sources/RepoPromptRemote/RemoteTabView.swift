import RepoPromptRemoteNetworking
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
            .foregroundStyle(Color.remoteFailure)
            .multilineTextAlignment(.leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .shadow(radius: 4, y: 2)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct PermissionsView: View {
    @EnvironmentObject private var model: RemoteAppModel
    @AppStorage(RemoteAppearance.storageKey) private var appearance = RemoteAppearance.system

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(RemoteAppearance.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)
                }

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
                        TextField("Relay URL (optional)", text: $model.notificationRelayURL, prompt: Text(""))
                            .remoteInputPrompt("Relay URL (optional)", isEmpty: model.notificationRelayURL.isEmpty)
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
                                Text(error).font(.caption).foregroundStyle(Color.remoteFailure)
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

                Section {
                    if let entry = model.reconnectHistory.last {
                        LabeledContent("Last attempt", value: entry.startedAt, format: .dateTime.hour().minute().second())
                        if let reason = entry.reason {
                            LabeledContent("Outcome", value: reason.rawValue.replacingOccurrences(of: "_", with: " ").capitalized)
                        } else {
                            LabeledContent("Outcome", value: "Connected")
                        }
                        if let report = RemoteReconnectDiagnostics.report(model.reconnectHistory) {
                            ShareLink(item: report) {
                                Label("Share connection diagnostics", systemImage: "square.and.arrow.up")
                            }
                        }
                    } else {
                        Text("No reconnect attempts recorded yet.")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Connection diagnostics")
                } footer: {
                    Text("The last 30 attempts are stored on this phone, including when offline.")
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
