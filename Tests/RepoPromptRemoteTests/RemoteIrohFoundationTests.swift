import Foundation
@testable import RepoPromptRemote
import RepoPromptRemoteProtocol
import XCTest

final class RemoteIrohFoundationTests: XCTestCase {
    @MainActor
    func testAppRejectsAnInvalidPairingCode() {
        let model = RemoteAppModel()
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
        XCTAssertEqual(try JSONDecoder().decode(StoredRemoteCredential.self, from: data), stored)
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
