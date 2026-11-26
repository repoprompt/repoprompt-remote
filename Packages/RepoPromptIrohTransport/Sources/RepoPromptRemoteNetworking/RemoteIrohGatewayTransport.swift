import Foundation
import OSLog
import RepoPromptRemoteProtocol

/// Typed production client over authenticated Iroh QUIC streams. Each RPC is
/// one bounded bidirectional stream; ordered events use framed replay polling
/// from the reducer cursor so disconnects and stale cursors retain the same
/// authoritative recovery after a reconnect.
public final class RemoteIrohGatewayTransport: RemoteConnectionCandidate, @unchecked Sendable {
    private static let unpairLogger = Logger(subsystem: "com.repoprompt.remote", category: "Unpair")

    private let endpoint: RemoteNetworkEndpoint
    private let connection: RemoteNetworkConnection
    private let desktopInstanceID: String
    private let deviceID: String
    private let credential: String
    private let expectedServerEndpointID: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()
    private var isClosed = false
    private var sessionID: UUID?
    public private(set) var refreshedServerAddress: RemoteIrohEndpointAddress?

    public var irohPath: RemoteIrohPathKind? {
        connection.path
    }

    private init(
        endpoint: RemoteNetworkEndpoint,
        connection: RemoteNetworkConnection,
        desktopInstanceID: String,
        deviceID: String,
        credential: String,
        expectedServerEndpointID: String
    ) {
        self.endpoint = endpoint
        self.connection = connection
        self.desktopInstanceID = desktopInstanceID
        self.deviceID = deviceID
        self.credential = credential
        self.expectedServerEndpointID = expectedServerEndpointID
    }

    public static func endpointID(for identitySecret: Data) throws -> String {
        try RemoteNetwork.endpointID(for: identitySecret)
    }

    public static func connect(
        stored: StoredRemoteCredential,
        identitySecret: Data,
        generation: UInt64
    ) async throws -> RemoteIrohGatewayTransport {
        var diagnostics = RemoteReconnectDiagnostics.Attempt()
        let transport = try await open(
            stored: stored, identitySecret: identitySecret, generation: generation, diagnostics: &diagnostics
        )
        do {
            try await transport.authenticate()
            return transport
        } catch {
            transport.close()
            throw error
        }
    }

    public static func open(
        stored: StoredRemoteCredential,
        identitySecret: Data,
        generation: UInt64,
        diagnostics: inout RemoteReconnectDiagnostics.Attempt
    ) async throws -> RemoteIrohGatewayTransport {
        diagnostics.enter(.binding)
        let binding = stored.irohBinding
        diagnostics.savedRelayHint = RemoteReconnectDiagnostics.relayHint(in: binding.serverAddress.transportAddressJSON)
            ?? (binding.serverAddress.relayURL == nil ? nil : true)
        guard binding.wireVersion == RemoteWireProtocol.currentVersion,
              let addressJSON = binding.serverAddress.transportAddressJSON,
              binding.serverAddress.endpointID == binding.expectedDesktopEndpointID
        else {
            throw RemoteIrohTransportError.bindingUnavailable
        }
        guard try endpointID(for: identitySecret) == binding.localMobileEndpointID else {
            throw RemoteIrohTransportError.localIdentityChanged
        }
        diagnostics.enter(.endpointStartup)
        let endpoint = try await RemoteNetworkEndpoint.start(
            secret: identitySecret,
            relayEnabled: true,
            generation: generation
        )
        do {
            diagnostics.enter(.dial)
            let connection = try await endpoint.connect(addressJSON: addressJSON, expectedPeerID: binding.expectedDesktopEndpointID)
            diagnostics.localRelayHint = RemoteReconnectDiagnostics.relayHint(in: try? endpoint.currentAddress().transportAddressJSON)
            return RemoteIrohGatewayTransport(
                endpoint: endpoint,
                connection: connection,
                desktopInstanceID: stored.desktopInstanceID,
                deviceID: stored.deviceID,
                credential: stored.credential,
                expectedServerEndpointID: binding.expectedDesktopEndpointID
            )
        } catch {
            diagnostics.localRelayHint = RemoteReconnectDiagnostics.relayHint(in: try? endpoint.currentAddress().transportAddressJSON)
            try? await endpoint.shutdown()
            if case RemoteNetworkError.peerMismatch = error {
                throw RemoteIrohTransportError.serverEndpointMismatch
            }
            throw error
        }
    }

