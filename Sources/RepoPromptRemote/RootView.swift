import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: RemoteAppModel

    var body: some View {
        Group {
            if model.isPaired {
                RemoteTabView()
            } else {
                PairingView()
            }
        }
        .tint(Color.remoteWarmOrange)
        .sheet(isPresented: $model.showingPairing, onDismiss: {
            model.cancelPairing()
        }) {
            PairingScannerScreen()
                .environmentObject(model)
        }
    }
}

struct PairingView: View {
    @EnvironmentObject private var model: RemoteAppModel
    @State private var showingResetConfirmation = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()

                Image("RemoteWelcomeIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 104, height: 104)
                    .clipShape(RoundedRectangle(cornerRadius: 23, style: .continuous))
                    .shadow(color: .black.opacity(0.22), radius: 12, y: 6)

                VStack(spacing: 8) {
                    Text("RepoPrompt Remote")
                        .font(.largeTitle.bold())
                    Text("Pair with your Mac to supervise and control RepoPrompt agents.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 14) {
                    PairingStep(number: "1", title: "Show the pairing code", detail: "In RepoPrompt on your Mac, open Settings → Remote and enable pairing.")
                    PairingStep(number: "2", title: "Scan the code", detail: "Point your camera at the code shown on your Mac.")
                    PairingStep(number: "3", title: "Use your Mac remotely", detail: "Your Mac remains in control while you supervise its projects and agents.")
                }
                .padding()
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18))

                if let issue = model.connectionIssue {
                    RemoteErrorBanner(message: issue)
                }

                if model.pairingStorageUnavailable {
                    Button("Retry Keychain") { model.retryConnection() }
                        .buttonStyle(.borderedProminent)
                    Button("Reset local pairing", role: .destructive) { showingResetConfirmation = true }
                } else if model.hasPendingPairing {
                    VStack(spacing: 10) {
                        if let progress = model.pairingProgress {
                            ProgressView(progress)
                        } else if model.isRecovering {
                            ProgressView("Retrying pairing…")
                        }
                        if model.connectionIssue != nil {
                            Button("Retry pairing") { model.retryConnection() }
                                .buttonStyle(.borderedProminent)
                        }
                        if model.canCancelPendingPairing {
                            Button("Scan another code") {
                                model.cancelPendingPairing()
                                model.beginPairing()
                            }
                        } else if model.connectionIssue != nil, model.canResetPendingConfirmation {
                            Button("Reset local pairing", role: .destructive) {
                                showingResetConfirmation = true
                            }
                        }
                    }
                } else {
                    Button {
                        model.beginPairing()
                    } label: {
                        Label("Pair with Mac", systemImage: "qrcode.viewfinder")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }

                Spacer()
            }
            .padding(24)
            .confirmationDialog("Reset pairing on this phone?", isPresented: $showingResetConfirmation) {
                Button("Reset local pairing", role: .destructive) {
                    if model.pairingStorageUnavailable {
                        model.resetPairingStorage()
                    } else {
                        model.resetPendingConfirmation()
                    }
                }
            } message: {
                Text("Check Mac Settings first. If the Mac already lists this phone as paired, unpair it there before generating another code.")
            }
        }
    }
}

private struct PairingStep: View {
    let number: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.caption.bold())
                .foregroundStyle(.black)
                .frame(width: 24, height: 24)
                .background(Color.remoteOrangeFill, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

private struct PairingScannerScreen: View {
    @EnvironmentObject private var model: RemoteAppModel
    @Environment(\.dismiss) private var dismiss
#if DEBUG
    @State private var manualPairingValue = ""
#endif

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                PairingScannerView(
                    onCode: { model.handleQRCode($0) },
                    onFailure: { model.presentError($0) }
                )
                .id(model.scannerGeneration)
                .ignoresSafeArea()

                VStack(spacing: 8) {
                    Text("Scan the pairing code shown in RepoPrompt Settings → Remote.")
                        .font(.footnote.weight(.semibold))
                        .multilineTextAlignment(.center)
#if DEBUG
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Debug pairing")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        HStack {
                            SecureField("Paste rpremote:// pairing link", text: $manualPairingValue)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .privacySensitive()
                                .onSubmit(submitManualPairing)
                            Button("Pair", action: submitManualPairing)
                                .disabled(manualPairingValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
#endif
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let error = model.transientError {
                    RemoteErrorBanner(message: error)
                        .padding(.top, 8)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 8)
                }
            }
            .navigationTitle("Pair with Mac")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        model.cancelPairing()
                        dismiss()
                    }
                }
            }
        }
    }

#if DEBUG
    private func submitManualPairing() {
        let value = manualPairingValue
        manualPairingValue = ""
        model.handleQRCode(value)
    }
#endif
}
