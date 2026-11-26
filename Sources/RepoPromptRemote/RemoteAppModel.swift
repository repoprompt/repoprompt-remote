import Combine
import Foundation
import Network
import OSLog
import RepoPromptIrohTransport
import RepoPromptRemoteNetworking
import RepoPromptRemoteProtocol
import UIKit

struct RemoteCommandCompletion: Equatable {
    enum Outcome: Equatable {
        case accepted
        case rejected
        case failed
    }

    let commandID: UUID
    let operation: RemoteCommandOperation
    let outcome: Outcome
}

struct RemoteCommandActivityState: Equatable {
    private(set) var inFlightIDs: Set<UUID> = []
    private(set) var completions: [UUID: RemoteCommandCompletion] = [:]

    mutating func begin(_ commandID: UUID) {
        inFlightIDs.insert(commandID)
    }

    mutating func end(_ commandID: UUID) {
        inFlightIDs.remove(commandID)
    }

    mutating func record(_ completion: RemoteCommandCompletion) {
        if completions[completion.commandID]?.outcome == .accepted {
            return
        }
        if completions.count >= 128 { completions.removeAll(keepingCapacity: true) }
        completions[completion.commandID] = completion
    }

    func completion(for commandID: UUID?) -> RemoteCommandCompletion? {
        commandID.flatMap { completions[$0] }
    }
}

struct RemoteAcceptedCommand: Equatable {
    let commandID: UUID
    let operation: RemoteCommandOperation
    let workspaceID: String?
    let sessionID: UUID?
    let runState: RemoteRunState?
    let resolvedSelection: RemoteAgentSelection?

    init(response: RemoteCommandResponse, operation: RemoteCommandOperation) {
        commandID = response.commandID
        self.operation = operation
        workspaceID = response.workspaceID
        sessionID = response.sessionID
        runState = response.runState
        resolvedSelection = response.resolvedSelection
    }
}

enum RemotePendingSessionRouteResolver {
    static func workspaceID(
        for sessionID: UUID,
        provisionalRoutes: [RemoteProvisionalSessionRoute],
        sessions: [RemoteSessionSummary],
        historyEntries: [RemoteHistoryEntry]
    ) -> String? {
        provisionalRoutes.first(where: { $0.sessionID == sessionID })?.workspaceID
            ?? sessions.first(where: { $0.sessionID == sessionID })?.workspaceID
            ?? historyEntries.first(where: { $0.id == sessionID })?.workspaceID
    }
}

struct RemoteProvisionalSessionRoute: Equatable {
    let sessionID: UUID
    let workspaceID: String
    let title: String
    let runState: RemoteRunState
    let createdAt: Date

    static func acceptedStart(
        response: RemoteCommandResponse,
        request: RemoteCommandRequest,
        now: Date = Date()
    ) -> Self? {
        guard response.accepted,
              request.operation == .startRun,
              let sessionID = response.sessionID,
              let workspaceID = response.workspaceID ?? request.workspaceID
        else { return nil }
        return Self(
            sessionID: sessionID,
            workspaceID: workspaceID,
            title: "New chat",
            runState: response.runState ?? .opening,
            createdAt: now
        )
    }
}

struct RemoteWorkspaceHistory: Equatable {
    enum Phase: Equatable {
        case loading
        case loaded
        case limited
        case failed
    }

    var entries: [RemoteHistoryEntry] = []
    var phase: Phase = .loading

    static func load(
        workspaceID: UUID,
        fetch: (RemoteHistoryRPCRequest) async throws -> RemoteHistoryPage
    ) async throws -> Self {
        var entries: [RemoteHistoryEntry] = []
        var seenSessions: Set<UUID> = []
        var before: RemoteHistoryCursor?

        while true {
            let page = try await fetch(.init(limit: 100, workspaceID: workspaceID, before: before))
            try Task.checkCancellation()
            let matchingEntries = page.entries.filter { UUID(uuidString: $0.workspaceID) == workspaceID }
            if page.workspaceID == nil, before == nil {
                // Older Macs ignore workspace scope and return one global page.
                return Self(entries: matchingEntries, phase: page.hasMore ? .limited : .loaded)
            }
            guard page.workspaceID == workspaceID, matchingEntries.count == page.entries.count else {
                throw RemoteGatewayError.invalidResponse
            }

            entries += matchingEntries.filter { seenSessions.insert($0.id).inserted }
            guard page.hasMore else { return Self(entries: entries, phase: .loaded) }
            guard let last = page.entries.last, let older = page.olderCursor,
                  older == RemoteHistoryCursor(lastActivityAt: last.lastActivityAt, sessionID: last.id),
                  before.map({ older < $0 }) ?? true
            else { throw RemoteGatewayError.invalidResponse }
            before = older
        }
    }
}

@MainActor
final class RemoteAppModel: ObservableObject {
    enum ConnectionState: Equatable {
        case unpaired
        case discovering
        case connected
        case disconnected
    }

    enum Authority: String, CaseIterable, Identifiable {
        case observe
        case respond
        case control
        case danger

        var id: String { rawValue }

        init(_ level: RemoteAuthorityLevel) {
            switch level {
            case .observe: self = .observe
            case .respond: self = .respond
            case .control: self = .control
            case .danger: self = .danger
            }
        }
    }

    @Published private(set) var connectionState: ConnectionState = .unpaired
    @Published var authority: Authority = .observe
    @Published var showingPairing = false
    @Published private(set) var transientError: String?
    @Published private(set) var commandActivity = RemoteCommandActivityState()
    @Published private(set) var lastCommandCompletion: RemoteCommandCompletion?
    @Published private(set) var lastAcceptedCommandID: UUID?
    @Published private(set) var lastAcceptedCommand: RemoteAcceptedCommand?
    @Published private(set) var snapshot: RemoteSnapshot?
    @Published private(set) var workspaceHistory: [String: RemoteWorkspaceHistory] = [:]
    enum TranscriptDetailState: Equatable {
        case loading
        case loaded
        case failed
    }

    @Published private(set) var transcriptDetailStates: [UUID: TranscriptDetailState] = [:]
    @Published private(set) var transcriptTimelinesBySessionID: [UUID: RemoteTranscriptTimelineState] = [:]
    @Published private(set) var unseenStateBySessionID: [UUID: RemoteSessionUnseenState] = [:]
    @Published private(set) var provisionalSessionRoutes: [UUID: RemoteProvisionalSessionRoute] = [:]
    @Published private(set) var selectionOverridesBySessionID: [UUID: RemoteAgentSelection] = [:]
    @Published private(set) var contextBuilderResult: RemoteContextBuilderResult?
    @Published private(set) var diagnostics: RemoteDiagnostics?
    @Published private(set) var notificationStatus: String = "Not configured"
    @Published private(set) var pendingSessionID: UUID?
    @Published private(set) var connectionIssue: String?
    @Published private(set) var pairingProgress: String?
    @Published private(set) var isRecovering = false
    @Published private(set) var pairingStorageUnavailable = false
    @Published private(set) var scannerGeneration = 0
    @Published private var pairingRecord: StoredRemotePairing?
    @Published private(set) var networkStatus: String = "Unknown"
    @Published private(set) var reconnectHistory: [RemoteReconnectDiagnostics.Entry]
    @Published private(set) var lastConnectionEvent: String = "Not connected"
    @Published private(set) var transportStatus: String = "None"
    @Published private(set) var irohPathStatus: String = "Unknown"
    @Published var notificationRelayURL: String {
        didSet { UserDefaults.standard.set(notificationRelayURL, forKey: Self.notificationRelayURLKey) }
    }

    struct ConnectionFactory {
        let prepare: (StoredRemotePairingAttempt, Data, UInt64, String, @MainActor () throws -> Void) async throws
            -> (StoredRemoteCredential, any RemoteConnectionCandidate)
        let open: (StoredRemoteCredential, Data, UInt64, inout RemoteReconnectDiagnostics.Attempt) async throws
            -> any RemoteConnectionCandidate

        static var live: Self {
            Self(
                prepare: { attempt, secret, generation, name, willSendLegacyHello in
                    try await RemoteIrohGatewayTransport.preparePairing(
                        attempt: attempt, identitySecret: secret, generation: generation, deviceName: name,
                        willSendLegacyHello: willSendLegacyHello
                    )
                },
                open: { stored, secret, generation, diagnostics in
                    try await RemoteIrohGatewayTransport.open(
                        stored: stored, identitySecret: secret, generation: generation, diagnostics: &diagnostics
                    )
                }
            )
        }
    }

    private static let notificationRelayURLKey = "RepoPromptRemote.notificationRelayURL"
    private static let connectionLogger = Logger(subsystem: "com.repoprompt.remote", category: "Connection")
    private static let unpairLogger = Logger(subsystem: "com.repoprompt.remote", category: "Unpair")
    private static let unpairDeadline: Duration = .seconds(5)
    private let credentialStore: any RemoteCredentialStoring
    private let irohIdentityStore: RemoteIrohIdentityStore
    private let connectionFactory: ConnectionFactory
    private var activeImageReads = 0
    private var waitingImageReads: [(UUID, CheckedContinuation<Void, Error>)] = []
    private let imageThumbnails: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()
    private var gateway: (any RemoteGatewayTransport)?
    private var storedCredential: StoredRemoteCredential? {
        if case let .paired(credential) = pairingRecord { return credential }
        return nil
    }
    private var reducer = RemoteSnapshotReducer()
    private var connectionTask: Task<Void, Never>?
    private var chatListTask: Task<Void, Never>?
    private var selectedHistoryWorkspaceID: String?
    private var unpairWork: RemoteUnpairWork?
    private var unpairWorkID: UUID?
    private var transcriptInitialTasks: [UUID: Task<Void, Never>] = [:]
    private var transcriptLatestTasks: [UUID: Task<Void, Never>] = [:]
    private var transcriptOlderTasks: [UUID: Task<Void, Never>] = [:]
    private var transcriptDetailTasks: [UUID: Task<Void, Never>] = [:]
    private var knownTranscriptRevisions: [UUID: UInt64] = [:]
    private var visibleSessionID: UUID?
    private var hasEstablishedSnapshot = false
    private var pendingNotificationDeviceToken: String?
    private var notificationObservers: [NSObjectProtocol] = []
    private var networkMonitor: RemoteNetworkMonitor?
    private var transientErrorTask: Task<Void, Never>?
    private var transientErrorID = UUID()
    private var activeConnectionAttemptID: UUID?
    private var authenticatedConnectionAttemptID: UUID?
    private var irohGeneration: UInt64 = 0
    private var isSceneActive = true
    private enum ObservedPath: Equatable {
        case usable(RemoteReconnectDiagnostics.Network)
        case requiresConnection
        case offline
    }