    public static func preparePairing(
        attempt: StoredRemotePairingAttempt,
        identitySecret: Data,
        generation: UInt64,
        deviceName: String,
        willSendLegacyHello: @MainActor () throws -> Void
    ) async throws -> (StoredRemoteCredential, RemoteIrohGatewayTransport) {
        let advertisement = attempt.advertisement
        let attemptID = advertisement.requiresPairingConfirmation == true ? attempt.id : nil
        guard let addressJSON = advertisement.server.transportAddressJSON else {
            throw RemoteIrohTransportError.bindingUnavailable
        }
        let endpoint = try await RemoteNetworkEndpoint.start(
            secret: identitySecret,
            relayEnabled: true,
            generation: generation
        )
        do {
            let localEndpointID = try endpoint.currentAddress().endpointID
            guard localEndpointID == attempt.localEndpointID else {
                throw RemoteIrohTransportError.localIdentityChanged
            }
            let connection = try await endpoint.connect(addressJSON: addressJSON, expectedPeerID: advertisement.server.endpointID)
            let request = RemoteIrohPairingRequest(
                desktopInstanceID: advertisement.desktopInstanceID,
                expectedServerEndpointID: advertisement.server.endpointID,
                clientEndpointID: localEndpointID,
                oneTimeSecret: advertisement.oneTimeSecret,
                deviceName: deviceName,
                attemptID: attemptID
            )
            let hello = try RemoteWireFrame(
                kind: attemptID == nil ? .pairingHello : .pairingPrepare,
                messageID: UUID(),
                encoding: RemotePairingHello(request: request)
            )
            try Task.checkCancellation()
            if attemptID == nil { try await willSendLegacyHello() }
            let responseFrame = try await connection.exchange(hello)
            guard responseFrame.messageID == hello.messageID else {
                throw RemoteIrohTransportError.unexpectedFrame
            }
            guard responseFrame.kind == .helloAccepted else {
                throw remoteError(from: responseFrame)
            }
            let response = try JSONDecoder().decode(
                RemoteIrohPairingResponse.self,
                from: responseFrame.payload
            )
            guard response.serverEndpointID == advertisement.server.endpointID,
                  response.clientEndpointID == localEndpointID
            else {
                throw RemoteIrohTransportError.serverEndpointMismatch
            }
            guard response.attemptID == attemptID,
                  response.pairingResponse.desktop.instanceID == advertisement.desktopInstanceID
            else { throw RemoteIrohTransportError.unexpectedFrame }

            let stored = StoredRemoteCredential(
                desktopInstanceID: advertisement.desktopInstanceID,
                deviceID: response.pairingResponse.deviceID,
                credential: response.pairingResponse.credential,
                irohBinding: .init(
                    expectedDesktopEndpointID: response.serverEndpointID,
                    localMobileEndpointID: response.clientEndpointID,
                    serverAddress: advertisement.server
                )
            )
            let transport = RemoteIrohGatewayTransport(
                endpoint: endpoint,
                connection: connection,
                desktopInstanceID: stored.desktopInstanceID,
                deviceID: stored.deviceID,
                credential: stored.credential,
                expectedServerEndpointID: stored.irohBinding.expectedDesktopEndpointID
            )
            return (stored, transport)
        } catch {
            try? await endpoint.shutdown()
            if case RemoteNetworkError.peerMismatch = error {
                throw RemoteIrohTransportError.serverEndpointMismatch
            }
            throw error
        }
    }

