import AVFoundation
import RepoPromptIrohTransport
import RepoPromptRemoteNetworking
import RepoPromptRemoteProtocol
import SwiftUI
import WebRTC

enum RemoteWorkspaceVoicePreference {
    static let storageKey = "workspaceVoice.preset"

    static var selectedPreset: RemoteWorkspaceVoicePreset? {
        UserDefaults.standard.string(forKey: storageKey).flatMap(RemoteWorkspaceVoicePreset.init(rawValue:))
    }
}

enum RemoteWorkspaceVoiceConnectionError: LocalizedError {
    case macUnavailable
    case microphoneDenied
    case peerUnavailable
    case timedOut
    case endedByMac(String?)

    var errorDescription: String? {
        switch self {
        case .macUnavailable: "Workspace Voice needs a connection to the paired Mac."
        case .microphoneDenied: "Allow microphone access for RepoPrompt Remote in Settings."
        case .peerUnavailable: "Could not connect the microphone and speaker to Codex voice."
        case .timedOut: "Workspace Voice took too long to connect."
        case let .endedByMac(message): message ?? "The Mac ended the voice call."
        }
    }
}

@MainActor
final class RemoteWorkspaceVoiceController: ObservableObject {
    struct Scope: Identifiable {
        let id: UUID
        let name: String

        init?(_ workspace: RemoteWorkspaceSummary) {
            guard let id = UUID(uuidString: workspace.workspaceID) else { return nil }
            self.id = id
            name = workspace.name
        }
    }

    enum Phase: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var scope: Scope?
    @Published private(set) var transcript: [RemoteWorkspaceVoiceLine] = []
    @Published private(set) var activity: RemoteWorkspaceVoiceActivity?
    @Published private(set) var workingChatID: UUID?
    @Published private(set) var connectionMessage: String?
    @Published private(set) var isMuted = false
    @Published private(set) var isEnding = false
    @Published private(set) var launchRequestedAt: Date?

    private weak var model: RemoteAppModel?
    private var activeCallID: UUID?
    private var operation: Task<Void, Never>?
    private var peer: RemoteWorkspaceVoicePeer?

    var isInCall: Bool { activeCallID != nil }

    func requestLaunch(from url: URL) {
        guard WorkspaceVoiceLaunchLink.matches(url) else { return }
        requestLaunch()
    }

    func requestLaunch() {
        launchRequestedAt = Date()
    }

    func consumeLaunchRequest() -> Bool {
        guard let requested = launchRequestedAt else { return false }
        launchRequestedAt = nil
        return (0 ... 30).contains(Date().timeIntervalSince(requested))
    }

    func start(in scope: Scope, model: RemoteAppModel) {
        guard !isInCall, !isEnding else { return }
        if let reason = model.workspaceVoiceUnavailableReason(for: scope.id) {
            phase = .failed(reason)
            return
        }

        let callID = UUID()
        self.scope = scope
        self.model = model
        activeCallID = callID
        phase = .connecting
        transcript = []
        activity = nil
        workingChatID = nil
        connectionMessage = nil
        isMuted = false
        model.setVoiceConnectionNeeded(true)
        let preset = RemoteWorkspaceVoicePreference.selectedPreset
        operation = Task { [weak self, weak model] in
            guard let self, let model else { return }
            do {
                try await run(callID: callID, scope: scope, model: model, preset: preset)
            } catch {
                guard self.activeCallID == callID else { return }
                finish(.failed(error.localizedDescription))
            }
        }
    }

    func toggleMute() {
        guard phase == .connected, let peer else { return }
        isMuted.toggle()
        peer.setMuted(isMuted)
    }

    func end() {
        finish(.idle)
    }

    private func finish(_ nextPhase: Phase) {
        guard let callID = activeCallID, let scope else {
            if !isEnding { phase = nextPhase }
            return
        }
        activeCallID = nil
        operation?.cancel()
        operation = nil
        peer?.close()
        peer = nil
        isMuted = false
        activity = nil
        workingChatID = nil
        connectionMessage = nil
        phase = nextPhase
        isEnding = true
        let model = model
        Task { [weak self] in
            _ = try? await model?.workspaceVoice(.init(action: .end, callID: callID, workspaceID: scope.id))
            model?.setVoiceConnectionNeeded(false)
            self?.isEnding = false
        }
    }

