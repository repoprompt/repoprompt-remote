import Foundation
@testable import RepoPromptRemote
import RepoPromptRemoteProtocol
import XCTest

final class RemoteIrohFoundationTests: XCTestCase {
    @MainActor
    func testAppRejectsAnInvalidPairingCode() {
        let model = RemoteAppModel(credentialStore: RecoveryStore(record: nil), monitorNetwork: false)
        model.beginPairing()
        model.handleQRCode("invalid-pairing-link")
        XCTAssertEqual(model.transientError, RemotePairingError.invalidQRCode.errorDescription)
    }

    func testPairingTelemetryClassifiesUntrustedPeerErrors() {
        let untrusted = RemoteGatewayError.requestRejected(.init(code: "untrusted-code", message: "untrusted-message"))
        XCTAssertEqual(RemotePairingTelemetry.failureReason(untrusted), "desktop_rejected_request")
        let rejected = RemoteGatewayError.requestRejected(.init(code: "pairing_failed", message: "untrusted-message"))
        XCTAssertEqual(RemotePairingTelemetry.failureReason(rejected), "desktop_rejected_pairing")
    }

    func testIrohPairingCodeDecodesFromJSONAndCopiedLink() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let code = makeIrohCode(expiresAt: now.addingTimeInterval(300))
        let data = try JSONEncoder().encode(code)