    public func confirmPairing(attemptID: UUID) async throws {
        let request = try RemoteWireFrame(
            kind: .pairingConfirm,
            messageID: UUID(),
            encoding: RemotePairingConfirmation(attemptID: attemptID, authentication: authentication)
        )
        let response = try await send(request)
        guard response.messageID == request.messageID else { throw RemoteIrohTransportError.unexpectedFrame }
        guard response.kind == .pairingConfirmed else { throw Self.remoteError(from: response) }
        guard try response.decodedPayload(as: UUID.self, expectedKind: .pairingConfirmed) == attemptID else {
            throw RemoteIrohTransportError.unexpectedFrame
        }
    }

    public func unpair() async throws {
        Self.unpairLogger.info("Sending framed Iroh Unpair RPC")
        let response: RemoteUnpairResponse = try await rpc(.unpair)
        Self.unpairLogger.info("Received framed Iroh Unpair response")
        guard RemoteProtocol.supports(response.protocolVersion), response.unpaired else {
            throw RemoteGatewayError.invalidResponse
        }
    }

    public func snapshot() async throws -> RemoteSnapshot {
        try await rpc(.snapshot)
    }

    public func firstSnapshot(diagnostics: inout RemoteReconnectDiagnostics.Attempt) async throws -> RemoteSnapshot {
        let response = try await rpcResponse(.snapshot)
        diagnostics.snapshotBytes = response.uncompressedSnapshotBytes ?? response.result?.count
        let snapshot = try decodeRPCResult(RemoteSnapshot.self, response: response)
        guard RemoteProtocol.supports(snapshot.protocolVersion) else {
            throw RemoteGatewayError.protocolMismatch(snapshot.protocolVersion)
        }
        guard snapshot.desktop.instanceID == desktopInstanceID else {
            throw RemoteIrohTransportError.serverEndpointMismatch
        }
        guard let sessionID else { return snapshot } // Existing pairings can connect to older Macs.
        diagnostics.enter(.syncConfirmation)
        guard let ticket = response.syncTicket else { throw RemoteIrohTransportError.unexpectedFrame }
        let request = try RemoteWireFrame(
            kind: .syncConfirm, messageID: UUID(), sessionID: sessionID, encoding: ticket
        )
        try Task.checkCancellation()
        let acknowledgement = try await send(request)
        guard acknowledgement.messageID == request.messageID else {
            throw RemoteIrohTransportError.unexpectedFrame
        }
        guard acknowledgement.kind == .syncConfirmed else { throw Self.remoteError(from: acknowledgement) }
        guard try acknowledgement.decodedPayload(as: UUID.self, expectedKind: .syncConfirmed) == ticket else {
            throw RemoteIrohTransportError.unexpectedFrame
        }
        return snapshot
    }

    public func diagnostics() async throws -> RemoteDiagnostics {
        try await rpc(.diagnostics)
    }

    public func workspaces() async throws -> [RemoteWorkspaceSummary] {
        try await rpc(.workspaces)
    }

    public func sessions() async throws -> [RemoteSessionSummary] {
        try await rpc(.sessions)
    }

    public func agents() async throws -> [RemoteAgentDescriptor] {
        try await rpc(.agents)
    }

    public func workflows() async throws -> [RemoteWorkflowDescriptor] {
        try await rpc(.workflows)
    }

    public func contextBuilder(_ request: RemoteCommandRequest) async throws -> RemoteCommandResponse {
        try await rpc(.contextBuilder, payload: encoder.encode(request))
    }

    public func command(_ request: RemoteCommandRequest) async throws -> RemoteCommandResponse {
        try await rpc(.command, payload: encoder.encode(request))
    }

    public func history(_ request: RemoteHistoryRPCRequest) async throws -> RemoteHistoryPage {
        try await rpc(.history, payload: encoder.encode(request))
    }

    public func imageAttachment(_ request: RemoteImageAttachmentRequest) async throws -> RemoteImageAttachmentChunk {
        try await rpc(.imageAttachment, payload: encoder.encode(request))
    }