    private func run(
        callID: UUID, scope: Scope, model: RemoteAppModel, preset: RemoteWorkspaceVoicePreset?
    ) async throws {
        guard await AVAudioApplication.requestRecordPermission() else {
            throw RemoteWorkspaceVoiceConnectionError.microphoneDenied
        }
        try Task.checkCancellation()

        let peer = RemoteWorkspaceVoicePeer()
        self.peer = peer
        let offer = try await peer.makeOffer()
        try Task.checkCancellation()
        var status = try await model.workspaceVoice(.init(
            action: .start, callID: callID, workspaceID: scope.id, offerSDP: offer, voice: preset
        ))

        let clock = ContinuousClock()
        let setupDeadline = clock.now + .seconds(50)
        var mediaDeadline: ContinuousClock.Instant?
        var lastContact = clock.now
        var receivedAnswer = false

        while true {
            try Task.checkCancellation()
            switch status.phase {
            case .ready:
                if connectionMessage != nil { connectionMessage = nil }
                if !receivedAnswer {
                    guard let answer = status.answerSDP else { throw RemoteGatewayError.invalidResponse }
                    try await peer.accept(answer: answer)
                    try Task.checkCancellation()
                    receivedAnswer = true
                    mediaDeadline = clock.now + .seconds(12)
                }
                if transcript != status.lines { transcript = status.lines }
                if activity != status.activity { activity = status.activity }
                if workingChatID != status.workingChatID { workingChatID = status.workingChatID }
            case .connecting:
                if connectionMessage != status.message { connectionMessage = status.message }
            case .ended:
                finish(.idle)
                return
            case .failed:
                throw RemoteWorkspaceVoiceConnectionError.endedByMac(status.message)
            }

            switch peer.connectionState {
            case .connected:
                if phase != .connected { phase = .connected }
                mediaDeadline = nil
            case .failed, .closed:
                throw RemoteWorkspaceVoiceConnectionError.peerUnavailable
            case .disconnected:
                if mediaDeadline == nil { mediaDeadline = clock.now + .seconds(12) }
                if phase != .connecting { phase = .connecting }
            default:
                break
            }
            if (!receivedAnswer && clock.now > setupDeadline) || (mediaDeadline.map { clock.now > $0 } == true) {
                throw RemoteWorkspaceVoiceConnectionError.timedOut
            }
            try await Task.sleep(for: phase == .connected ? .milliseconds(600) : .milliseconds(350))

            do {
                status = try await model.workspaceVoice(.init(action: .status, callID: callID, workspaceID: scope.id))
                lastContact = clock.now
            } catch {
                if !isTransient(error) || clock.now - lastContact >= .seconds(15) { throw error }
            }
        }
    }

    private func isTransient(_ error: Error) -> Bool {
        if error is URLError || error is RemoteWorkspaceVoiceConnectionError { return true }
        if let gatewayError = error as? RemoteGatewayError,
           case let .requestRejected(response) = gatewayError { return response.retryable == true }
        return error is RemoteIrohTransportError
    }
}

@MainActor
private final class RemoteWorkspaceVoicePeer {
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        let audio = RTCAudioSessionConfiguration.webRTC()
        audio.mode = AVAudioSession.Mode.voiceChat.rawValue
        audio.categoryOptions.insert(.defaultToSpeaker)
        RTCAudioSessionConfiguration.setWebRTC(audio)
        return RTCPeerConnectionFactory()
    }()

    private var peer: RTCPeerConnection?
    private var microphone: RTCAudioTrack?
    private var events: RTCDataChannel?

    var connectionState: RTCPeerConnectionState { peer?.connectionState ?? .closed }

    func makeOffer() async throws -> String {
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let factory = Self.factory
        guard let peer = factory.peerConnection(with: configuration, constraints: constraints, delegate: nil) else {
            throw RemoteWorkspaceVoiceConnectionError.peerUnavailable
        }
        self.peer = peer

        let source = factory.audioSource(with: constraints)
        let microphone = factory.audioTrack(with: source, trackId: "repoprompt-microphone")
        microphone.isEnabled = false
        self.microphone = microphone
        guard peer.add(microphone, streamIds: ["workspace-voice"]) != nil,
              let events = peer.dataChannel(forLabel: "oai-events", configuration: RTCDataChannelConfiguration())
        else { throw RemoteWorkspaceVoiceConnectionError.peerUnavailable }
        self.events = events

        let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            peer.offer(for: constraints) { description, error in
                if let description { continuation.resume(returning: description) }
                else { continuation.resume(throwing: error ?? RemoteWorkspaceVoiceConnectionError.peerUnavailable) }
            }
        }
        try await peer.setLocalDescription(offer)
        // The signaling RPC exchanges one offer and answer. Include gathered
        // candidates in the offer without waiting indefinitely for a slow interface.
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(2)
        while peer.iceGatheringState != .complete, clock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let sdp = peer.localDescription?.sdp else {
            throw RemoteWorkspaceVoiceConnectionError.peerUnavailable
        }
        return sdp
    }

    func accept(answer: String) async throws {
        guard let peer else { throw RemoteWorkspaceVoiceConnectionError.peerUnavailable }
        try await peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: answer))
        try Task.checkCancellation()
        microphone?.isEnabled = true
    }

    func setMuted(_ muted: Bool) {
        microphone?.isEnabled = !muted
    }

    func close() {
        microphone?.isEnabled = false
        events?.close()
        peer?.close()
        events = nil
        microphone = nil
        peer = nil
    }
}