        XCTAssertEqual(
            try RemotePairingDecoder.decode(String(decoding: data, as: UTF8.self), at: now),
            code
        )
        XCTAssertEqual(
            try RemotePairingDecoder.decode(pairingLink(for: data), at: now),
            code
        )
    }

    func testIrohPairingDecoderRejectsExpiryAndUnauthenticatedBindingFields() throws {
        let now = Date(timeIntervalSince1970: 2_000)
        let expired = try JSONEncoder().encode(makeIrohCode(expiresAt: now))
        XCTAssertThrowsError(
            try RemotePairingDecoder.decode(String(decoding: expired, as: UTF8.self), at: now)
        ) { error in
            XCTAssertEqual(error as? RemotePairingError, .expiredQRCode)
        }

        let validExpiry = now.addingTimeInterval(300)
        for server in [
            RemoteIrohEndpointAddress(endpointID: "not-an-endpoint", transportAddressJSON: "{}"),
            RemoteIrohEndpointAddress(endpointID: endpointID("a")),
            RemoteIrohEndpointAddress(endpointID: endpointID("a"), directAddresses: [String(repeating: "a", count: 257)], transportAddressJSON: "{}")
        ] {
            let advertisement = RemoteIrohPairingAdvertisement(
                desktopInstanceID: "desktop",
                server: server,
                oneTimeSecret: "one-time-secret",
                expiresAt: validExpiry
            )
            let encoded = try JSONEncoder().encode(advertisement)
            XCTAssertThrowsError(
                try RemotePairingDecoder.decode(String(decoding: encoded, as: UTF8.self), at: now)
            ) { error in
                XCTAssertEqual(error as? RemotePairingError, .invalidQRCode)
            }
        }
    }

    func testPairingDecoderRejectsOversizedPayloadBeforeJSONDecoding() {
        let oversized = "{\"padding\":\"\(String(repeating: "a", count: 33 * 1_024))\"}"
        XCTAssertThrowsError(try RemotePairingDecoder.decode(oversized)) { error in
            XCTAssertEqual(error as? RemotePairingError, .invalidQRCode)
        }
    }

    func testStoredMobileCredentialRoundTripsWithRequiredIrohBinding() throws {
        let endpoint = makeIrohCode(expiresAt: Date()).server
        let stored = StoredRemoteCredential(
            desktopInstanceID: "desktop",
            deviceID: "device",
            credential: "bearer",
            irohBinding: StoredRemoteIrohBinding(
                expectedDesktopEndpointID: endpoint.endpointID,
                localMobileEndpointID: endpointID("b"),
                serverAddress: endpoint
            )
        )
        let data = try JSONEncoder().encode(stored)
        XCTAssertEqual(try StoredRemotePairing.decode(data), .paired(stored))
        let updated = try StoredRemotePairing.paired(stored).encodedForKeychain()
        XCTAssertEqual(try JSONDecoder().decode(StoredRemoteCredential.self, from: updated), stored)
    }

    @MainActor
    func testFailedKeychainSaveNeverConfirmsAndRestartResumesTheSameAttempt() async throws {
        let attempt = recoveryAttempt()
        let credential = recoveryCredential(for: attempt)
        let store = RecoveryStore(record: .preparing(attempt))
        store.failNextSave = true
        let transport = RecoveryTransport()
        let factory = RemoteAppModel.ConnectionFactory(
            prepare: { suppliedAttempt, _, _, _ in
                XCTAssertEqual(suppliedAttempt, attempt)
                return (credential, transport)
            },
            open: { _, _, _ in throw RecoveryFault.disconnected }
        )
        let first = recoveryModel(store: store, factory: factory)
        await waitForRecovery { first.connectionIssue != nil && !first.isRecovering }
        XCTAssertFalse(first.isPaired)
        XCTAssertEqual(store.record, .preparing(attempt))
        XCTAssertEqual(transport.confirmations, [])
        first.disconnect()

        let restartedStore = try RecoveryStore(restarting: store)
        transport.onConfirm = { _ in
            XCTAssertEqual(restartedStore.record, .confirming(credential, attemptID: attempt.id))
        }
        let restarted = recoveryModel(store: restartedStore, factory: factory)
        await waitForRecovery { restarted.connectionState == .connected }
        XCTAssertEqual(transport.confirmations, [attempt.id])
        XCTAssertEqual(restartedStore.record, .paired(credential))
        restarted.disconnect()
    }

    @MainActor
    func testLostFinalAckAndFailedFirstSyncRecoverAcrossRestartWithoutRePreparing() async throws {
        let attempt = recoveryAttempt()
        let credential = recoveryCredential(for: attempt)
        let store = RecoveryStore(record: .confirming(credential, attemptID: attempt.id))
        let lostAck = RecoveryTransport()
        lostAck.onConfirm = { _ in throw RecoveryFault.disconnected }
        let first = recoveryModel(store: store, factory: .init(
            prepare: { _, _, _, _ in throw RecoveryFault.unexpectedPrepare },
            open: { _, _, _ in lostAck }
        ))
        await waitForRecovery { first.connectionIssue != nil }
        XCTAssertFalse(first.isPaired)
        XCTAssertEqual(lostAck.confirmations, [attempt.id])
        XCTAssertEqual(store.record, .confirming(credential, attemptID: attempt.id))
        first.disconnect()

        let restartedStore = try RecoveryStore(restarting: store)
        let failedSync = RecoveryTransport()
        failedSync.syncFailure = RecoveryFault.disconnected
        let ready = RecoveryTransport()
        var opens = 0
        let restarted = recoveryModel(store: restartedStore, factory: .init(
            prepare: { _, _, _, _ in throw RecoveryFault.unexpectedPrepare },
            open: { _, _, _ in
                opens += 1
                return opens == 1 ? failedSync : ready
            }
        ))
        await waitForRecovery { restarted.connectionIssue != nil }
        XCTAssertTrue(restarted.isPaired)
        XCTAssertEqual(restarted.connectionState, .disconnected)
        XCTAssertNil(restarted.snapshot)
        XCTAssertEqual(failedSync.confirmations, [attempt.id])
        XCTAssertEqual(restartedStore.record, .paired(credential))

        await waitForRecovery(timeout: .seconds(4)) { restarted.connectionState == .connected }
        XCTAssertEqual(opens, 2)
        XCTAssertEqual(ready.confirmations, [])
        XCTAssertNotNil(restarted.snapshot)
        restarted.disconnect()
    }

    @MainActor
    func testRepeatedDialFailuresKeepRetryingUntilReady() async {
        let store = RecoveryStore(record: .paired(recoveryCredential(for: recoveryAttempt())))
        var dials = 0
        let ready = RecoveryTransport()
        let model = recoveryModel(store: store, factory: .init(
            prepare: { _, _, _, _ in throw RecoveryFault.unexpectedPrepare },
            open: { _, _, _ in
                dials += 1
                if dials < 3 { throw RecoveryFault.disconnected }
                return ready
            }
        ))
        await waitForRecovery(timeout: .seconds(6)) { model.connectionState == .connected }
        XCTAssertEqual(dials, 3)
        XCTAssertNil(model.connectionIssue)
        model.disconnect()
    }

    @MainActor
    func testFailedEventPollRecoversEvenWhenTheFirstReconnectDialFails() async throws {
        let store = RecoveryStore(record: .paired(recoveryCredential(for: recoveryAttempt())))
        let initial = RecoveryTransport()
        let recovered = RecoveryTransport()
        var dials = 0
        let model = recoveryModel(store: store, factory: .init(
            prepare: { _, _, _, _ in throw RecoveryFault.unexpectedPrepare },
            open: { _, _, _ in
                dials += 1
                if dials == 1 { return initial }
                if dials == 2 { throw RecoveryFault.disconnected }
                return recovered
            }
        ))
        await waitForRecovery { model.connectionState == .connected && initial.hasEventSubscriber }
        defer {
            model.disconnect()
            XCTAssertEqual(model.connectionStatusLabel, "Offline")
        }
        let firstSync = try XCTUnwrap(model.lastSyncAt)
        XCTAssertEqual(model.connectionStatusLabel, "Connected")
        initial.interruptEvents()
        await waitForRecovery { model.connectionState == .disconnected }
        XCTAssertNotNil(model.snapshot)
        XCTAssertEqual(model.lastSyncAt, firstSync)
        XCTAssertEqual(model.connectionStatusLabel, "Reconnecting…")
        await waitForRecovery(timeout: .seconds(5)) { model.connectionState == .connected }
        XCTAssertEqual(dials, 3)
        XCTAssertGreaterThan(try XCTUnwrap(model.lastSyncAt), firstSync)
    }

    @MainActor
    func testBackgroundingRejectsLateFirstSnapshot() async {
        let store = RecoveryStore(record: .paired(recoveryCredential(for: recoveryAttempt())))
        let late = RecoveryTransport()
        var firstSync: CheckedContinuation<Void, Never>?
        late.beforeSnapshot = { await withCheckedContinuation { firstSync = $0 } }
        let model = recoveryModel(store: store, factory: .init(
            prepare: { _, _, _, _ in throw RecoveryFault.unexpectedPrepare },
            open: { _, _, _ in late }
        ))
        await waitForRecovery { firstSync != nil }
        model.setSceneActive(false)
        firstSync?.resume()
        await waitForRecovery { late.wasClosed }
        XCTAssertEqual(model.connectionState, .disconnected)
        XCTAssertNil(model.snapshot)
        XCTAssertNil(model.lastSyncAt)
    }

    @MainActor
    private func waitForRecovery(
        timeout: Duration = .seconds(1), until condition: () -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition(), .now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }

    @MainActor
    private func recoveryModel(store: RecoveryStore, factory: RemoteAppModel.ConnectionFactory) -> RemoteAppModel {
        RemoteAppModel(
            credentialStore: store,
            irohIdentityStore: .init(
                read: { Data(repeating: 1, count: 32) }, write: { _ in },
                generate: { Data(repeating: 1, count: 32) }
            ),
            connectionFactory: factory,
            monitorNetwork: false
        )
    }

    private func recoveryAttempt() -> StoredRemotePairingAttempt {
        .init(
            id: UUID(), advertisement: makeIrohCode(expiresAt: Date().addingTimeInterval(300)),
            localEndpointID: endpointID("b")
        )
    }

    private func recoveryCredential(for attempt: StoredRemotePairingAttempt) -> StoredRemoteCredential {
        let server = attempt.advertisement.server
        return .init(
            desktopInstanceID: "desktop", deviceID: "phone", credential: "test-bearer",
            irohBinding: .init(
                expectedDesktopEndpointID: server.endpointID,
                localMobileEndpointID: attempt.localEndpointID, serverAddress: server
            )
        )
    }

    func testMobileIdentityStoreLoadsCreatesAndReplacesCorruptValues() throws {
        let stable = Data(repeating: 1, count: 32)
        var writes: [Data] = []
        let loaded = try RemoteIrohIdentityStore(
            read: { stable },
            write: { writes.append($0) },
            generate: { XCTFail("Should not generate"); return Data() }
        ).loadOrCreate()
        XCTAssertEqual(loaded, RemoteIrohIdentity(secret: stable, origin: .loaded))
        XCTAssertTrue(writes.isEmpty)

        let createdSecret = Data(repeating: 2, count: 32)
        let created = try RemoteIrohIdentityStore(
            read: { nil },
            write: { writes.append($0) },
            generate: { createdSecret }
        ).loadOrCreate()
        XCTAssertEqual(created, RemoteIrohIdentity(secret: createdSecret, origin: .created))
        XCTAssertEqual(writes.last, createdSecret)

        let replacement = Data(repeating: 3, count: 32)
        let replaced = try RemoteIrohIdentityStore(
            read: { Data(repeating: 9, count: 64) },
            write: { writes.append($0) },
            generate: { replacement }
        ).loadOrCreate()
        XCTAssertEqual(replaced, RemoteIrohIdentity(secret: replacement, origin: .replacedCorruptValue))
        XCTAssertEqual(writes.last, replacement)
    }

    func testIdentityStoreRejectsIncorrectGeneratedLengthWithoutPersisting() {
        var didWrite = false
        let store = RemoteIrohIdentityStore(
            read: { nil },
            write: { _ in didWrite = true },
            generate: { Data(repeating: 1, count: 31) }
        )
        XCTAssertThrowsError(try store.loadOrCreate()) { error in
            XCTAssertEqual(
                error as? RemoteIrohIdentityStoreError,
                .invalidGeneratedIdentityLength(31)
            )
        }
        XCTAssertFalse(didWrite)
    }

    func testIdentityStoreDeletionUsesDedicatedKeychainAction() throws {
        var didDelete = false
        let store = RemoteIrohIdentityStore(
            read: { nil },
            write: { _ in },
            delete: { didDelete = true },
            generate: { Data(repeating: 1, count: 32) }
        )

        try store.delete()
        XCTAssertTrue(didDelete)
    }

    @MainActor
    func testOneTapUnpairConnectedSuccessRevokesAndCloses() async {
        var didCleanUpLocally = false
        var didSend = false
        var closeCount = 0
        var outcome: RemoteUnpairRemoteOutcome?
        let work = RemoteUnpairCoordinator.startBestEffort(
            attempts: [RemoteUnpairAttempt(
                transportDescription: "active Iroh",
                run: { didSend = true },
                cancel: { closeCount += 1 }
            )],
            timeout: .seconds(1),
            localCleanup: { didCleanUpLocally = true },
            onCompletion: { outcome = $0 }
        )

        XCTAssertTrue(didCleanUpLocally)
        await work.task.value
        XCTAssertTrue(didSend)
        XCTAssertEqual(closeCount, 1)
        XCTAssertEqual(outcome, .revoked)
    }

    @MainActor
    func testOneTapUnpairWithoutGatewayStillCleansUpImmediately() async {
        var cleanupCount = 0
        var outcome: RemoteUnpairRemoteOutcome?
        let work = RemoteUnpairCoordinator.startBestEffort(
            attempts: [],
            timeout: .milliseconds(20),
            localCleanup: { cleanupCount += 1 },
            onCompletion: { outcome = $0 }
        )

        XCTAssertEqual(cleanupCount, 1)
        await work.task.value
        XCTAssertEqual(outcome, .noTransport)
    }

    @MainActor
    func testOneTapUnpairHungIrohTimesOutAndCloses() async {
        var continuation: CheckedContinuation<Void, Error>?
        var didClose = false
        var outcomes: [RemoteUnpairRemoteOutcome] = []
        let work = RemoteUnpairCoordinator.startBestEffort(
            attempts: [RemoteUnpairAttempt(
                transportDescription: "hung Iroh",
                run: {
                    try await withCheckedThrowingContinuation { continuation = $0 }
                },
                cancel: {
                    didClose = true
                    continuation?.resume(throwing: CancellationError())
                    continuation = nil
                }
            )],
            timeout: .milliseconds(20),
            localCleanup: {},
            onCompletion: { outcomes.append($0) }
        )

        await work.task.value
        XCTAssertTrue(didClose)
        XCTAssertEqual(outcomes, [.timedOut])
    }

    @MainActor
    func testOneTapUnpairUnreachableIrohIsDiagnosticOnly() async {
        enum Unreachable: Error { case offline }
        var didCleanUpLocally = false
        var didClose = false
        var failureDescriptions: [String] = []
        var outcome: RemoteUnpairRemoteOutcome?
        let work = RemoteUnpairCoordinator.startBestEffort(
            attempts: [RemoteUnpairAttempt(
                transportDescription: "Iroh reconnect",
                run: { throw Unreachable.offline },
                cancel: { didClose = true }
            )],
            timeout: .seconds(1),
            localCleanup: { didCleanUpLocally = true },
            onAttemptFailure: { description, _ in failureDescriptions.append(description) },
            onCompletion: { outcome = $0 }
        )

        XCTAssertTrue(didCleanUpLocally)
        await work.task.value
        XCTAssertTrue(didClose)
        XCTAssertEqual(failureDescriptions, ["Iroh reconnect"])
        XCTAssertEqual(outcome, .failed)
    }

    @MainActor
    func testOneTapUnpairCancellationIgnoresLateCompletion() async {
        var continuation: CheckedContinuation<Void, Error>?
        var outcomes: [RemoteUnpairRemoteOutcome] = []
        let work = RemoteUnpairCoordinator.startBestEffort(
            attempts: [RemoteUnpairAttempt(
                transportDescription: "active Iroh",
                run: {
                    try await withCheckedThrowingContinuation { continuation = $0 }
                },
                cancel: {
                    continuation?.resume()
                    continuation = nil
                }
            )],
            timeout: .seconds(1),
            localCleanup: {},
            onCompletion: { outcomes.append($0) }
        )

        while continuation == nil { await Task.yield() }
        work.cancel()
        await work.task.value
        XCTAssertEqual(outcomes, [.cancelled])
    }

    @MainActor
    func testOneTapUnpairLocalCleanupPrecedesAnyRemoteAwait() async {
        var order: [String] = []
        let work = RemoteUnpairCoordinator.startBestEffort(
            attempts: [RemoteUnpairAttempt(
                transportDescription: "active Iroh",
                run: { order.append("remote") }
            )],
            timeout: .seconds(1),
            localCleanup: { order.append("local") }
        )

        XCTAssertEqual(order, ["local"])
        await work.task.value
        XCTAssertEqual(order, ["local", "remote"])
    }

    private func makeIrohCode(expiresAt: Date) -> RemoteIrohPairingAdvertisement {
        RemoteIrohPairingAdvertisement(
            desktopInstanceID: "desktop",
            server: RemoteIrohEndpointAddress(
                endpointID: endpointID("a"),
                directAddresses: ["192.0.2.1:4433"],
                relayURL: "https://relay.example",
                transportAddressJSON: "{}"
            ),
            oneTimeSecret: "one-time-secret",
            expiresAt: expiresAt
        )
    }

    private func endpointID(_ character: Character) -> String {
        String(repeating: String(character), count: 64)
    }

    private func pairingLink(for data: Data) -> String {
        let payload = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "rpremote://pair?payload=\(payload)"
    }
}


