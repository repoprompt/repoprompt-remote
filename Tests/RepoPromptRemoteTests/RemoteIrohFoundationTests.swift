import RepoPromptRemoteNetworking
import Foundation
import RepoPromptIrohTransport
@testable import RepoPromptRemote
import RepoPromptRemoteProtocol
import XCTest

final class RemoteIrohFoundationTests: XCTestCase {
    @MainActor
    func testAppRejectsAnInvalidPairingCode() {
        let model = RemoteAppModel(credentialStore: RecoveryStore(record: nil), monitorNetwork: false, reconnectHistoryDefaults: nil)
        model.beginPairing()
        model.handleQRCode("invalid-pairing-link")
        XCTAssertEqual(model.transientError, RemotePairingError.invalidQRCode.errorDescription)
    }

    func testAuthenticationRecognizesLegacyRevocationWithoutAcceptingUncorrelatedSuccess() throws {
        let requestID = UUID()
        let rejection = RemoteErrorResponse(code: "unauthorized", message: "The credential was revoked.")
        let legacyFrame = try RemoteWireFrame(kind: .streamError, encoding: rejection)
        XCTAssertThrowsError(try RemoteIrohGatewayTransport.validateAuthenticationResponse(legacyFrame, requestID: requestID)) { error in
            guard case RemoteGatewayError.credentialRejected = error else {
                return XCTFail("Expected a definitive credential rejection, got \(error)")
            }
        }

        let wrongRequest = try RemoteWireFrame(kind: .streamError, messageID: UUID(), encoding: rejection)
        let uncorrelatedSuccess = RemoteWireFrame(kind: .helloAccepted)
        for frame in [wrongRequest, uncorrelatedSuccess] {
            XCTAssertThrowsError(try RemoteIrohGatewayTransport.validateAuthenticationResponse(frame, requestID: requestID)) { error in
                XCTAssertEqual(error as? RemoteIrohTransportError, .unexpectedFrame)
            }
        }
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
    func testLegacyDesktopPairingSurvivesFirstSnapshotLossAndRestart() async throws {
        let attempt = recoveryAttempt(supportsConfirmation: nil)
        let credential = recoveryCredential(for: attempt)
        let store = RecoveryStore(record: .preparing(attempt))
        let failedSync = RecoveryTransport()
        failedSync.syncFailure = RecoveryFault.disconnected
        let first = recoveryModel(store: store, factory: .init(
            prepare: { _, _, _, _, willSendLegacyHello in
                try willSendLegacyHello()
                guard case let .preparing(dispatched) = store.record else {
                    throw RecoveryFault.unexpectedPrepare
                }
                XCTAssertEqual(dispatched.legacyHelloMayHaveBeenSent, true)
                return (credential, failedSync)
            },
            open: { _, _, _, _ in throw RecoveryFault.disconnected }
        ))
        await waitForRecovery { first.connectionIssue != nil && first.isPaired }
        XCTAssertEqual(store.record, .paired(credential))
        XCTAssertEqual(failedSync.confirmations, [])
        first.disconnect()

        let restartedStore = try RecoveryStore(restarting: store)
        let recovered = RecoveryTransport()
        let restarted = recoveryModel(store: restartedStore, factory: .init(
            prepare: { _, _, _, _, _ in throw RecoveryFault.unexpectedPrepare },
            open: { stored, _, _, _ in
                XCTAssertEqual(stored, credential)
                return recovered
            }
        ))
        await waitForRecovery { restarted.connectionState == .connected }
        XCTAssertEqual(recovered.confirmations, [])
        XCTAssertEqual(restartedStore.record, .paired(credential))
        restarted.disconnect()
    }

    @MainActor
    func testLegacyReceiptSurvivesNetworkChangeBeforeFirstSync() async {
        let attempt = recoveryAttempt(supportsConfirmation: nil)
        let credential = recoveryCredential(for: attempt)
        let store = RecoveryStore(record: .preparing(attempt))
        let oldPath = RecoveryTransport()
        let newPath = RecoveryTransport()
        var deliverReceipt: CheckedContinuation<Void, Never>?
        let model = recoveryModel(store: store, factory: .init(
            prepare: { _, _, _, _, willSendLegacyHello in
                try willSendLegacyHello()
                await withCheckedContinuation { deliverReceipt = $0 }
                return (credential, oldPath)
            },
            open: { stored, _, _, _ in
                XCTAssertEqual(stored, credential)
                return newPath
            }
        ))
        model.observeNetworkPath(.satisfied, interface: "wifi")
        await waitForRecovery { deliverReceipt != nil }
        XCTAssertFalse(model.canCancelPendingPairing)
        model.observeNetworkPath(.unsatisfied, interface: "unknown")
        await waitForRecovery { model.networkStatus == "Offline" }
        deliverReceipt?.resume()
        await waitForRecovery { oldPath.wasClosed }
        XCTAssertEqual(store.record, .paired(credential))
        XCTAssertNil(model.snapshot)

        model.observeNetworkPath(.satisfied, interface: "cellular")
        await waitForRecovery(timeout: .seconds(4)) { model.connectionState == .connected }
        XCTAssertEqual(newPath.confirmations, [])
        XCTAssertEqual(store.record, .paired(credential))
        model.disconnect()
    }

    @MainActor
    func testInterruptedLegacyHelloShowsRecoveryWithoutResendingTheCode() async throws {
        var attempt = recoveryAttempt(supportsConfirmation: nil)
        attempt.legacyHelloMayHaveBeenSent = true
        let saved = try RecoveryStore(restarting: RecoveryStore(record: .preparing(attempt)))
        let model = recoveryModel(store: saved, factory: .init(
            prepare: { _, _, _, _, _ in
                XCTFail("A legacy QR may have been consumed before the phone restarted")
                throw RecoveryFault.unexpectedPrepare
            },
            open: { _, _, _, _ in throw RecoveryFault.disconnected }
        ))
        await waitForRecovery { model.connectionIssue != nil }
        XCTAssertNil(saved.record)
        XCTAssertEqual(model.connectionState, .unpaired)
        XCTAssertTrue(model.connectionIssue?.contains("may have accepted the code") == true)
        model.disconnect()
    }

    @MainActor
    func testFailedKeychainSaveNeverConfirmsAndRestartResumesTheSameAttempt() async throws {
        let attempt = recoveryAttempt()
        let credential = recoveryCredential(for: attempt)
        let store = RecoveryStore(record: .preparing(attempt))
        store.failNextSave = true
        let transport = RecoveryTransport()
        let factory = RemoteAppModel.ConnectionFactory(
            prepare: { suppliedAttempt, _, _, _, _ in
                XCTAssertEqual(suppliedAttempt, attempt)
                return (credential, transport)
            },
            open: { _, _, _, _ in throw RecoveryFault.disconnected }
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
            prepare: { _, _, _, _, _ in throw RecoveryFault.unexpectedPrepare },
            open: { _, _, _, _ in lostAck }
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
            prepare: { _, _, _, _, _ in throw RecoveryFault.unexpectedPrepare },
            open: { _, _, _, _ in
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
            prepare: { _, _, _, _, _ in throw RecoveryFault.unexpectedPrepare },
            open: { _, _, _, diagnostics in
                diagnostics.enter(.endpointStartup)
                diagnostics.enter(.dial)
                diagnostics.savedRelayHint = true
                dials += 1
                if dials < 3 { throw TransportError.Failure("timed out connecting endpoint") }
                return ready
            }
        ))
        await waitForRecovery(timeout: .seconds(6)) { model.connectionState == .connected }
        XCTAssertEqual(dials, 3)
        XCTAssertNil(model.connectionIssue)
        let history = model.reconnectHistory
        XCTAssertEqual(history.map(\.outcome), [.failed, .failed, .connected])
        XCTAssertEqual(history.map(\.reason), [.dialTimeout, .dialTimeout, nil])
        XCTAssertEqual(history.map(\.attempt), [1, 2, 3])
        XCTAssertEqual(history.last?.stage, .firstSnapshot)
        XCTAssertEqual(history.last?.savedRelayHint, true)
        XCTAssertGreaterThan(history.last?.recoveryMilliseconds ?? 0, history.last?.elapsedMilliseconds ?? 0)
        XCTAssertEqual(history.last?.timings.map(\.stage), [.localIdentity, .endpointStartup, .dial, .authenticate, .firstSnapshot])
        model.disconnect()
    }

    func testReconnectReportContainsOnlyClassifiedTransportData() throws {
        let address = #"{"id":"private-endpoint","addrs":[{"Relay":"https://private-relay.example/"}]}"#
        XCTAssertEqual(RemoteReconnectDiagnostics.relayHint(in: address), true)
        XCTAssertEqual(RemoteReconnectDiagnostics.relayHint(in: #"{"id":"private-endpoint","addrs":[{"Ip":"192.0.2.1:1234"}]}"#), false)
        XCTAssertNil(RemoteReconnectDiagnostics.relayHint(in: "{}"))

        var attempt = RemoteReconnectDiagnostics.Attempt()
        attempt.savedRelayHint = RemoteReconnectDiagnostics.relayHint(in: address)
        attempt.enter(.dial)
        let reason = RemoteReconnectDiagnostics.Reason(
            error: TransportError.Failure("connect endpoint: private-error-detail"), stage: .dial
        )
        let entry = attempt.finish(
            network: .wifi, endingNetwork: .cellular, networkChanged: true,
            attempt: 1, recoveryStart: attempt.start, outcome: .failed, reason: reason, route: nil
        )
        let history = (0..<40).reduce(into: [RemoteReconnectDiagnostics.Entry]()) { result, _ in
            result = RemoteReconnectDiagnostics.append(entry, to: result)
        }
        XCTAssertEqual(history.count, 30)
        let persisted = try JSONDecoder().decode(
            [RemoteReconnectDiagnostics.Entry].self, from: JSONEncoder().encode(history)
        )
        let report = try XCTUnwrap(RemoteReconnectDiagnostics.report(persisted))
        XCTAssertTrue(report.contains("dial_failed"))
        XCTAssertTrue(report.contains("cellular"))
        XCTAssertFalse(report.contains("private-"))
        XCTAssertFalse(report.contains("192.0.2.1"))
    }

    @MainActor
    func testFlappingAndManualRetryKeepOneDialAndPreserveItsRetryDeadline() async throws {
        let credential = recoveryCredential(for: recoveryAttempt())
        let store = RecoveryStore(record: .paired(credential))
        let stale = RecoveryTransport()
        let ready = RecoveryTransport()
        var dialStarts: [ContinuousClock.Instant] = []
        var finishFirstDial: CheckedContinuation<Void, Never>?
        let model = recoveryModel(store: store, factory: .init(
            prepare: { _, _, _, _, _ in throw RecoveryFault.unexpectedPrepare },
            open: { stored, _, _, diagnostics in
                XCTAssertEqual(stored, credential)
                diagnostics.enter(.dial)
                dialStarts.append(.now)
                if dialStarts.count == 1 {
                    await withCheckedContinuation { finishFirstDial = $0 }
                    return stale
                }
                return ready
            }
        ))
        model.observeNetworkPath(.satisfied, interface: "wifi")
        await waitForRecovery { finishFirstDial != nil }

        model.observeNetworkPath(.unsatisfied, interface: "unknown")
        model.observeNetworkPath(.satisfied, interface: "cellular")
        model.observeNetworkPath(.satisfied, interface: "wifi")
        for _ in 0..<5 { model.retryConnection() }
        try await Task.sleep(for: .milliseconds(550))
        XCTAssertEqual(model.networkStatus, "Online (wifi)")
        XCTAssertEqual(dialStarts.count, 1)

        model.observeNetworkPath(.satisfied, interface: "cellular")
        model.observeNetworkPath(.satisfied, interface: "cellular")
        await waitForRecovery { model.networkStatus == "Online (cellular)" }
        XCTAssertEqual(dialStarts.count, 1)
        finishFirstDial?.resume()
        await waitForRecovery { stale.wasClosed }
        for _ in 0..<5 { model.retryConnection() }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(dialStarts.count, 1)
        XCTAssertNil(model.snapshot)

        await waitForRecovery(timeout: .seconds(4)) { model.connectionState == .connected }
        XCTAssertEqual(dialStarts.count, 2)
        let firstStart = try XCTUnwrap(dialStarts.first)
        let secondStart = try XCTUnwrap(dialStarts.dropFirst().first)
        XCTAssertGreaterThanOrEqual(firstStart.duration(to: secondStart), .seconds(2))
        XCTAssertEqual(model.reconnectHistory.map(\.outcome), [.cancelled, .connected])
        XCTAssertEqual(model.reconnectHistory.first?.reason, .networkChanged)
        XCTAssertEqual(model.reconnectHistory.last?.network, .cellular)
        XCTAssertEqual(store.record, .paired(credential))
        model.disconnect()
    }

    @MainActor
    func testUsableHandoffKeepsAuthenticatedFirstSnapshotInFlight() async {
        let credential = recoveryCredential(for: recoveryAttempt())
        let store = RecoveryStore(record: .paired(credential))
        let transport = RecoveryTransport()
        var releaseSnapshot: CheckedContinuation<Void, Never>?
        transport.beforeSnapshot = { await withCheckedContinuation { releaseSnapshot = $0 } }
        var dials = 0
        let model = recoveryModel(store: store, factory: .init(
            prepare: { _, _, _, _, _ in throw RecoveryFault.unexpectedPrepare },
            open: { _, _, _, _ in
                dials += 1
                return transport
            }
        ))
        model.observeNetworkPath(.satisfied, interface: "wifi")
        await waitForRecovery { releaseSnapshot != nil }
        model.observeNetworkPath(.satisfied, interface: "cellular")
        await waitForRecovery { model.networkStatus == "Online (cellular)" }
        XCTAssertEqual(dials, 1)
        XCTAssertFalse(transport.wasClosed)
        releaseSnapshot?.resume()
        await waitForRecovery { model.connectionState == .connected }
        XCTAssertEqual(model.reconnectHistory.last?.endingNetwork, .cellular)
        XCTAssertEqual(model.reconnectHistory.last?.networkChanged, true)
        XCTAssertEqual(store.record, .paired(credential))
        model.disconnect()
    }

    @MainActor
    func testSyncConfirmationTimeoutReportsItsOwnStageAndKeepsPhoneOffline() async {
        let credential = recoveryCredential(for: recoveryAttempt())
        let store = RecoveryStore(record: .paired(credential))
        let transport = RecoveryTransport()
        transport.syncConfirmationFailure = TransportError.Failure("frame I/O timed out")
        let model = recoveryModel(store: store, factory: .init(
            prepare: { _, _, _, _, _ in throw RecoveryFault.unexpectedPrepare },
            open: { _, _, _, _ in transport }
        ))

        await waitForRecovery { model.reconnectHistory.last?.outcome == .failed }
        XCTAssertTrue(model.isPaired)
        XCTAssertEqual(model.connectionState, .disconnected)
        XCTAssertNil(model.snapshot)
        XCTAssertEqual(model.reconnectHistory.last?.stage, .syncConfirmation)
        XCTAssertEqual(model.reconnectHistory.last?.reason, .frameTimeout)
        XCTAssertEqual(model.reconnectHistory.last?.snapshotBytes, 512)
        XCTAssertEqual(model.reconnectHistory.last?.timings.suffix(2).map(\.stage), [.firstSnapshot, .syncConfirmation])
        model.disconnect()
    }

    @MainActor
    func testFailedEventPollRecoversEvenWhenTheFirstReconnectDialFails() async throws {
        let store = RecoveryStore(record: .paired(recoveryCredential(for: recoveryAttempt())))
        let initial = RecoveryTransport()
        let recovered = RecoveryTransport()
        var dials = 0
        let model = recoveryModel(store: store, factory: .init(
            prepare: { _, _, _, _, _ in throw RecoveryFault.unexpectedPrepare },
            open: { _, _, _, _ in
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
            prepare: { _, _, _, _, _ in throw RecoveryFault.unexpectedPrepare },
            open: { _, _, _, _ in late }
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
            monitorNetwork: false, reconnectHistoryDefaults: nil
        )
    }

    private func recoveryAttempt(supportsConfirmation: Bool? = true) -> StoredRemotePairingAttempt {
        .init(
            id: UUID(), advertisement: makeIrohCode(
                expiresAt: Date().addingTimeInterval(300), supportsConfirmation: supportsConfirmation
            ),
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

    private func makeIrohCode(expiresAt: Date, supportsConfirmation: Bool? = nil) -> RemoteIrohPairingAdvertisement {
        RemoteIrohPairingAdvertisement(
            desktopInstanceID: "desktop",
            server: RemoteIrohEndpointAddress(
                endpointID: endpointID("a"),
                directAddresses: ["192.0.2.1:4433"],
                relayURL: "https://relay.example",
                transportAddressJSON: "{}"
            ),
            oneTimeSecret: "one-time-secret",
            expiresAt: expiresAt,
            requiresPairingConfirmation: supportsConfirmation
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
    var syncConfirmationFailure: Error?
    var beforeSnapshot: (() async -> Void)?
    private(set) var wasClosed = false
    var hasEventSubscriber: Bool { eventsContinuation != nil }
    private var eventsContinuation: AsyncThrowingStream<RemoteEvent, Error>.Continuation?

    func confirmPairing(attemptID: UUID) async throws {
        confirmations.append(attemptID)
        try onConfirm?(attemptID)
    }

    func authenticate() async throws {}

    func firstSnapshot(diagnostics: inout RemoteReconnectDiagnostics.Attempt) async throws -> RemoteSnapshot {
        await beforeSnapshot?()
        if let syncFailure { throw syncFailure }
        let first = try await snapshot()
        if let syncConfirmationFailure {
            diagnostics.snapshotBytes = 512
            diagnostics.enter(.syncConfirmation)
            throw syncConfirmationFailure
        }
        return first
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