    public func transcript(
        sessionID: UUID,
        afterSequenceIndex: Int?,
        itemID: UUID?,
        limit: Int,
        includeDetails: Bool
    ) async throws -> RemoteTranscriptPage {
        try await rpc(
            .transcript,
            payload: encoder.encode(RemoteTranscriptRPCRequest(
                sessionID: sessionID,
                afterSequenceIndex: afterSequenceIndex,
                itemID: itemID,
                pagingMode: .legacyForward,
                limit: limit,
                includeDetails: includeDetails
            ))
        )
    }

    public func recentTranscript(
        sessionID: UUID,
        before cursor: RemoteTranscriptCursor?,
        limit: Int
    ) async throws -> RemoteTranscriptPage {
        try await rpc(
            .transcript,
            payload: encoder.encode(RemoteTranscriptRPCRequest(
                sessionID: sessionID,
                before: cursor,
                pagingMode: .recentBackward,
                limit: limit
            ))
        )
    }

    public func events(after cursor: UInt64) -> AsyncThrowingStream<RemoteEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [weak self] in
                guard let self else { return continuation.finish() }
                var nextCursor = cursor
                do {
                    while !Task.isCancelled {
                        let subscription = RemoteEventSubscriptionRequest(
                            desktopInstanceID: desktopInstanceID,
                            after: nextCursor
                        )
                        let request = try RemoteWireFrame(
                            kind: .eventSubscribe,
                            messageID: UUID(),
                            sessionID: sessionID,
                            encoding: subscription
                        )
                        let response = try await send(request)
                        guard response.messageID == request.messageID else {
                            throw RemoteIrohTransportError.unexpectedFrame
                        }
                        switch response.kind {
                        case .event:
                            let events = try response.decodedPayload(
                                as: [RemoteEvent].self,
                                expectedKind: .event
                            )
                            for event in events {
                                try Task.checkCancellation()
                                continuation.yield(event)
                                nextCursor = max(nextCursor, event.sequence)
                            }
                        case .heartbeat:
                            try await Task.sleep(for: .milliseconds(500))
                        case .streamError:
                            throw Self.remoteError(from: response)
                        default:
                            throw RemoteIrohTransportError.unexpectedFrame
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func close() {
        lock.lock()
        let shouldClose = !isClosed
        isClosed = true
        lock.unlock()
        guard shouldClose else { return }
        connection.close()
        let endpoint = endpoint
        Task { try? await endpoint.shutdown() }
    }

    private var authentication: RemoteAuthenticatedHello {
        RemoteAuthenticatedHello(
            desktopInstanceID: desktopInstanceID,
            expectedServerEndpointID: expectedServerEndpointID,
            deviceID: deviceID,
            credential: credential,
            supportsSyncConfirmation: true
        )
    }

    public func authenticate() async throws {
        let requestID = UUID()
        let request = try RemoteWireFrame(
            kind: .authenticatedHello,
            messageID: requestID,
            encoding: authentication
        )
        let response = try await send(request)
        try Self.validateAuthenticationResponse(response, requestID: requestID)
        let accepted = try response.decodedPayload(
            as: RemoteHelloAccepted.self,
            expectedKind: .helloAccepted
        )
        guard RemoteProtocol.supports(accepted.protocolVersion),
              accepted.wireVersion == RemoteWireProtocol.currentVersion,
              accepted.desktopInstanceID == desktopInstanceID,
              accepted.serverEndpointID == expectedServerEndpointID,
              accepted.clientEndpointID == (try endpoint.currentAddress().endpointID),
              accepted.deviceID == deviceID
        else {
            throw RemoteIrohTransportError.serverEndpointMismatch
        }
        sessionID = accepted.sessionID
        if let address = accepted.serverAddress, address.endpointID == expectedServerEndpointID,
           let addressJSON = address.transportAddressJSON, !addressJSON.isEmpty, addressJSON.utf8.count <= 16 * 1_024
        {
            refreshedServerAddress = address
        }
    }

    public static func validateAuthenticationResponse(_ response: RemoteWireFrame, requestID: UUID) throws {
        if response.messageID == nil, response.kind == .streamError,
           case RemoteGatewayError.credentialRejected = remoteError(from: response)
        {
            // Older Macs omit the ID on rejected hello responses. The pinned
            // peer returned this response on the hello's dedicated stream.
            throw RemoteGatewayError.credentialRejected
        }
        guard response.messageID == requestID else { throw RemoteIrohTransportError.unexpectedFrame }
        guard response.kind == .helloAccepted else { throw remoteError(from: response) }
    }

    private func rpc<Response: Decodable>(
        _ operation: RemoteRPCOperation,
        payload: Data = Data()
    ) async throws -> Response {
        try decodeRPCResult(Response.self, response: await rpcResponse(operation, payload: payload))
    }

    private func rpcResponse(_ operation: RemoteRPCOperation, payload: Data = Data()) async throws -> RemoteRPCResponse {
        let messageID = UUID()
        let request = try RemoteWireFrame(
            kind: .rpcRequest,
            messageID: messageID,
            sessionID: sessionID,
            encoding: RemoteRPCRequest(
                operation: operation,
                payload: payload,
                acceptsCompressedSnapshot: operation == .snapshot ? true : nil
            )
        )
        let frame = try await connection.exchange(request, read: operation)
        guard frame.messageID == messageID else { throw RemoteIrohTransportError.unexpectedFrame }
        guard frame.kind == .rpcResponse else {
            throw Self.remoteError(from: frame)
        }
        let response = try frame.decodedPayload(
            as: RemoteRPCResponse.self,
            expectedKind: .rpcResponse
        )
        guard operation == .snapshot || response.uncompressedSnapshotBytes == nil else {
            throw RemoteGatewayError.invalidResponse
        }
        return response
    }

    private func decodeRPCResult<Response: Decodable>(
        _ type: Response.Type, response: RemoteRPCResponse
    ) throws -> Response {
        if let error = response.error { throw Self.remoteError(error) }
        do {
            guard let result = try response.decodedResult() else { throw RemoteGatewayError.invalidResponse }
            return try decoder.decode(Response.self, from: result)
        } catch {
            throw RemoteGatewayError.invalidResponse
        }
    }

    private func send(_ frame: RemoteWireFrame) async throws -> RemoteWireFrame {
        try await connection.exchange(frame)
    }

    private static func remoteError(from frame: RemoteWireFrame) -> Error {
        if frame.kind == .streamError,
           let error = try? frame.decodedPayload(
               as: RemoteErrorResponse.self,
               expectedKind: .streamError
           )
        {
            return remoteError(error)
        }
        return RemoteIrohTransportError.unexpectedFrame
    }

    private static func remoteError(_ error: RemoteErrorResponse) -> Error {
        switch error.code {
        case "snapshot_required": RemoteGatewayError.snapshotRequired
        case "unauthorized": RemoteGatewayError.credentialRejected
        case "endpoint_mismatch": RemoteIrohTransportError.serverEndpointMismatch
        case "unsupported_protocol_version": RemoteIrohTransportError.confirmationUnavailable
        default: RemoteGatewayError.requestRejected(error)
        }
    }
}

public enum RemoteIrohTransportError: LocalizedError, Equatable {
    case bindingUnavailable
    case localIdentityChanged
    case serverEndpointMismatch
    case unexpectedFrame
    case frameTooLarge
    case confirmationUnavailable
    case legacyPairingOutcomeUnknown

    public var errorDescription: String? {
        switch self {
        case .bindingUnavailable: "The paired Mac has no usable Iroh endpoint binding."
        case .localIdentityChanged: "The phone’s pairing identity changed. Pair with the Mac again."
        case .serverEndpointMismatch: "The authenticated Iroh endpoint did not match the paired Mac."
        case .unexpectedFrame: "The Mac returned an unexpected Iroh frame."
        case .frameTooLarge: "The Mac returned an oversized Iroh frame."
        case .confirmationUnavailable:
            "The Mac rejected this version of the Remote protocol."
        case .legacyPairingOutcomeUnknown:
            "The Mac may have accepted the code before the connection dropped."
        }
    }
}