private enum RecoveryFault: Error {
    case disconnected
    case unexpectedPrepare
}

private final class RecoveryStore: RemoteCredentialStoring {
    private(set) var record: StoredRemotePairing?
    var failNextSave = false

    init(record: StoredRemotePairing?) {
        self.record = record
    }

    convenience init(restarting previous: RecoveryStore) throws {
        let record = try previous.record.map { try StoredRemotePairing.decode($0.encodedForKeychain()) }
        self.init(record: record)
    }

    func load() throws -> StoredRemotePairing? { record }

    func save(_ pairing: StoredRemotePairing) throws {
        if failNextSave {
            failNextSave = false
            throw RemoteCredentialStoreError.invalidKeychainData
        }
        record = pairing
    }

    func delete() throws { record = nil }
}

private final class RecoveryTransport: RemoteConnectionCandidate {
    private(set) var confirmations: [UUID] = []
    var onConfirm: ((UUID) throws -> Void)?
    var syncFailure: Error?
    var beforeSnapshot: (() async -> Void)?
    private(set) var wasClosed = false
    var hasEventSubscriber: Bool { eventsContinuation != nil }
    private var eventsContinuation: AsyncThrowingStream<RemoteEvent, Error>.Continuation?

    func confirmPairing(attemptID: UUID) async throws {
        confirmations.append(attemptID)
        try onConfirm?(attemptID)
    }

