import Combine
import Foundation
import Network
import OSLog
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
    @Published private(set) var networkStatus: String = "Unknown"
    @Published private(set) var lastConnectionEvent: String = "Not connected"
    @Published private(set) var transportStatus: String = "None"
    @Published private(set) var irohPathStatus: String = "Unknown"
    @Published var notificationRelayURL: String {
        didSet { UserDefaults.standard.set(notificationRelayURL, forKey: Self.notificationRelayURLKey) }
    }

    private static let notificationRelayURLKey = "RepoPromptRemote.notificationRelayURL"
    private static let unpairLogger = Logger(subsystem: "com.repoprompt.remote", category: "Unpair")
    private static let unpairDeadline: Duration = .milliseconds(1_500)
    private let credentialStore = RemoteCredentialStore()
    private let irohIdentityStore = RemoteIrohIdentityStore()
    private var activeImageReads = 0
    private var waitingImageReads: [(UUID, CheckedContinuation<Void, Error>)] = []
    private let imageThumbnails: NSCache<NSString, NSData> = {
        let cache = NSCache<NSString, NSData>()
        cache.totalCostLimit = 8 * 1024 * 1024
        return cache
    }()
    private var gateway: (any RemoteGatewayTransport)?
    private var storedCredential: StoredRemoteCredential?
    private var reducer = RemoteSnapshotReducer()
    private var eventTask: Task<Void, Never>?
    private var chatListTask: Task<Void, Never>?
    private var selectedHistoryWorkspaceID: String?
    private var pairingTask: Task<Void, Never>?
    private var pairingAttemptID: UUID?
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
    private var irohGeneration: UInt64 = 0
    private var isSceneActive = true
    private var lastSatisfiedInterface: String?

    init() {
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
        networkMonitor = RemoteNetworkMonitor { [weak self] status, interface in
            guard let self else { return }
            switch status {
            case .satisfied:
                let pathChanged = self.lastSatisfiedInterface != nil && self.lastSatisfiedInterface != interface
                self.lastSatisfiedInterface = interface
                self.networkStatus = "Online (\(interface))"
                if self.isSceneActive, pathChanged, self.connectionState == .connected,
                   let stored = self.storedCredential
                {
                    self.activeConnectionAttemptID = nil
                    self.eventTask?.cancel()
                    self.eventTask = nil
                    self.endConnectionCycle()
                    self.connectionState = .disconnected
                    self.lastConnectionEvent = "Network path changed; reconnecting"
                    Task { await self.connect(using: stored) }
                } else if self.isSceneActive, self.connectionState == .disconnected,
                          let stored = self.storedCredential
                {
                    Task { await self.connect(using: stored) }
                }
            case .unsatisfied:
                self.networkStatus = "Offline"
                self.lastConnectionEvent = "Network unavailable"
                if self.storedCredential != nil {
                    self.endConnectionCycle()
                    self.connectionState = .disconnected
                }
            case .requiresConnection:
                self.networkStatus = "Connection required"
            @unknown default:
                self.networkStatus = "Unknown"
            }
        }
        networkMonitor?.start()
        Task { [weak self] in
            await self?.restorePairing()
        }
    }

    deinit {
        eventTask?.cancel()
        chatListTask?.cancel()
        transcriptInitialTasks.values.forEach { $0.cancel() }
        transcriptLatestTasks.values.forEach { $0.cancel() }
        transcriptOlderTasks.values.forEach { $0.cancel() }
        transcriptDetailTasks.values.forEach { $0.cancel() }
        pairingTask?.cancel()
        networkMonitor?.stop()
        transientErrorTask?.cancel()
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
    }

    var isPaired: Bool {
        storedCredential != nil
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
        unpairWork?.cancel()
        unpairWork = nil
        unpairWorkID = nil
        clearTransientError()
        showingPairing = true
        connectionState = .discovering
    }

    func handleQRCode(_ value: String) {
        guard pairingTask == nil else { return }
        do {
            let advertisement = try RemotePairingDecoder.decode(value)
            clearTransientError()
            startPairing(advertisement)
        } catch {
            RemotePairingTelemetry.failure(error, attempt: .init(stage: .decodeQR))
            presentError(error.localizedDescription)
        }
    }

    func cancelPairing() {
        showingPairing = false
        pairingTask?.cancel()
        pairingTask = nil
        pairingAttemptID = nil
        if storedCredential == nil { connectionState = .unpaired }
    }

    func setSceneActive(_ active: Bool) {
        isSceneActive = active
        if active {
            if connectionState == .disconnected, let storedCredential {
                Task { await connect(using: storedCredential) }
            }
        } else {
            pairingTask?.cancel()
            pairingTask = nil
            pairingAttemptID = nil
            activeConnectionAttemptID = nil
            eventTask?.cancel()
            eventTask = nil
            cancelAllTranscriptTasks()
            endConnectionCycle()
            if storedCredential != nil { connectionState = .disconnected }
        }
    }

    func disconnect() {
        activeConnectionAttemptID = nil
        eventTask?.cancel()
        eventTask = nil
        cancelAllTranscriptTasks()
        endConnectionCycle()
        connectionState = storedCredential == nil ? .unpaired : .disconnected
    }

    @discardableResult
    func startRun(
        in workspaceID: String,
        message: String,
        workflowID: String? = nil,
        agentID: String? = nil,
        modelID: String? = nil,
        reasoningEffort: String? = nil,
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
                guard let gateway else { throw RemotePairingError.unavailableDesktop }
                diagnostics = try await gateway.diagnostics()
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
        secret: String? = nil
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
                secret: secret
            )
        )
    }

    func refreshRemoteState() {
        clearTransientError()
        Task { [weak self] in
            guard let self else { return }
            do {
                guard gateway != nil else { throw RemotePairingError.unavailableDesktop }
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

    func refreshChatList() {
        guard let gateway, let selection = selectedHistoryWorkspaceID,
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

    func loadTranscript(for sessionID: UUID) {
        acknowledgeSession(sessionID)
        cancelTranscriptMutationTasks(for: sessionID)
        let generation = beginTranscriptLoad(.initial, for: sessionID)
        transcriptInitialTasks[sessionID] = Task { [weak self] in
            guard let self else { return }
            do {
                guard let gateway else { throw RemotePairingError.unavailableDesktop }
                let page = try await gateway.recentTranscript(sessionID: sessionID)
                guard !Task.isCancelled else { return }
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
        activeConnectionAttemptID = nil
        eventTask?.cancel()
        eventTask = nil
        cancelAllTranscriptTasks()
        let preferredGateway = gateway
        gateway = nil
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

    private func clearLocalPairing() {
        var keychainFailureCount = 0
        do {
            try credentialStore.delete()
        } catch {
            keychainFailureCount += 1
        }
        do {
            try irohIdentityStore.delete()
        } catch {
            keychainFailureCount += 1
        }
        if keychainFailureCount == 0 {
            Self.unpairLogger.info("Phone credential and mobile Iroh identity deleted")
        } else {
            Self.unpairLogger.error("Local Unpair completed with \(keychainFailureCount, privacy: .public) Keychain deletion failure(s)")
        }

        storedCredential = nil
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
        showingPairing = false
        connectionState = .unpaired
        clearTransientError()
    }

    private func restorePairing() async {
        do {
            guard let stored = try credentialStore.load() else { return }
            storedCredential = stored
            connectionState = .disconnected
            await connect(using: stored)
        } catch {
            storedCredential = nil
            connectionState = .unpaired
        }
    }

    private func startPairing(_ advertisement: RemoteIrohPairingAdvertisement) {
        guard pairingTask == nil else { return }
        let attemptID = UUID()
        pairingAttemptID = attemptID
        pairingTask = Task { [weak self] in
            guard let self else { return }
            await self.pair(advertisement, attemptID: attemptID)
            guard self.pairingAttemptID == attemptID else { return }
            self.pairingAttemptID = nil
            self.pairingTask = nil
        }
    }

    private func pair(
        _ advertisement: RemoteIrohPairingAdvertisement,
        attemptID: UUID
    ) async {
        guard pairingAttemptID == attemptID else { return }
        connectionState = .discovering
        var diagnostics = RemotePairingTelemetry.Attempt()
        let trace = RemotePairingTelemetry.begin(attemptID: attemptID)
        var traceStatus = RemotePairingTelemetry.TraceStatus.cancelled
        defer { trace.finish(status: traceStatus) }
        var candidateTransport: RemoteIrohGatewayTransport?
        do {
            let identity = try irohIdentityStore.loadOrCreate()
            irohGeneration &+= 1
            let (response, transport) = try await RemoteIrohGatewayTransport.pair(
                advertisement: advertisement,
                identitySecret: identity.secret,
                generation: irohGeneration,
                deviceName: UIDevice.current.name,
                attemptID: attemptID,
                diagnostics: &diagnostics
            )
            candidateTransport = transport
            try Task.checkCancellation()
            guard pairingAttemptID == attemptID, isSceneActive else {
                transport.close()
                return
            }
            let stored = StoredRemoteCredential(
                desktopInstanceID: advertisement.desktopInstanceID,
                deviceID: response.pairingResponse.deviceID,
                credential: response.pairingResponse.credential,
                irohBinding: StoredRemoteIrohBinding(
                    expectedDesktopEndpointID: response.serverEndpointID,
                    localMobileEndpointID: response.clientEndpointID,
                    serverAddress: advertisement.server
                )
            )
            diagnostics.stage = .saveCredential
            try credentialStore.save(stored)
            storedCredential = stored
            diagnostics.stage = .initialSnapshot
            try await refreshSnapshot(using: transport)
            guard pairingAttemptID == attemptID, isSceneActive else {
                transport.close()
                return
            }
            gateway = transport
            candidateTransport = nil
            refreshChatList()
            showingPairing = false
            connectionState = .connected
            transportStatus = "Iroh"
            irohPathStatus = transport.irohPath?.rawValue ?? "unknown"
            lastConnectionEvent = "Connected to Mac with Iroh"
            startEventStream()
            refreshDiagnostics()
            registerPendingNotificationIfPossible()
            RemotePairingTelemetry.complete(attemptID: attemptID, path: diagnostics.path)
            traceStatus = .ok
        } catch {
            candidateTransport?.close()
            guard !isExpectedCancellation(error), pairingAttemptID == attemptID, isSceneActive else { return }
            traceStatus = .internalError
            RemotePairingTelemetry.failure(error, attempt: diagnostics, attemptID: attemptID)
            connectionState = storedCredential == nil ? .unpaired : .disconnected
            lastConnectionEvent = connectionEvent(for: error)
            presentError(error.localizedDescription)
        }
    }

    private func connect(using stored: StoredRemoteCredential) async {
        guard isSceneActive,
              connectionState != .connected,
              activeConnectionAttemptID == nil,
              storedCredential == stored
        else { return }

        let attemptID = UUID()
        activeConnectionAttemptID = attemptID
        defer {
            if activeConnectionAttemptID == attemptID { activeConnectionAttemptID = nil }
        }

        var candidate: RemoteIrohGatewayTransport?
        do {
            let identity = try irohIdentityStore.loadOrCreate()
            irohGeneration &+= 1
            let transport = try await RemoteIrohGatewayTransport.connect(
                stored: stored,
                identitySecret: identity.secret,
                generation: irohGeneration
            )
            candidate = transport
            guard activeConnectionAttemptID == attemptID, isSceneActive else {
                transport.close()
                return
            }
            try await refreshSnapshot(using: transport, expectedConnectionAttemptID: attemptID)
            guard activeConnectionAttemptID == attemptID, isSceneActive else {
                transport.close()
                return
            }
            gateway = transport
            refreshChatList()
            connectionState = .connected
            transportStatus = "Iroh"
            irohPathStatus = transport.irohPath?.rawValue ?? "unknown"
            lastConnectionEvent = "Reconnected to Mac with Iroh"
            clearTransientError()
            startEventStream()
            refreshDiagnostics()
            registerPendingNotificationIfPossible()
        } catch {
            candidate?.close()
            guard activeConnectionAttemptID == attemptID, isSceneActive, !isExpectedCancellation(error) else { return }
            switch error {
            case RemoteGatewayError.credentialRejected, RemoteIrohTransportError.localIdentityChanged:
                clearLocalPairing()
                presentError(error.localizedDescription)
            default:
                endConnectionCycle()
                connectionState = .disconnected
                lastConnectionEvent = connectionEvent(for: error)
            }
        }
    }

    private func refreshSnapshot(
        using client: (any RemoteGatewayTransport)? = nil,
        expectedConnectionAttemptID: UUID? = nil
    ) async throws {
        guard let client = client ?? gateway else { throw RemotePairingError.unavailableDesktop }
        let newSnapshot = try await client.snapshot()
        if let expectedConnectionAttemptID {
            guard activeConnectionAttemptID == expectedConnectionAttemptID else {
                throw CancellationError()
            }
        }
        let previousSnapshot = snapshot
        let isRevisionEpochReset = RemoteTranscriptRevisionReconciliation.isEpochReset(
            previous: previousSnapshot,
            current: newSnapshot
        )
        reducer.replace(with: newSnapshot)
        snapshot = newSnapshot
        authority = Authority(newSnapshot.authorization.defaultLevel)
        reconcileSnapshot(
            previous: previousSnapshot,
            current: newSnapshot,
            revisionEpochReset: isRevisionEpochReset
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
        } else if let storedCredential {
            Task { await connect(using: storedCredential) }
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
            do {
                guard let gateway else { throw RemotePairingError.unavailableDesktop }
                if !attachments.isEmpty {
                    guard agentCatalogMetadata?.supportsAttachments == true else {
                        throw RemoteGatewayError.attachmentRejected("Update RepoPrompt on the Mac to send attachments.")
                    }
                    try await uploadAttachments(attachments, submissionID: request.commandID, gateway: gateway)
                }
                let response = try await gateway.command(request)
                guard response.accepted else {
                    if request.operation == .configureSession || request.operation == .configureTools {
                        try? await refreshSnapshot()
                    }
                    recordCommandCompletion(RemoteCommandCompletion(
                        commandID: request.commandID,
                        operation: request.operation,
                        outcome: .rejected
                    ))
                    presentError(response.message ?? "The command was not accepted.")
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
                        try? await refreshSnapshot()
                        presentError("That interaction is no longer active. Refreshed from the Mac.")
                    } else {
                        presentError(gatewayError.localizedDescription)
                    }
                } else {
                    presentError(error.localizedDescription)
                }
            }
        }
        return request.commandID
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

    private func startEventStream() {
        eventTask?.cancel()
        eventTask = Task { [weak self] in
            guard let self else { return }
            eventLoop: while !Task.isCancelled {
                do {
                    guard let gateway = self.gateway else { return }
                    self.irohPathStatus = gateway.irohPath?.rawValue ?? "unknown"
                    let events = gateway.events(after: self.reducer.cursor)
                    for try await event in events {
                        guard !Task.isCancelled else { return }
                        let previousSnapshot = self.snapshot
                        switch self.reducer.apply(event) {
                        case .applied:
                            self.snapshot = self.reducer.snapshot
                            if let currentSnapshot = self.snapshot {
                                self.reconcileSnapshot(
                                    previous: previousSnapshot,
                                    current: currentSnapshot,
                                    revisionEpochReset: false
                                )
                            }
                            self.handleAppliedEvent(event)
                        case .duplicate:
                            self.snapshot = self.reducer.snapshot
                        case .snapshotRequired:
                            try await self.refreshSnapshot()
                        }
                    }
                    // The desktop currently serves /events as a short
                    // replay and closes the response. Treat normal EOF as the
                    // next long-poll cycle, not as a lost Mac.
                    try await Task.sleep(nanoseconds: 500_000_000)
                    continue eventLoop
                } catch RemoteGatewayError.snapshotRequired {
                    do {
                        try await self.refreshSnapshot()
                    } catch {
                        guard !self.isExpectedCancellation(error) else { return }
                        self.endConnectionCycle()
                        self.connectionState = .disconnected
                    }
                } catch {
                    guard !self.isExpectedCancellation(error) else { return }
                    self.endConnectionCycle()
                    self.connectionState = .disconnected
                    self.lastConnectionEvent = self.connectionEvent(for: error)
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                    guard !Task.isCancelled, let stored = self.storedCredential else { return }
                    await self.connect(using: stored)
                    if self.connectionState == .connected { return }
                }
            }
        }
    }

    private func connectionEvent(for error: Error) -> String {
        if error is RemoteGatewayError {
            switch error as? RemoteGatewayError {
            case .credentialRejected?: return "Credential rejected; re-pair required"
            default: return "Mac unavailable or restarted; retrying"
            }
        }
        return "Connection failed; retrying"
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