    private var appliedNetworkPath: ObservedPath?
    private var pendingNetworkPath: ObservedPath?
    private var networkPathTask: Task<Void, Never>?
    private var networkAvailable = true
    private var reconnectBackoff = RemoteConnectionBackoff()
    private var reconnectNetwork = RemoteReconnectDiagnostics.Network.unknown
    private var reconnectNetworkRevision = 0
    private var reconnectAttempt = 0
    private var recoveryStartedAt: ContinuousClock.Instant?
    private var reconnectLogSentAt: [RemoteReconnectDiagnostics.Outcome: ContinuousClock.Instant] = [:]
    private let reconnectHistoryDefaults: UserDefaults?
    private var automaticRecoveryPaused = false

    init(
        credentialStore: any RemoteCredentialStoring = RemoteCredentialStore(),
        irohIdentityStore: RemoteIrohIdentityStore = RemoteIrohIdentityStore(),
        connectionFactory: ConnectionFactory = .live,
        monitorNetwork: Bool = true,
        reconnectHistoryDefaults: UserDefaults? = .standard
    ) {
        self.credentialStore = credentialStore
        self.irohIdentityStore = irohIdentityStore
        self.connectionFactory = connectionFactory
        self.reconnectHistoryDefaults = reconnectHistoryDefaults
        let historyData = reconnectHistoryDefaults?.data(forKey: RemoteReconnectDiagnostics.historyKey) ?? Data()
        let history = (try? JSONDecoder().decode([RemoteReconnectDiagnostics.Entry].self, from: historyData)) ?? []
        reconnectHistory = Array(history.suffix(RemoteReconnectDiagnostics.historyLimit))
        notificationRelayURL = UserDefaults.standard.string(forKey: Self.notificationRelayURLKey) ?? ""
        notificationObservers = [
            NotificationCenter.default.addObserver(
                forName: RemoteNotificationDelegate.deviceTokenNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let token = notification.object as? String else { return }
                Task { @MainActor [weak self] in self?.handleDeviceToken(token) }
            },
            NotificationCenter.default.addObserver(
                forName: RemoteNotificationDelegate.receivedNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let userInfo = notification.object as? [AnyHashable: Any] else { return }
                Task { @MainActor [weak self] in self?.handleRemoteNotification(userInfo) }
            },
            NotificationCenter.default.addObserver(
                forName: RemoteNotificationDelegate.registrationErrorNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let message = notification.object as? String ?? "Notification registration failed."
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    notificationStatus = "Not configured"
                    presentError(message)
                }
            }
        ]
        if monitorNetwork {
            startNetworkMonitoring()
        }
        restorePairing()
    }

    private func startNetworkMonitoring() {
        networkMonitor = RemoteNetworkMonitor { [weak self] status, interface in
            self?.observeNetworkPath(status, interface: interface)
        }
        networkMonitor?.start()
    }

    func observeNetworkPath(_ status: NWPath.Status, interface: String) {
        let path: ObservedPath
        switch status {
        case .satisfied: path = .usable(.init(interface: interface))
        case .unsatisfied: path = .offline
        case .requiresConnection: path = .requiresConnection
        @unknown default: return
        }
        guard path != pendingNetworkPath else { return }
        networkPathTask?.cancel()
        networkPathTask = nil
        pendingNetworkPath = nil
        guard path != appliedNetworkPath else { return }
        if appliedNetworkPath == nil {
            applyNetworkPath(path)
            return
        }

        pendingNetworkPath = path
        let preserveConnection = connectionState == .connected || authenticatedConnectionAttemptID != nil
        let delay: Duration = path == .offline && preserveConnection ? .seconds(2) : .milliseconds(450)
        networkPathTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch { return }
            guard let self, pendingNetworkPath == path, !Task.isCancelled else { return }
            pendingNetworkPath = nil
            networkPathTask = nil
            applyNetworkPath(path)
        }
    }

    private func applyNetworkPath(_ path: ObservedPath) {
        let previousPath = appliedNetworkPath
        appliedNetworkPath = path
        reconnectNetworkRevision += 1
        switch path {
        case let .usable(network):
            reconnectNetwork = network
            networkAvailable = true
            networkStatus = "Online (\(network.rawValue))"
            // Let Iroh migrate an authenticated connection even during first sync.
            if previousPath != nil, connectionState != .connected, authenticatedConnectionAttemptID == nil {
                stopConnection()
            }
            startConnectionRecovery()
        case .offline:
            reconnectNetwork = .offline
            networkAvailable = false
            networkStatus = "Offline"
            stopConnection()
            if pairingRecord != nil {
                connectionIssue = "Network unavailable. Retrying when the phone is back online."
                lastConnectionEvent = "Network unavailable"
            }
        case .requiresConnection:
            reconnectNetwork = .unknown
            networkAvailable = true
            networkStatus = "Connection required"
            startConnectionRecovery()
        }
    }

    deinit {
        connectionTask?.cancel()
        chatListTask?.cancel()
        transcriptInitialTasks.values.forEach { $0.cancel() }
        transcriptLatestTasks.values.forEach { $0.cancel() }
        transcriptOlderTasks.values.forEach { $0.cancel() }
        transcriptDetailTasks.values.forEach { $0.cancel() }
        networkMonitor?.stop()
        networkPathTask?.cancel()
        transientErrorTask?.cancel()
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
    }

    var isPaired: Bool { storedCredential != nil }

    var hasPendingPairing: Bool { pairingRecord != nil && !isPaired }

    var canCancelPendingPairing: Bool {
        guard case let .preparing(attempt) = pairingRecord else { return false }
        return attempt.legacyHelloMayHaveBeenSent != true
    }

    var canResetPendingConfirmation: Bool {
        switch pairingRecord {
        case .confirming: true
        case let .preparing(attempt): attempt.legacyHelloMayHaveBeenSent == true
        default: false
        }
    }

    var connectionStatusLabel: String {
        if connectionState == .connected { return "Connected" }
        return isRecovering ? "Reconnecting…" : "Paired · Offline"
    }

    var isCommandInFlight: Bool {
        !commandActivity.inFlightIDs.isEmpty
    }

    func isCommandInFlight(_ commandID: UUID?) -> Bool {
        commandID.map(commandActivity.inFlightIDs.contains) ?? false
    }

    var sessions: [SessionRow] {
        snapshot?.sessions.map {
            SessionRow($0, selectionOverride: selectionOverridesBySessionID[$0.sessionID])
        } ?? []
    }

    func chatList(for workspaceID: String) -> [RemoteChatListItem] {
        RemoteChatListProjection.project(
            historyEntries: workspaceHistory[workspaceID]?.entries ?? [],
            sessions: sessions,
            provisionalRoutes: Array(provisionalSessionRoutes.values),
            workspaceID: workspaceID
        )
    }

    var transcriptItemsBySessionID: [UUID: [RemoteTranscriptItem]] {
        transcriptTimelinesBySessionID.mapValues(\.orderedItems)
    }

    func navigationRows(
        for workspaceID: String,
        selectedSessionID: UUID?
    ) -> [RemoteSessionNavigationRow] {
        RemoteSessionNavigationProjection.project(
            items: chatList(for: workspaceID),
            sessions: snapshot?.sessions.filter { $0.workspaceID == workspaceID } ?? [],
            selectedSessionID: selectedSessionID,
            unseenBySessionID: unseenStateBySessionID
        )
    }

    func workspaceID(forPendingSessionID sessionID: UUID) -> String? {
        RemotePendingSessionRouteResolver.workspaceID(
            for: sessionID,
            provisionalRoutes: Array(provisionalSessionRoutes.values),
            sessions: snapshot?.sessions ?? [],
            historyEntries: workspaceHistory.values.flatMap(\.entries)
        )
    }

    func setVisibleSessionID(_ sessionID: UUID?) {
        visibleSessionID = sessionID
        if let sessionID { acknowledgeSession(sessionID) }
    }

    func acknowledgeSession(_ sessionID: UUID) {
        unseenStateBySessionID = RemoteSessionUnseenProjection.acknowledging(
            sessionID: sessionID,
            in: unseenStateBySessionID
        )
    }

    var workspaces: [RemoteWorkspaceSummary] {
        snapshot?.workspaces ?? []
    }

    var attentionItems: [RemoteAttentionItem] {
        snapshot?.attentionItems ?? []
    }

    var workflowCatalog: [RemoteWorkflowDescriptor] {
        snapshot?.workflowCatalog ?? []
    }

    var agentCatalog: [RemoteAgentDescriptor] {
        snapshot?.agentCatalog ?? []
    }

    var canControlChat: Bool {
        connectionState == .connected && snapshot?.authorization.allows(.control) == true
    }

    var canSendAttachments: Bool {
        agentCatalogMetadata?.supportsAttachments == true && canControlChat
    }

    var agentCatalogMetadata: RemoteCatalogMetadata? {
        snapshot?.agentCatalogMetadata
    }

    func beginPairing() {
        guard pairingRecord == nil, !pairingStorageUnavailable else { return }
        unpairWork?.cancel()
        unpairWork = nil
        unpairWorkID = nil
        clearTransientError()
        showingPairing = true
        connectionState = .discovering
    }

    func handleQRCode(_ value: String) {
        guard pairingRecord == nil, !pairingStorageUnavailable else { return }
        var stage = RemotePairingTelemetry.Stage.decodeQR
        do {
            let advertisement = try RemotePairingDecoder.decode(value)
            stage = .localIdentity
            let identity = try irohIdentityStore.loadOrCreate()
            let endpointID = try RemoteIrohGatewayTransport.endpointID(for: identity.secret)
            stage = .saveAttempt
            try savePairing(.preparing(.init(id: UUID(), advertisement: advertisement, localEndpointID: endpointID)))
            showingPairing = false
            clearTransientError()
            retryConnection()
        } catch {
            RemotePairingTelemetry.failure(error, stage: stage)
            scannerGeneration &+= 1
            presentError(error.localizedDescription)
        }
    }

    func cancelPairing() {
        showingPairing = false
        if pairingRecord == nil { connectionState = .unpaired }
    }

    func cancelPendingPairing() {
        guard canCancelPendingPairing else { return }
        stopConnection()
        clearLocalPairing(message: "Generate a new pairing code on your Mac, then scan it here.")
    }

    func resetPendingConfirmation() {
        guard canResetPendingConfirmation else { return }
        stopConnection()
        clearLocalPairing(message: "Check the phone in Mac Settings. Cancel a pending attempt or unpair this phone there, then generate a new code.")
    }

    func resetPairingStorage() {
        guard pairingStorageUnavailable else { return }
        stopConnection()
        clearLocalPairing(message: "Check the phone in Mac Settings. Unpair it there if it still appears, then generate a new code.")
    }

    func retryConnection() {
        guard unpairWorkID == nil else { return }
        automaticRecoveryPaused = false
        if pairingStorageUnavailable {
            restorePairing()
            return
        }
        guard connectionState != .connected else { return }
        guard networkAvailable else {
            connectionIssue = "Network unavailable. Retrying when the phone is back online."
            return
        }
        startConnectionRecovery()
    }

    func setSceneActive(_ active: Bool) {
        guard isSceneActive != active else { return }
        isSceneActive = active
        if active {
            startConnectionRecovery()
        } else {
            stopConnection()
        }
    }

    func disconnect() {
        automaticRecoveryPaused = true
        stopConnection()
        if isPaired { connectionIssue = "Disconnected. Tap Reconnect when you’re ready." }
    }

    private func stopConnection() {
        // The cancelled supervisor owns the slot until its in-flight transport has unwound.
        connectionTask?.cancel()
        isRecovering = false
        pairingProgress = nil
        cancelAllTranscriptTasks()
        endConnectionCycle()
        if pairingRecord != nil { connectionState = isPaired ? .disconnected : .discovering }
    }

    @discardableResult
    func startRun(
        in workspaceID: String,
        message: String,
        workflowID: String? = nil,
        agentID: String? = nil,
        modelID: String? = nil,
        reasoningEffort: String? = nil,
        interviewFirst: Bool = false,
        attachments: [RemoteDraftAttachment] = []
    ) -> UUID {
        let request = RemoteCommandRequest(
            operation: .startRun,
            workspaceID: workspaceID,
            message: message,
            agentID: agentID?.isEmpty == true ? nil : agentID,
            modelID: modelID?.isEmpty == true ? nil : modelID,
            reasoningEffort: reasoningEffort?.isEmpty == true ? nil : reasoningEffort,
            workflowID: workflowID?.isEmpty == true ? nil : workflowID,
            interviewFirst: interviewFirst ? true : nil,
            attachmentIDs: attachments.isEmpty ? nil : attachments.map(\.id)
        )
        return sendCommand(request, attachments: attachments)
    }

    @discardableResult
    func configureTool(
        workspaceID: String,
        sessionID: UUID? = nil,
        settingID: String,
        enabled: Bool,
        expectedRevision: Int
    ) -> UUID {
        sendCommand(RemoteCommandRequest(
            operation: .configureTools,
            workspaceID: workspaceID,
            sessionID: sessionID,
            toolMutation: RemoteToolMutation(
                settingID: settingID,
                enabled: enabled,
                expectedRevision: expectedRevision
            )
        ))
    }

    @discardableResult
    func configureSession(
        sessionID: UUID,
        workspaceID: String,
        agentID: String? = nil,
        modelID: String? = nil,
        reasoningEffort: String? = nil
    ) -> UUID {
        sendCommand(RemoteCommandRequest(
            operation: .configureSession,
            workspaceID: workspaceID,
            sessionID: sessionID,
            agentID: agentID,
            modelID: modelID,
            reasoningEffort: reasoningEffort
        ))
    }

    @discardableResult
    func continueChat(
        sessionID: UUID,
        workspaceID: String,
        message: String,
        runState: RemoteRunState? = nil,
        attachments: [RemoteDraftAttachment] = []
    ) -> UUID {
        let authoritativeSession = snapshot?.sessions.first { $0.sessionID == sessionID }
        let state = authoritativeSession?.runState
            ?? runState
            ?? provisionalSessionRoutes[sessionID]?.runState
            ?? .idle
        let policy = RemoteComposerPolicy.resolve(
            runState: state,
            pendingInteraction: authoritativeSession?.pendingInteraction
        )
        guard let operation = policy.primaryOperation, attachments.isEmpty || policy.canAttach else {
            let commandID = UUID()
            recordCommandCompletion(.init(commandID: commandID, operation: .followUp, outcome: .rejected))
            presentError(attachments.isEmpty
                ? "Respond to the pending interaction before sending another message."
                : "Wait for the current run to finish before sending attachments.")
            return commandID
        }
        return sendCommand(RemoteCommandRequest(
            operation: operation,
            workspaceID: workspaceID,
            sessionID: sessionID,
            message: message,
            attachmentIDs: attachments.isEmpty ? nil : attachments.map(\.id)
        ), attachments: attachments)
    }

    func followUp(sessionID: UUID, workspaceID: String, message: String) {
        sendCommand(
            RemoteCommandRequest(
                operation: .followUp,
                workspaceID: workspaceID,
                sessionID: sessionID,
                message: message
            )
        )
    }

    func resume(sessionID: UUID, workspaceID: String, message: String) {
        sendCommand(
            RemoteCommandRequest(
                operation: .resume,
                workspaceID: workspaceID,
                sessionID: sessionID,
                message: message
            )
        )
    }

    func runContextBuilder(
        in workspaceID: String,
        instructions: String,
        responseType: String
    ) {
        sendCommand(
            RemoteCommandRequest(
                operation: .contextBuilder,
                workspaceID: workspaceID,
                message: instructions,
                contextBuilderResponseType: responseType == "clarify" ? nil : responseType
            )
        )
    }

    func enableNotifications() {
        notificationStatus = "Requesting permission…"
        Task { [weak self] in
            let granted = await RemoteNotificationDelegate.requestAuthorizationAndRegister()
            guard let self else { return }
            if !granted {
                notificationStatus = "Notification permission is unavailable."
            } else if pendingNotificationDeviceToken == nil {
                notificationStatus = "Waiting for Apple notification registration…"
            }
        }
    }

    func refreshDiagnostics() {
        Task { [weak self] in
            guard let self else { return }
            do {
                guard let gateway else { return }
                let result = try await gateway.diagnostics()
                guard !Task.isCancelled, self.gateway === gateway else { return }
                diagnostics = result
                if let diagnostics {
                    notificationStatus = diagnostics.notificationRegistration
                        ? (diagnostics.notificationRelayConfigured ? "Configured" : "Registered; relay URL missing")
                        : "Not configured"
                }
            } catch {
                guard !isExpectedCancellation(error) else { return }
                presentError("Diagnostics unavailable: \(error.localizedDescription)")
            }
        }
    }

    func consumePendingSessionID() -> UUID? {
        defer { pendingSessionID = nil }
        return pendingSessionID
    }

    func steer(sessionID: UUID, workspaceID: String, message: String) {
        sendCommand(
            RemoteCommandRequest(
                operation: .steer,
                workspaceID: workspaceID,
                sessionID: sessionID,
                message: message
            )
        )
    }

    @discardableResult
    func cancel(sessionID: UUID, workspaceID: String) -> UUID {
        sendCommand(
            RemoteCommandRequest(
                operation: .cancel,
                workspaceID: workspaceID,
                sessionID: sessionID
            )
        )
    }

    @discardableResult
    func respond(
        sessionID: UUID,
        workspaceID: String,
        interactionID: UUID,
        decision: String? = nil,
        message: String? = nil,
        answers: [String: [String]] = [:],
        secret: String? = nil,
        questionAnswers: [String: RemoteQuestionAnswer]? = nil
    ) -> UUID {
        sendCommand(
            RemoteCommandRequest(
                operation: .respond,
                workspaceID: workspaceID,
                sessionID: sessionID,
                interactionID: interactionID,
                message: message,
                decision: decision,
                answers: answers,
                secret: secret,
                questionAnswers: questionAnswers
            )
        )
    }

    func refreshRemoteState() {
        clearTransientError()
        guard gateway != nil else { retryConnection(); return }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await refreshSnapshot()
                refreshChatList()
            } catch {
                guard !isExpectedCancellation(error) else { return }
                presentError(error.localizedDescription)
            }
        }
    }

    func selectHistoryWorkspace(_ workspaceID: String?) {
        guard selectedHistoryWorkspaceID != workspaceID else { return }
        chatListTask?.cancel()
        chatListTask = nil
        selectedHistoryWorkspaceID = workspaceID
        refreshChatList()
    }

    func retryChatList() {
        guard gateway != nil else { retryConnection(); return }
        refreshChatList()
    }

    func refreshChatList() {
        guard let gateway else { startConnectionRecovery(); return }
        guard let selection = selectedHistoryWorkspaceID,
              let workspaceID = UUID(uuidString: selection)
        else { return }
        chatListTask?.cancel()
        var history = workspaceHistory[selection] ?? RemoteWorkspaceHistory()
        history.phase = .loading
        workspaceHistory[selection] = history
        chatListTask = Task { [weak self, weak gateway] in
            guard let self, let gateway else { return }
            do {
                let result = try await RemoteWorkspaceHistory.load(workspaceID: workspaceID, fetch: gateway.history)
                guard !Task.isCancelled, self.gateway === gateway, selection == selectedHistoryWorkspaceID else { return }
                workspaceHistory[selection] = result
            } catch {
                guard !Task.isCancelled, self.gateway === gateway, selection == selectedHistoryWorkspaceID else { return }
                history.phase = .failed
                workspaceHistory[selection] = history
            }
        }
    }

    func retryTranscript(for sessionID: UUID) {
        guard gateway != nil else { retryConnection(); return }
        loadTranscript(for: sessionID)
    }

    func loadTranscript(for sessionID: UUID) {
        guard let gateway else { startConnectionRecovery(); return }
        acknowledgeSession(sessionID)
        cancelTranscriptMutationTasks(for: sessionID)
        let generation = beginTranscriptLoad(.initial, for: sessionID)
        transcriptInitialTasks[sessionID] = Task { [weak self] in
            guard let self else { return }
            do {
                let page = try await gateway.recentTranscript(sessionID: sessionID)
                guard !Task.isCancelled, self.gateway === gateway else { return }
                applyTranscriptPage(page, kind: .initial, generation: generation, for: sessionID)
            } catch {
                guard !isExpectedCancellation(error) else { return }
                failTranscriptLoad(error, kind: .initial, generation: generation, for: sessionID)
            }
        }
    }

    func loadMoreTranscript(for sessionID: UUID) {
        guard let timeline = transcriptTimelinesBySessionID[sessionID], timeline.hasOlder else { return }
        cancelTranscriptMutationTasks(for: sessionID)
        let generation = beginTranscriptLoad(.older, for: sessionID)
        let legacyAfter = timeline.legacyNextSequenceIndex
        let recentCursor = timeline.olderCursor
        let usesLegacyPaging = timeline.isLegacyPaging
        transcriptOlderTasks[sessionID] = Task { [weak self] in
            guard let self else { return }
            do {
                guard let gateway else { throw RemotePairingError.unavailableDesktop }
                let page: RemoteTranscriptPage
                if usesLegacyPaging {
                    guard let legacyAfter else { return }
                    page = try await gateway.transcript(
                        sessionID: sessionID,
                        afterSequenceIndex: legacyAfter
                    )
                } else {
                    guard let recentCursor else { return }
                    page = try await gateway.recentTranscript(
                        sessionID: sessionID,
                        before: recentCursor
                    )
                }
                guard !Task.isCancelled else { return }
                applyTranscriptPage(page, kind: .older, generation: generation, for: sessionID)
            } catch {
                guard !isExpectedCancellation(error) else { return }
                failTranscriptLoad(error, kind: .older, generation: generation, for: sessionID)
            }
        }
    }

    func loadTranscriptDetails(for sessionID: UUID, itemID: UUID) {
        clearTransientError()
        transcriptDetailTasks[itemID]?.cancel()
        transcriptDetailStates[itemID] = .loading
        transcriptDetailTasks[itemID] = Task { [weak self] in
            guard let self else { return }
            do {
                guard let gateway else { throw RemotePairingError.unavailableDesktop }
                let item = transcriptTimelinesBySessionID[sessionID]?.itemsByID[itemID]
                var page = try await gateway.transcript(
                    sessionID: sessionID,
                    itemID: itemID,
                    limit: 1,
                    includeDetails: true
                )
                if !page.items.contains(where: { $0.id == itemID }), let item {
                    // Older CE builds ignore `item_id`; use the actual legacy
                    // `> after` contract and fetch enough tied rows to match.
                    page = try await gateway.transcript(
                        sessionID: sessionID,
                        afterSequenceIndex: item.sequenceIndex - 1,
                        limit: 200,
                        includeDetails: true
                    )
                }
                guard let detailedItem = page.items.first(where: { $0.id == itemID }) else {
                    throw RemoteGatewayError.requestRejected(
                        RemoteErrorResponse(
                            code: "transcript_item_not_found",
                            message: "That transcript detail is no longer available. Try refreshing and retrying.",
                            retryable: true
                        )
                    )
                }
                try Task.checkCancellation()
                var timeline = transcriptTimelinesBySessionID[sessionID] ?? RemoteTranscriptTimelineState()
                timeline.mergeDetails(from: detailedItem)
                transcriptTimelinesBySessionID[sessionID] = timeline
                transcriptDetailTasks[itemID] = nil
                transcriptDetailStates[itemID] = .loaded
            } catch {
                guard !isExpectedCancellation(error), !Task.isCancelled else { return }
                transcriptDetailTasks[itemID] = nil
                transcriptDetailStates[itemID] = .failed
            }
        }
    }

    func imageThumbnail(sessionID: UUID, itemID: UUID, attachmentID: UUID) async throws -> Data {
        let desktop = snapshot?.desktop.instanceID
        let key = "\(desktop ?? ""):\(sessionID):\(itemID):\(attachmentID)" as NSString
        if let cached = imageThumbnails.object(forKey: key) { return cached as Data }

        let chunk = try await fetchImageChunk(
            RemoteImageAttachmentRequest(sessionID: sessionID, itemID: itemID, attachmentID: attachmentID, variant: .thumbnail)
        )
        guard chunk.offset == 0, chunk.revision == nil,
              chunk.totalBytes == chunk.bytes.count,
              (1 ... RemoteImageAttachmentRequest.maxThumbnailBytes).contains(chunk.bytes.count)
        else { throw RemoteGatewayError.invalidResponse }
        try Task.checkCancellation()
        guard snapshot?.desktop.instanceID == desktop else { throw CancellationError() }
        imageThumbnails.setObject(chunk.bytes as NSData, forKey: key, cost: chunk.bytes.count)
        return chunk.bytes
    }

    func originalImage(sessionID: UUID, itemID: UUID, attachmentID: UUID) async throws -> Data {
        let desktop = snapshot?.desktop.instanceID
        var download = RemoteImageDownload()
        while !download.isComplete {
            try Task.checkCancellation()
            guard snapshot?.desktop.instanceID == desktop else { throw CancellationError() }
            let chunk = try await fetchImageChunk(RemoteImageAttachmentRequest(
                sessionID: sessionID, itemID: itemID, attachmentID: attachmentID, variant: .original,
                offset: download.bytes.count, revision: download.revision
            ))
            try download.append(chunk)
        }
        try Task.checkCancellation()
        guard snapshot?.desktop.instanceID == desktop else { throw CancellationError() }
        return download.bytes
    }

    private func fetchImageChunk(_ request: RemoteImageAttachmentRequest) async throws -> RemoteImageAttachmentChunk {
        let desktop = snapshot?.desktop.instanceID
        for delay in [Duration.zero, .milliseconds(250), .milliseconds(750)] {
            try await Task.sleep(for: delay)
            guard snapshot?.desktop.instanceID == desktop else { throw CancellationError() }
            do {
                guard let gateway else { throw RemotePairingError.unavailableDesktop }
                return try await withImageReadSlot { try await gateway.imageAttachment(request) }
            } catch {
                if delay == .milliseconds(750) || isExpectedCancellation(error) { throw error }
                if case let RemoteGatewayError.requestRejected(response) = error, response.retryable != true { throw error }
            }
        }
        throw RemoteGatewayError.imageUnavailable
    }

    /// Leave room on the shared Iroh connection for transcript and control RPCs when many photos appear together.
    private func withImageReadSlot<Result>(_ read: () async throws -> Result) async throws -> Result {
        if activeImageReads < 3 {
            activeImageReads += 1
        } else {
            let id = UUID()
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    if Task.isCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        waitingImageReads.append((id, continuation))
                    }
                }
            } onCancel: {
                Task { @MainActor in
                    guard let index = self.waitingImageReads.firstIndex(where: { $0.0 == id }) else { return }
                    self.waitingImageReads.remove(at: index).1.resume(throwing: CancellationError())
                }
            }
        }
        defer {
            if waitingImageReads.isEmpty {
                activeImageReads -= 1
            } else {
                waitingImageReads.removeFirst().1.resume()
            }
        }
        try Task.checkCancellation()
        return try await read()
    }

    func transcriptHasMore(for sessionID: UUID) -> Bool {
        transcriptTimelinesBySessionID[sessionID]?.hasOlder == true
    }

    private func refreshLatestTranscript(for sessionID: UUID, revision: UInt64?) {
        if let revision,
           let loaded = transcriptTimelinesBySessionID[sessionID]?.loadedRevision,
           revision <= loaded
        {
            return
        }
        cancelTranscriptMutationTasks(for: sessionID)
        let existingTimeline = transcriptTimelinesBySessionID[sessionID]
        let startsInLegacyMode = existingTimeline?.isLegacyPaging == true
        let legacyStart = existingTimeline?.legacyRefreshSequenceIndex
        let generation = beginTranscriptLoad(.latest, for: sessionID)
        transcriptLatestTasks[sessionID] = Task { [weak self] in
            guard let self else { return }
            do {
                guard let gateway else { throw RemotePairingError.unavailableDesktop }
                if startsInLegacyMode {
                    guard let legacyStart else { throw RemoteGatewayError.invalidResponse }
                    try await refreshLegacyTranscript(
                        gateway: gateway,
                        sessionID: sessionID,
                        startingAfter: legacyStart,
                        initialPage: nil,
                        generation: generation,
                        requestedRevision: revision
                    )
                    return
                }

                var page = try await gateway.recentTranscript(sessionID: sessionID)
                try Task.checkCancellation()
                guard page.pagingMode == .recentBackward else {
                    try await refreshLegacyTranscript(
                        gateway: gateway,
                        sessionID: sessionID,
                        startingAfter: page.nextSequenceIndex,
                        initialPage: page,
                        generation: generation,
                        requestedRevision: revision
                    )
                    return
                }

                var batch = RemoteTranscriptRecentRefreshBatch(
                    existingItems: existingTimeline?.orderedItems ?? []
                )
                var visitedCursors: Set<RemoteTranscriptCursor> = []
                while true {
                    try Task.checkCancellation()
                    if batch.append(page) {
                        let completePage = try batch.combinedPage(requestedRevision: revision)
                        applyTranscriptPage(
                            completePage,
                            kind: .latest,
                            generation: generation,
                            requestedRevision: revision,
                            for: sessionID
                        )
                        return
                    }
                    guard let before = batch.nextOlderCursor,
                          visitedCursors.insert(before).inserted
                    else { throw RemoteGatewayError.invalidResponse }
                    page = try await gateway.recentTranscript(
                        sessionID: sessionID,
                        before: before
                    )
                    guard page.pagingMode == .recentBackward else {
                        throw RemoteGatewayError.invalidResponse
                    }
                }
            } catch {
                guard !isExpectedCancellation(error) else { return }
                failTranscriptLoad(error, kind: .latest, generation: generation, for: sessionID)
            }
        }
    }

    private func refreshLegacyTranscript(
        gateway: any RemoteGatewayTransport,
        sessionID: UUID,
        startingAfter: Int?,
        initialPage: RemoteTranscriptPage?,
        generation: UInt64,
        requestedRevision: UInt64?
    ) async throws {
        var fetchedByID: [UUID: RemoteTranscriptItem] = [:]
        var lastPage = initialPage
        initialPage?.items.forEach { fetchedByID[$0.id] = $0 }
        var after: Int? = if let initialPage {
            initialPage.hasMore ? initialPage.nextSequenceIndex : nil
        } else {
            startingAfter
        }
        var visitedCursors: Set<Int> = []
        if initialPage?.hasMore == true, after == nil {
            throw RemoteGatewayError.invalidResponse
        }

        while let cursor = after {
            guard visitedCursors.insert(cursor).inserted else {
                throw RemoteGatewayError.invalidResponse
            }
            try Task.checkCancellation()
            let page = try await gateway.transcript(
                sessionID: sessionID,
                afterSequenceIndex: cursor
            )
            try Task.checkCancellation()
            page.items.forEach { fetchedByID[$0.id] = $0 }
            lastPage = page
            if page.hasMore {
                guard let next = page.nextSequenceIndex, next != cursor else {
                    throw RemoteGatewayError.invalidResponse
                }
                after = next
            } else {
                after = nil
            }
        }

        guard let lastPage else { throw RemoteGatewayError.invalidResponse }
        let completePage = RemoteTranscriptPage(
            sessionID: sessionID,
            items: Array(fetchedByID.values),
            hasMore: false,
            eventCursor: lastPage.eventCursor,
            transcriptRevision: lastPage.transcriptRevision ?? requestedRevision,
            transcriptRevisionEpoch: lastPage.transcriptRevisionEpoch
        )
        applyTranscriptPage(
            completePage,
            kind: .latest,
            generation: generation,
            requestedRevision: requestedRevision,
            for: sessionID
        )
    }

    private func beginTranscriptLoad(
        _ kind: RemoteTranscriptLoadKind,
        for sessionID: UUID
    ) -> UInt64 {
        var timeline = transcriptTimelinesBySessionID[sessionID] ?? RemoteTranscriptTimelineState()
        let generation = timeline.begin(kind)
        transcriptTimelinesBySessionID[sessionID] = timeline
        return generation
    }

    private func applyTranscriptPage(
        _ page: RemoteTranscriptPage,
        kind: RemoteTranscriptLoadKind,
        generation: UInt64,
        requestedRevision: UInt64? = nil,
        for sessionID: UUID
    ) {
        var timeline = transcriptTimelinesBySessionID[sessionID] ?? RemoteTranscriptTimelineState()
        guard timeline.apply(
            page,
            kind: kind,
            generation: generation,
            requestedRevision: requestedRevision
        ) else { return }
        transcriptTimelinesBySessionID[sessionID] = timeline
    }

    private func failTranscriptLoad(
        _ error: Error,
        kind: RemoteTranscriptLoadKind,
        generation: UInt64,
        for sessionID: UUID
    ) {
        var timeline = transcriptTimelinesBySessionID[sessionID] ?? RemoteTranscriptTimelineState()
        guard timeline.fail(error.localizedDescription, kind: kind, generation: generation) else { return }
        transcriptTimelinesBySessionID[sessionID] = timeline
        presentError("Transcript unavailable: \(error.localizedDescription)")
    }

    private func endConnectionCycle() {
        chatListTask?.cancel()
        chatListTask = nil
        gateway?.close()
        gateway = nil
        transportStatus = "None"
        irohPathStatus = "Unknown"
        let provisionalIDs = Set(provisionalSessionRoutes.keys)
        if let pendingSessionID, provisionalIDs.contains(pendingSessionID) {
            self.pendingSessionID = nil
        }
        provisionalSessionRoutes = [:]
    }

    private func cancelTranscriptMutationTasks(for sessionID: UUID) {
        transcriptInitialTasks[sessionID]?.cancel()
        transcriptLatestTasks[sessionID]?.cancel()
        transcriptOlderTasks[sessionID]?.cancel()
        transcriptInitialTasks[sessionID] = nil
        transcriptLatestTasks[sessionID] = nil
        transcriptOlderTasks[sessionID] = nil
    }

    private func cancelAllTranscriptTasks() {
        transcriptInitialTasks.values.forEach { $0.cancel() }
        transcriptLatestTasks.values.forEach { $0.cancel() }
        transcriptOlderTasks.values.forEach { $0.cancel() }
        transcriptDetailTasks.values.forEach { $0.cancel() }
        transcriptInitialTasks = [:]
        transcriptLatestTasks = [:]
        transcriptOlderTasks = [:]
        transcriptDetailTasks = [:]
        transcriptDetailStates = [:]
    }

    func unpair() {
        guard let storedCredential else { return }

        unpairWork?.cancel()
        let preferredGateway = gateway
        gateway = nil
        automaticRecoveryPaused = true
        stopConnection()
        let attempts = makeUnpairAttempts(
            stored: storedCredential,
            preferredGateway: preferredGateway
        )
        let workID = UUID()
        unpairWorkID = workID
        Self.unpairLogger.info("One-tap Unpair started with \(attempts.count, privacy: .public) short best-effort remote attempt(s)")

        unpairWork = RemoteUnpairCoordinator.startBestEffort(
            attempts: attempts,
            timeout: Self.unpairDeadline,
            localCleanup: { [weak self] in
                self?.clearLocalPairing()
            },
            onAttempt: { description in
                Self.unpairLogger.info("Attempting best-effort remote revocation over \(description, privacy: .public)")
            },
            onAttemptFailure: { description, _ in
                Self.unpairLogger.error("Best-effort Unpair attempt \(description, privacy: .public) failed")
            },
            onCompletion: { [weak self] outcome in
                Self.unpairLogger.info("Best-effort remote revocation finished: \(String(describing: outcome), privacy: .public)")
                guard self?.unpairWorkID == workID else { return }
                self?.unpairWorkID = nil
                self?.unpairWork = nil
                guard self?.pairingRecord == nil else { return }
                switch outcome {
                case .revoked, .alreadyRevoked:
                    self?.connectionIssue = nil
                case .cancelled:
                    break
                case .noTransport, .failed, .timedOut:
                    self?.connectionIssue = "Pairing was removed from this phone. If the Mac still lists it, choose Unpair phone in Mac Settings before pairing again."
                }
            }
        )
    }

    private func makeUnpairAttempts(
        stored: StoredRemoteCredential,
        preferredGateway: (any RemoteGatewayTransport)?
    ) -> [RemoteUnpairAttempt] {
        if let preferredGateway {
            return [RemoteUnpairAttempt(
                transportDescription: "Iroh",
                run: { try await preferredGateway.unpair() },
                cancel: { preferredGateway.close() }
            )]
        }

        // Capture the existing identity before the coordinator clears the local pairing.
        guard let identity = try? irohIdentityStore.loadOrCreate() else { return [] }
        irohGeneration &+= 1
        let generation = irohGeneration
        var transport: RemoteIrohGatewayTransport?
        var cancelled = false
        return [RemoteUnpairAttempt(
            transportDescription: "Iroh reconnect",
            run: {
                let connected = try await RemoteIrohGatewayTransport.connect(
                    stored: stored,
                    identitySecret: identity.secret,
                    generation: generation
                )
                guard !cancelled else {
                    connected.close()
                    throw CancellationError()
                }
                transport = connected
                try await connected.unpair()
            },
            cancel: {
                cancelled = true
                transport?.close()
            }
        )]
    }

    private func clearLocalPairing(message: String = "Removing pairing from the Mac…") {
        recoveryStartedAt = nil
        reconnectAttempt = 0
        reconnectBackoff = .init()
        do {
            try credentialStore.delete()
        } catch {
            automaticRecoveryPaused = true
            connectionIssue = "The phone could not remove pairing from Keychain. Unlock the phone and try again."
            return
        }
        do {
            try irohIdentityStore.delete()
        } catch {
            Self.unpairLogger.error("Phone Iroh identity cleanup failed")
        }

        pairingRecord = nil
        pairingStorageUnavailable = false
        automaticRecoveryPaused = false
        authority = .observe
        reducer = RemoteSnapshotReducer()
        snapshot = nil
        chatListTask?.cancel()
        chatListTask = nil
        selectedHistoryWorkspaceID = nil
        workspaceHistory = [:]
        cancelAllTranscriptTasks()
        transcriptTimelinesBySessionID = [:]
        imageThumbnails.removeAllObjects()
        knownTranscriptRevisions = [:]
        unseenStateBySessionID = [:]
        provisionalSessionRoutes = [:]
        selectionOverridesBySessionID = [:]
        visibleSessionID = nil
        hasEstablishedSnapshot = false
        commandActivity = RemoteCommandActivityState()
        lastCommandCompletion = nil
        lastAcceptedCommand = nil
        lastAcceptedCommandID = nil
        contextBuilderResult = nil
        diagnostics = nil
        pendingSessionID = nil
        pendingNotificationDeviceToken = nil
        notificationStatus = "Not configured"
        transportStatus = "None"
        irohPathStatus = "Unknown"
        lastConnectionEvent = "Unpaired"
        connectionIssue = message
        showingPairing = false
        connectionState = .unpaired
        clearTransientError()
    }

    private func restorePairing() {
        do {
            pairingRecord = try credentialStore.load()
            pairingStorageUnavailable = false
            connectionIssue = nil
            connectionState = isPaired ? .disconnected : (hasPendingPairing ? .discovering : .unpaired)
            startConnectionRecovery()
        } catch {
            pairingStorageUnavailable = true
            connectionIssue = error.localizedDescription
        }
    }

    private func savePairing(_ record: StoredRemotePairing) throws {
        try credentialStore.save(record)
        pairingRecord = record
    }

    private func startConnectionRecovery() {
        guard connectionTask == nil, isSceneActive, networkAvailable,
              pairingRecord != nil, unpairWorkID == nil, !automaticRecoveryPaused, !pairingStorageUnavailable
        else { return }
        let generation = UUID()
        activeConnectionAttemptID = generation
        isRecovering = true
        connectionTask = Task { [weak self] in
            await self?.superviseConnection(generation: generation)
        }
    }

    private func checkConnectionGeneration(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard activeConnectionAttemptID == generation, isSceneActive, networkAvailable else {
            throw CancellationError()
        }
    }

    private func superviseConnection(generation: UUID) async {
        defer {
            if activeConnectionAttemptID == generation {
                activeConnectionAttemptID = nil
                authenticatedConnectionAttemptID = nil
                connectionTask = nil
                isRecovering = false
                pairingProgress = nil
                if Task.isCancelled { startConnectionRecovery() }
            }
        }

        while !Task.isCancelled {
            var attemptStarted = false
            do {
                if let deadline = reconnectBackoff.nextAttempt, deadline > .now {
                    try await ContinuousClock().sleep(until: deadline)
                }
                try checkConnectionGeneration(generation)
                guard let pairingRecord else { return }
                reconnectBackoff.started(at: .now)
                attemptStarted = true
                let (transport, firstSnapshot) = try await establishConnection(pairingRecord, generation: generation)
                attemptStarted = false
                guard (try? checkConnectionGeneration(generation)) != nil else {
                    transport.close()
                    return
                }
                gateway = transport
                applySnapshot(firstSnapshot)
                reconnectBackoff.connected()
                isRecovering = false
                pairingProgress = nil
                connectionIssue = nil
                connectionState = .connected
                transportStatus = "Iroh"
                irohPathStatus = transport.irohPath?.rawValue ?? "unknown"
                lastConnectionEvent = "Connected to Mac with Iroh"
                clearTransientError()
                refreshChatList()
                if let visibleSessionID { loadTranscript(for: visibleSessionID) }
                refreshDiagnostics()
                registerPendingNotificationIfPossible()
                try await consumeEvents(using: transport, generation: generation)
            } catch {
                guard (try? checkConnectionGeneration(generation)) != nil else {
                    if attemptStarted, pairingRecord != nil, !automaticRecoveryPaused {
                        reconnectBackoff.failed(at: .now)
                    }
                    return
                }
                authenticatedConnectionAttemptID = nil
                cancelAllTranscriptTasks()
                endConnectionCycle()
                pairingProgress = nil
                connectionState = isPaired ? .disconnected : .discovering

                let pairingError = if case let .preparing(attempt) = pairingRecord,
                                      attempt.legacyHelloMayHaveBeenSent == true,
                                      !(error is RemoteCredentialStoreError)
                {
                    RemoteIrohTransportError.legacyPairingOutcomeUnknown as Error
                } else {
                    error
                }
                if requiresNewPairing(pairingError, duringPairing: hasPendingPairing) {
                    let recovery = isPaired
                        ? "If this phone still appears in Remote settings on your Mac, unpair it there before scanning a new code."
                        : "Check Remote settings on your Mac for a pending or paired phone before generating a new code."
                    clearLocalPairing(message: "\(pairingError.localizedDescription) \(recovery)")
                    lastConnectionEvent = "Pairing needs attention"
                    return
                }
                connectionIssue = connectionMessage(for: error)
                lastConnectionEvent = connectionIssue ?? "Connection interrupted"
                if error is RemoteCredentialStoreError || isIncompatibleConnection(error) {
                    automaticRecoveryPaused = true
                    return
                }
                isRecovering = true
                reconnectBackoff.failed(at: .now)
            }
        }
    }

    private func recordReconnect(_ entry: RemoteReconnectDiagnostics.Entry) {
        reconnectHistory = RemoteReconnectDiagnostics.append(entry, to: reconnectHistory)
        if let data = try? JSONEncoder().encode(reconnectHistory) {
            reconnectHistoryDefaults?.set(data, forKey: RemoteReconnectDiagnostics.historyKey)
        }
        if entry.outcome == .connected {
            recoveryStartedAt = nil
            reconnectAttempt = 0
        }
        guard entry.outcome != .cancelled else { return }
        let now = ContinuousClock.now
        if let last = reconnectLogSentAt[entry.outcome], last.duration(to: now) < .seconds(60) { return }
        reconnectLogSentAt[entry.outcome] = now
        RemotePairingTelemetry.logReconnect(entry)
    }

    private func establishConnection(
        _ record: StoredRemotePairing,
        generation: UUID
    ) async throws -> (any RemoteConnectionCandidate, RemoteSnapshot) {
        var candidate: (any RemoteConnectionCandidate)?
        let attemptID: UUID? = switch record {
        case let .preparing(attempt): attempt.id
        case let .confirming(_, id): id
        case .paired: nil
        }
        let start = ContinuousClock.now
        var reconnect = RemoteReconnectDiagnostics.Attempt()
        let networkAtStart = reconnectNetwork
        let networkRevisionAtStart = reconnectNetworkRevision
        let recoveryStart = recoveryStartedAt ?? reconnect.start
        let attemptNumber = reconnectAttempt + 1
        if attemptID == nil {
            recoveryStartedAt = recoveryStart
            reconnectAttempt = attemptNumber
        }
        var stage = RemotePairingTelemetry.Stage.localIdentity
        let trace = attemptID.map { RemotePairingTelemetry.begin(attemptID: $0) }
        var traceStatus = RemotePairingTelemetry.TraceStatus.cancelled
        defer { trace?.finish(status: traceStatus) }
        do {
            let identity = try irohIdentityStore.loadOrCreate()
            irohGeneration &+= 1
            let transport: any RemoteConnectionCandidate
            let stored: StoredRemoteCredential
            switch record {
            case let .preparing(attempt):
                guard attempt.legacyHelloMayHaveBeenSent != true else {
                    throw RemoteIrohTransportError.legacyPairingOutcomeUnknown
                }
                let requiresConfirmation = attempt.advertisement.requiresPairingConfirmation == true
                // A Mac with confirmation can retain an already accepted attempt after the QR expires.
                let recoveryWindow = requiresConfirmation ? RemoteWireProtocol.pairingAttemptLifetime : 0
                guard Date() < attempt.advertisement.expiresAt.addingTimeInterval(recoveryWindow) else {
                    throw RemotePairingError.expiredQRCode
                }
                pairingProgress = "Contacting your Mac…"
                stage = .preparePairing
                let prepared = try await connectionFactory.prepare(
                    attempt, identity.secret, irohGeneration, UIDevice.current.name, {
                        try self.checkConnectionGeneration(generation)
                        var dispatched = attempt
                        dispatched.legacyHelloMayHaveBeenSent = true
                        try self.savePairing(.preparing(dispatched))
                    }
                )
                stored = prepared.0
                transport = prepared.1
                candidate = transport
                stage = .saveCredential
                pairingProgress = "Saving pairing…"
                if requiresConfirmation {
                    try checkConnectionGeneration(generation)
                    try savePairing(.confirming(stored, attemptID: attempt.id))
                } else {
                    // Preserve a verified receipt even if the network changed, unless the user reset this attempt.
                    guard case let .preparing(currentAttempt) = pairingRecord,
                          currentAttempt.id == attempt.id,
                          currentAttempt.legacyHelloMayHaveBeenSent == true
                    else { throw CancellationError() }
                    try savePairing(.paired(stored))
                }
            case let .confirming(credential, _), let .paired(credential):
                stored = credential
                pairingProgress = hasPendingPairing ? "Contacting your Mac…" : nil
                stage = .dial
                transport = try await connectionFactory.open(credential, identity.secret, irohGeneration, &reconnect)
                candidate = transport
            }
            try checkConnectionGeneration(generation)
            if case let .confirming(_, confirmationID) = pairingRecord {
                stage = .confirmPairing
                pairingProgress = "Confirming pairing with your Mac…"
                try await transport.confirmPairing(attemptID: confirmationID)
                try checkConnectionGeneration(generation)
                stage = .saveConfirmation
                try savePairing(.paired(stored))
                connectionState = .disconnected
                showingPairing = false
            }

            stage = .authenticate
            reconnect.enter(.authenticate)
            try await transport.authenticate()
            try checkConnectionGeneration(generation)
            authenticatedConnectionAttemptID = generation
            updateServerAddress(transport.refreshedServerAddress, for: stored)
            stage = .initialSnapshot
            reconnect.enter(.firstSnapshot)
            pairingProgress = "Loading chats…"
            let newSnapshot = try await transport.firstSnapshot(diagnostics: &reconnect)
            try checkConnectionGeneration(generation)
            Self.connectionLogger.info("Remote ready after \(String(describing: start.duration(to: .now)), privacy: .public)")
            if let attemptID {
                RemotePairingTelemetry.complete(attemptID: attemptID, path: transport.irohPath)
            } else {
                recordReconnect(reconnect.finish(
                    network: networkAtStart, endingNetwork: reconnectNetwork,
                    networkChanged: networkRevisionAtStart != reconnectNetworkRevision, attempt: attemptNumber,
                    recoveryStart: recoveryStart, outcome: .connected, route: transport.irohPath
                ))
            }
            traceStatus = .ok
            return (transport, newSnapshot)
        } catch {
            let path = candidate?.irohPath
            candidate?.close()
            let cancelled = Task.isCancelled || error is CancellationError
            if attemptID == nil {
                let networkChanged = networkRevisionAtStart != reconnectNetworkRevision
                let reason: RemoteReconnectDiagnostics.Reason = if cancelled {
                    networkChanged ? .networkChanged : .cancelled
                } else if error is RemoteIrohIdentityStoreError {
                    .keychainUnavailable
                } else {
                    .init(error: error, stage: reconnect.stage)
                }
                recordReconnect(reconnect.finish(
                    network: networkAtStart, endingNetwork: reconnectNetwork, networkChanged: networkChanged,
                    attempt: attemptNumber, recoveryStart: recoveryStart, outcome: cancelled ? .cancelled : .failed,
                    reason: reason, route: path
                ))
                if !cancelled {
                    Self.connectionLogger.notice("Remote reconnect failed at \(reconnect.stage.rawValue, privacy: .public): \(reason.rawValue, privacy: .public)")
                }
            }
            if !cancelled {
                if let attemptID {
                    traceStatus = .internalError
                    RemotePairingTelemetry.failure(error, stage: stage, path: path, attemptID: attemptID)
                }
                Self.connectionLogger.notice("Remote connection failed at \(stage.rawValue, privacy: .public) after \(String(describing: start.duration(to: .now)), privacy: .public)")
            }
            throw error
        }
    }

    private func updateServerAddress(_ address: RemoteIrohEndpointAddress?, for stored: StoredRemoteCredential) {
        let binding = stored.irohBinding
        guard let address, address != binding.serverAddress else { return }
        let updated = StoredRemoteCredential(
            desktopInstanceID: stored.desktopInstanceID, deviceID: stored.deviceID, credential: stored.credential,
            irohBinding: .init(
                expectedDesktopEndpointID: binding.expectedDesktopEndpointID,
                localMobileEndpointID: binding.localMobileEndpointID,
                wireVersion: binding.wireVersion,
                serverAddress: address
            )
        )
        do {
            try savePairing(.paired(updated))
        } catch {
            Self.connectionLogger.notice("Could not persist refreshed route hints")
        }
    }

    private func connectionMessage(for error: Error) -> String {
        if case RemoteIrohIdentityStoreError.keychain = error {
            return "Unlock this phone so Remote can access its pairing identity, then retry."
        }
        if RemoteNetwork.isFrameTimeout(error) {
            return "Sync stalled. Remote will try again automatically."
        }
        if error is TransportError || (error as? RemotePairingError) == .unavailableDesktop {
            return "Couldn’t reach your Mac. Check that it’s awake and Remote is enabled."
        }
        return error.localizedDescription
    }

    private func requiresNewPairing(_ error: Error, duringPairing: Bool) -> Bool {
        switch error {
        case RemoteGatewayError.credentialRejected, RemoteIrohTransportError.localIdentityChanged,
             RemoteIrohTransportError.legacyPairingOutcomeUnknown,
             RemotePairingError.expiredQRCode:
            return true
        case let RemoteGatewayError.requestRejected(response) where duringPairing:
            return ["pairing_expired", "pairing_unavailable", "pairing_confirmation_rejected",
                    "pairing_in_progress", "already_paired"].contains(response.code)
        default:
            return false
        }
    }

    private func isIncompatibleConnection(_ error: Error) -> Bool {
        switch error {
        case RemoteIrohTransportError.bindingUnavailable, RemoteIrohTransportError.serverEndpointMismatch,
             RemoteIrohTransportError.frameTooLarge, RemoteIrohTransportError.confirmationUnavailable,
             RemoteGatewayError.protocolMismatch, RemoteWireContractError.unsupportedWireVersion,
             RemoteIrohIdentityStoreError.keychain:
            return true
        case let RemoteGatewayError.requestRejected(response):
            return response.code == "response_too_large"
        default:
            return false
        }
    }

    private func refreshSnapshot() async throws {
        guard let client = gateway else { throw RemotePairingError.unavailableDesktop }
        let newSnapshot = try await client.snapshot()
        try Task.checkCancellation()
        guard gateway === client else { throw CancellationError() }
        guard newSnapshot.desktop.instanceID == storedCredential?.desktopInstanceID else {
            throw RemoteIrohTransportError.serverEndpointMismatch
        }
        if let current = snapshot, current.transcriptRevisionEpoch == newSnapshot.transcriptRevisionEpoch,
           newSnapshot.eventCursor < reducer.cursor {
            return
        }
        applySnapshot(newSnapshot)
    }

    private func applySnapshot(_ newSnapshot: RemoteSnapshot) {
        let previousSnapshot = snapshot
        let isRevisionEpochReset = RemoteTranscriptRevisionReconciliation.isEpochReset(
            previous: previousSnapshot, current: newSnapshot
        )
        reducer.replace(with: newSnapshot)
        snapshot = newSnapshot
        authority = Authority(newSnapshot.authorization.defaultLevel)
        reconcileSnapshot(
            previous: previousSnapshot, current: newSnapshot, revisionEpochReset: isRevisionEpochReset
        )
        hasEstablishedSnapshot = true
    }

    private func reconcileSnapshot(
        previous: RemoteSnapshot?,
        current: RemoteSnapshot,
        revisionEpochReset: Bool
    ) {
        selectionOverridesBySessionID = selectionOverridesBySessionID.filter { sessionID, selection in
            guard let authoritative = current.sessions.first(where: { $0.sessionID == sessionID }) else { return true }
            return authoritative.agent != selection.agentID
                || authoritative.model != selection.modelID
                || authoritative.reasoningEffort != selection.reasoningEffort
        }
        if revisionEpochReset {
            knownTranscriptRevisions = [:]
            for sessionID in transcriptTimelinesBySessionID.keys {
                var timeline = transcriptTimelinesBySessionID[sessionID] ?? RemoteTranscriptTimelineState()
                timeline.resetRevisionEpoch()
                transcriptTimelinesBySessionID[sessionID] = timeline
            }
        }

        unseenStateBySessionID = RemoteSessionUnseenProjection.reconcileRunTransitions(
            previous: previous?.sessions ?? [],
            current: current.sessions,
            existing: unseenStateBySessionID,
            visibleSessionID: visibleSessionID,
            isInitial: !hasEstablishedSnapshot || revisionEpochReset
        )

        for session in current.sessions {
            if provisionalSessionRoutes[session.sessionID] != nil {
                provisionalSessionRoutes[session.sessionID] = nil
            }

            if let revision = session.transcriptRevision {
                let known = knownTranscriptRevisions[session.sessionID]
                if hasEstablishedSnapshot,
                   !revisionEpochReset,
                   known.map({ revision > $0 }) ?? true
                {
                    handleTranscriptRevision(sessionID: session.sessionID, revision: revision)
                } else if known == nil || revision >= (known ?? 0) {
                    knownTranscriptRevisions[session.sessionID] = revision
                }
            }
        }

        let currentIDs = Set(current.sessions.map(\.sessionID))
        knownTranscriptRevisions = knownTranscriptRevisions.filter { currentIDs.contains($0.key) }
        unseenStateBySessionID = unseenStateBySessionID.filter { currentIDs.contains($0.key) }

        if revisionEpochReset, let visibleSessionID {
            refreshLatestTranscript(
                for: visibleSessionID,
                revision: current.sessions.first(where: { $0.sessionID == visibleSessionID })?.transcriptRevision
            )
        }
    }

    private func handleTranscriptRevision(sessionID: UUID, revision: UInt64) {
        let disposition = RemoteTranscriptRevisionReconciliation.disposition(
            incomingRevision: revision,
            knownRevision: knownTranscriptRevisions[sessionID],
            loadedRevision: transcriptTimelinesBySessionID[sessionID]?.loadedRevision,
            isVisible: visibleSessionID == sessionID
        )
        guard disposition != .ignore else { return }
        knownTranscriptRevisions[sessionID] = revision
        switch disposition {
        case .ignore, .recordOnly:
            break
        case .refreshLatest:
            acknowledgeSession(sessionID)
            refreshLatestTranscript(for: sessionID, revision: revision)
        case .markUnread:
            unseenStateBySessionID = RemoteSessionUnseenProjection.markingNarrative(
                sessionID: sessionID,
                in: unseenStateBySessionID
            )
        }
    }

    private func handleDeviceToken(_ token: String) {
        pendingNotificationDeviceToken = token
        notificationStatus = "Registering with paired Mac…"
        registerPendingNotificationIfPossible()
    }

    private func registerPendingNotificationIfPossible() {
        guard let token = pendingNotificationDeviceToken,
              storedCredential != nil,
              gateway != nil
        else { return }
        let relayURL = notificationRelayURL.trimmingCharacters(in: .whitespacesAndNewlines)
        sendCommand(
            RemoteCommandRequest(
                operation: .registerNotifications,
                notificationRegistration: RemoteNotificationRegistration(
                    platform: .apns,
                    deviceToken: token,
                    relayURL: relayURL.isEmpty ? nil : relayURL
                )
            )
        )
    }

    private func handleRemoteNotification(_ userInfo: [AnyHashable: Any]) {
        var sessionID = (userInfo["sessionID"] as? String).flatMap(UUID.init)
        var category = userInfo["category"] as? String
        if let envelope = notificationEnvelope(from: userInfo),
           let credential = storedCredential?.credential
        {
            do {
                let payload = try RemoteNotificationCrypto.open(
                    envelope,
                    credential: credential,
                    expectedDesktopInstanceID: storedCredential?.desktopInstanceID,
                    expectedDeviceID: storedCredential?.deviceID
                )
                sessionID = payload.sessionID
                category = payload.category.rawValue
            } catch {
                notificationStatus = "Received an invalid notification envelope."
                return
            }
        }
        pendingSessionID = sessionID
        if let category {
            notificationStatus = "Received \(category.replacingOccurrences(of: "_", with: " ")) notification"
        }
        if connectionState == .connected {
            refreshDiagnostics()
        } else {
            startConnectionRecovery()
        }
    }

    private func notificationEnvelope(from userInfo: [AnyHashable: Any]) -> RemoteNotificationEnvelope? {
        if let dictionary = userInfo["remoteEnvelope"] as? [String: Any],
           let data = try? JSONSerialization.data(withJSONObject: dictionary),
           let envelope = try? JSONDecoder().decode(RemoteNotificationEnvelope.self, from: data)
        {
            return envelope
        }
        if let encoded = userInfo["remoteEnvelope"] as? String,
           let data = Data(base64Encoded: encoded),
           let envelope = try? JSONDecoder().decode(RemoteNotificationEnvelope.self, from: data)
        {
            return envelope
        }
        return nil
    }

    @discardableResult
    private func sendCommand(
        _ request: RemoteCommandRequest,
        attachments: [RemoteDraftAttachment] = []
    ) -> UUID {
        clearTransientError()
        commandActivity.begin(request.commandID)
        Task { [weak self] in
            guard let self else { return }
            defer { commandActivity.end(request.commandID) }
            var dispatched = false
            do {
                guard let gateway else { throw RemotePairingError.unavailableDesktop }
                if !attachments.isEmpty {
                    guard agentCatalogMetadata?.supportsAttachments == true else {
                        throw RemoteGatewayError.attachmentRejected("Update RepoPrompt on the Mac to send attachments.")
                    }
                    try await uploadAttachments(attachments, submissionID: request.commandID, gateway: gateway)
                }
                guard self.gateway === gateway else { throw RemotePairingError.unavailableDesktop }
                dispatched = true
                let response = try await gateway.command(request)
                guard self.gateway === gateway else {
                    throw RemotePairingError.unavailableDesktop
                }
                guard response.accepted else {
                    if request.operation == .configureSession || request.operation == .configureTools {
                        try? await refreshSnapshot()
                    }
                    let message = await refreshedRejectionMessage(
                        request, fallback: response.message ?? "The command was not accepted."
                    )
                    recordCommandCompletion(RemoteCommandCompletion(
                        commandID: request.commandID,
                        operation: request.operation,
                        outcome: .rejected
                    ))
                    presentError(message)
                    return
                }

                let accepted = RemoteAcceptedCommand(response: response, operation: request.operation)
                lastAcceptedCommand = accepted
                lastAcceptedCommandID = accepted.commandID
                if let sessionID = response.sessionID ?? request.sessionID,
                   let resolvedSelection = response.resolvedSelection
                {
                    selectionOverridesBySessionID[sessionID] = resolvedSelection
                }
                if let provisional = RemoteProvisionalSessionRoute.acceptedStart(
                    response: response,
                    request: request
                ) {
                    provisionalSessionRoutes[provisional.sessionID] = provisional
                    pendingSessionID = provisional.sessionID
                }
                recordCommandCompletion(RemoteCommandCompletion(
                    commandID: request.commandID,
                    operation: request.operation,
                    outcome: .accepted
                ))
                if request.operation == .contextBuilder {
                    contextBuilderResult = response.contextBuilderResult
                }
                if request.operation == .registerNotifications {
                    notificationStatus = "Registered; relay URL \(request.notificationRegistration?.relayURL == nil ? "not configured" : "configured")"
                }

                do {
                    try await refreshSnapshot()
                    refreshChatList()
                    if request.operation != .startRun,
                       let sessionID = response.sessionID ?? request.sessionID
                    {
                        refreshLatestTranscript(
                            for: sessionID,
                            revision: snapshot?.sessions.first(where: { $0.sessionID == sessionID })?.transcriptRevision
                        )
                    }
                    refreshDiagnostics()
                } catch {
                    guard !isExpectedCancellation(error) else { return }
                    presentError("Command accepted, but remote state could not be refreshed: \(error.localizedDescription)")
                }
            } catch {
                if request.operation == .configureSession || request.operation == .configureTools {
                    try? await refreshSnapshot()
                }
                recordCommandCompletion(RemoteCommandCompletion(
                    commandID: request.commandID,
                    operation: request.operation,
                    outcome: .failed
                ))
                guard !isExpectedCancellation(error) else { return }
                if let gatewayError = error as? RemoteGatewayError {
                    if request.operation == .respond,
                       case let .requestRejected(response) = gatewayError, response.code == "command_rejected"
                    {
                        let message = await refreshedRejectionMessage(request, fallback: response.message)
                        presentError(message)
                    } else {
                        presentError(gatewayError.localizedDescription)
                    }
                } else if dispatched {
                    presentError("Couldn’t confirm the command’s outcome. Check the changes on your Mac before sending it again.")
                } else {
                    presentError(error.localizedDescription)
                }
            }
        }
        return request.commandID
    }

    private func refreshedRejectionMessage(_ request: RemoteCommandRequest, fallback: String) async -> String {
        guard request.operation == .respond, let interactionID = request.interactionID else { return fallback }
        do {
            try await refreshSnapshot()
        } catch {
            return fallback
        }
        let currentID = snapshot?.sessions.first(where: { $0.sessionID == request.sessionID })?.pendingInteraction?.id
        if currentID.flatMap(UUID.init(uuidString:)) != interactionID {
            return "That request is no longer active. The chat has been refreshed."
        }
        return fallback
    }

    private func uploadAttachments(
        _ attachments: [RemoteDraftAttachment],
        submissionID: UUID,
        gateway: any RemoteGatewayTransport
    ) async throws {
        for attachment in attachments {
            var offset = 0
            repeat {
                try Task.checkCancellation()
                let end = min(offset + RemoteAttachmentLimits.maxChunkBytes, attachment.bytes.count)
                let chunk = RemoteAttachmentChunk(
                    submissionID: submissionID, attachmentID: attachment.id, fileName: attachment.name,
                    fileSize: attachment.bytes.count, offset: offset,
                    bytes: attachment.bytes.subdata(in: offset ..< end)
                )
                let response = try await gateway.command(.init(operation: .uploadAttachment, attachmentChunk: chunk))
                guard response.accepted else {
                    throw RemoteGatewayError.attachmentRejected(response.message ?? "The Mac rejected this attachment.")
                }
                offset = end
            } while offset < attachment.bytes.count
        }
    }

    private func recordCommandCompletion(_ completion: RemoteCommandCompletion) {
        lastCommandCompletion = completion
        commandActivity.record(completion)
    }

    func presentError(_ message: String) {
        transientErrorTask?.cancel()
        transientErrorID = UUID()
        let errorID = transientErrorID
        transientError = message
        transientErrorTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, let self, self.transientErrorID == errorID else { return }
            self.transientError = nil
        }
    }

    private func clearTransientError() {
        transientErrorTask?.cancel()
        transientErrorTask = nil
        transientErrorID = UUID()
        transientError = nil
    }

    private func handleAppliedEvent(_ event: RemoteEvent) {
        guard event.type == .transcriptItemsAppended,
              let sessionID = event.sessionID,
              case let .text(revisionText) = event.payload,
              let revision = UInt64(revisionText)
        else {
            // Ordered reduction has already advanced the cursor. Malformed
            // revision payloads wait for the next authoritative snapshot.
            return
        }
        handleTranscriptRevision(sessionID: sessionID, revision: revision)
    }

    private func consumeEvents(
        using transport: any RemoteGatewayTransport,
        generation: UUID
    ) async throws {
        while !Task.isCancelled {
            do {
                for try await event in transport.events(after: reducer.cursor) {
                    try checkConnectionGeneration(generation)
                    let previousSnapshot = snapshot
                    switch reducer.apply(event) {
                    case .applied:
                        snapshot = reducer.snapshot
                        if let currentSnapshot = snapshot {
                            reconcileSnapshot(previous: previousSnapshot, current: currentSnapshot, revisionEpochReset: false)
                        }
                        handleAppliedEvent(event)
                    case .duplicate:
                        break
                    case .snapshotRequired:
                        throw RemoteGatewayError.snapshotRequired
                    }
                }
                try checkConnectionGeneration(generation)
                throw RemotePairingError.unavailableDesktop
            } catch RemoteGatewayError.snapshotRequired {
                try await refreshSnapshot()
                if let visibleSessionID { loadTranscript(for: visibleSessionID) }
                try await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func isExpectedCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }
}

struct SessionRow: Identifiable, Equatable {
    let id: UUID
    let workspaceID: String
    let title: String
    let runState: RemoteRunState
    let status: String
    let detail: String
    let isLive: Bool
    let workflow: String?
    let workflowID: String?
    let agent: String?
    let model: String?
    let reasoningEffort: String?
    let configurationControls: RemoteSessionConfigurationControls?
    let runStartedAt: Date?
    let lifecycleStage: String?
    let latestMeaningfulActivity: String?
    let pendingInteraction: RemoteInteractionSummary?
    let parentSessionID: UUID?
    let childSessionIDs: [UUID]
    let worktreeSummary: String?
    let mergeAttention: String?
    let failureSummary: String?
    let lastUpdatedAt: Date

    init(_ session: RemoteSessionSummary, selectionOverride: RemoteAgentSelection? = nil) {
        id = session.sessionID
        workspaceID = session.workspaceID
        title = session.sessionName ?? session.workflow ?? "Agent session"
        runState = session.runState
        status = session.runState.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
        detail = session.latestMeaningfulActivity ?? (session.isLive ? "Live" : "Saved session")
        isLive = session.isLive
        workflow = session.workflow
        workflowID = session.workflowID
        agent = selectionOverride?.agentID ?? session.agent
        model = selectionOverride?.modelID ?? session.model
        reasoningEffort = selectionOverride.map(\.reasoningEffort) ?? session.reasoningEffort
        configurationControls = session.configurationControls
        runStartedAt = session.runStartedAt
        lifecycleStage = session.lifecycleStage
        latestMeaningfulActivity = session.latestMeaningfulActivity
        pendingInteraction = session.pendingInteraction
        parentSessionID = session.parentSessionID
        childSessionIDs = session.childSessionIDs
        worktreeSummary = session.worktreeSummary
        mergeAttention = session.mergeAttention
        failureSummary = session.failureSummary
        lastUpdatedAt = session.lastUpdatedAt
    }
}

struct RemoteChatListItem: Identifiable, Equatable {
    let id: UUID
    let workspaceID: String
    let title: String
    let runState: RemoteRunState
    let lastActivityAt: Date
    let preview: String?
    let turnCount: Int?
    let isLive: Bool
    let liveDetail: String?
    let isProvisional: Bool

    init(historyEntry: RemoteHistoryEntry, liveSession: SessionRow?) {
        id = historyEntry.id
        workspaceID = historyEntry.workspaceID
        title = liveSession?.title ?? historyEntry.sessionName
        runState = liveSession?.runState ?? historyEntry.runState
        lastActivityAt = max(historyEntry.lastActivityAt, liveSession?.lastUpdatedAt ?? .distantPast)
        preview = historyEntry.preview
        turnCount = historyEntry.turnCount
        isLive = liveSession?.isLive == true
        liveDetail = liveSession?.detail
        isProvisional = false
    }

    init(liveSession: SessionRow) {
        id = liveSession.id
        workspaceID = liveSession.workspaceID
        title = liveSession.title
        runState = liveSession.runState
        lastActivityAt = liveSession.lastUpdatedAt
        preview = nil
        turnCount = nil
        isLive = liveSession.isLive
        liveDetail = liveSession.detail
        isProvisional = false
    }

    init(provisionalRoute: RemoteProvisionalSessionRoute) {
        id = provisionalRoute.sessionID
        workspaceID = provisionalRoute.workspaceID
        title = provisionalRoute.title
        runState = provisionalRoute.runState
        lastActivityAt = provisionalRoute.createdAt
        preview = nil
        turnCount = nil
        isLive = true
        liveDetail = "Waiting for the Mac to publish this session…"
        isProvisional = true
    }

    init(
        id: UUID,
        workspaceID: String,
        title: String,
        runState: RemoteRunState,
        lastActivityAt: Date,
        preview: String? = nil,
        turnCount: Int? = nil,
        isLive: Bool = false,
        liveDetail: String? = nil,
        isProvisional: Bool = false
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.title = title
        self.runState = runState
        self.lastActivityAt = lastActivityAt
        self.preview = preview
        self.turnCount = turnCount
        self.isLive = isLive
        self.liveDetail = liveDetail
        self.isProvisional = isProvisional
    }

    var status: String {
        runState.rawValue.replacingOccurrences(of: "_", with: " ").capitalized
    }

    var detail: String? {
        if let liveDetail, !liveDetail.isEmpty {
            return liveDetail
        }
        if let preview, !preview.isEmpty {
            return preview
        }
        return nil
    }
}

enum RemoteChatListProjection {
    static func project(
        historyEntries: [RemoteHistoryEntry],
        sessions: [SessionRow],
        provisionalRoutes: [RemoteProvisionalSessionRoute] = [],
        workspaceID: String
    ) -> [RemoteChatListItem] {
        let entries = historyEntries.filter { $0.workspaceID == workspaceID }
        let allEntryIDs = Set(historyEntries.map(\.id))
        let liveSessionsByID = sessions.reduce(into: [UUID: SessionRow]()) { result, session in
            if let existing = result[session.id], existing.lastUpdatedAt >= session.lastUpdatedAt {
                return
            }
            result[session.id] = session
        }

        var items = entries.map { entry in
            RemoteChatListItem(historyEntry: entry, liveSession: liveSessionsByID[entry.id])
        }
        items += sessions
            .filter {
                $0.workspaceID == workspaceID
                    && $0.isLive
                    && !allEntryIDs.contains($0.id)
            }
            .map(RemoteChatListItem.init(liveSession:))

        let authoritativeIDs = Set(items.map(\.id))
        items += provisionalRoutes
            .filter { $0.workspaceID == workspaceID && !authoritativeIDs.contains($0.sessionID) }
            .map(RemoteChatListItem.init(provisionalRoute:))

        return items.sorted {
            if $0.lastActivityAt != $1.lastActivityAt {
                return $0.lastActivityAt > $1.lastActivityAt
            }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}