    func authenticate() async throws {}

    func firstSnapshot() async throws -> RemoteSnapshot {
        await beforeSnapshot?()
        if let syncFailure { throw syncFailure }
        return try await snapshot()
    }

    func snapshot() async throws -> RemoteSnapshot {
        .init(
            desktop: .init(instanceID: "desktop", displayName: "Mac", appVersion: "test", isAvailable: true),
            connection: .init(state: .connected), authorization: .init(), eventCursor: 0
        )
    }

    func events(after cursor: UInt64) -> AsyncThrowingStream<RemoteEvent, Error> {
        AsyncThrowingStream { eventsContinuation = $0 }
    }

    func interruptEvents() { eventsContinuation?.finish(throwing: RecoveryFault.disconnected) }

    func close() {
        wasClosed = true
        eventsContinuation?.finish()
    }
    func unpair() async throws { throw RecoveryFault.disconnected }
    func diagnostics() async throws -> RemoteDiagnostics { .init(gatewayState: "running", pairedDevice: true) }
    func workspaces() async throws -> [RemoteWorkspaceSummary] { [] }
    func sessions() async throws -> [RemoteSessionSummary] { [] }
    func agents() async throws -> [RemoteAgentDescriptor] { [] }
    func workflows() async throws -> [RemoteWorkflowDescriptor] { [] }
    func contextBuilder(_ request: RemoteCommandRequest) async throws -> RemoteCommandResponse { try await command(request) }
    func command(_ request: RemoteCommandRequest) async throws -> RemoteCommandResponse { throw RecoveryFault.disconnected }
    func history(_ request: RemoteHistoryRPCRequest) async throws -> RemoteHistoryPage { throw RecoveryFault.disconnected }
    func imageAttachment(_ request: RemoteImageAttachmentRequest) async throws -> RemoteImageAttachmentChunk {
        throw RecoveryFault.disconnected
    }

    func transcript(
        sessionID: UUID, afterSequenceIndex: Int?, itemID: UUID?, limit: Int, includeDetails: Bool
    ) async throws -> RemoteTranscriptPage {
        throw RecoveryFault.disconnected
    }

    func recentTranscript(
        sessionID: UUID, before cursor: RemoteTranscriptCursor?, limit: Int
    ) async throws -> RemoteTranscriptPage {
        throw RecoveryFault.disconnected
    }
}
