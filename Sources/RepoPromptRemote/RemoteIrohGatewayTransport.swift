import Foundation
import OSLog
import RepoPromptIrohTransport
import RepoPromptRemoteProtocol

/// Typed production client over authenticated Iroh QUIC streams. Each RPC is
/// one bounded bidirectional stream; ordered events use framed replay polling
/// from the reducer cursor so disconnects and stale cursors retain the same
/// authoritative recovery after a reconnect.
final class RemoteIrohGatewayTransport: RemoteGatewayTransport, @unchecked Sendable {
    private static let unpairLogger = Logger(subsystem: "com.repoprompt.remote", category: "Unpair")

    private let endpoint: TransportEndpoint
    private let connection: TransportConnection
    private let desktopInstanceID: String
    private let deviceID: String
    private let credential: String
    private let expectedServerEndpointID: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let lock = NSLock()
    private var isClosed = false

    var irohPath: RemoteIrohPathKind? {
        Self.pathKind(from: connection.pathSummary())
    }

    private init(
        endpoint: TransportEndpoint,
        connection: TransportConnection,
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

    static func endpointID(for identitySecret: Data) throws -> String {
        try endpointIdForSecret(secretKey: identitySecret)
    }

    static func connect(
        stored: StoredRemoteCredential,
        identitySecret: Data,
        generation: UInt64
    ) async throws -> RemoteIrohGatewayTransport {
        let binding = stored.irohBinding
        guard binding.wireVersion == RemoteWireProtocol.currentVersion,
              let addressJSON = binding.serverAddress.transportAddressJSON,
              binding.serverAddress.endpointID == binding.expectedDesktopEndpointID
        else {
            throw RemoteIrohTransportError.bindingUnavailable
        }
        guard try endpointID(for: identitySecret) == binding.localMobileEndpointID else {
            throw RemoteIrohTransportError.localIdentityChanged
        }
        let endpoint = try await RepoPromptIrohSpike.startApplication(
            secret: identitySecret,
            relayEnabled: true,
            generation: generation
        )
        do {
            let connection = try await connectStaged(
                endpoint: endpoint,
                addressJSON: addressJSON
            )
            guard connection.peerEndpointId() == binding.expectedDesktopEndpointID else {
                connection.close()
                throw RemoteIrohTransportError.serverEndpointMismatch
            }
            let transport = RemoteIrohGatewayTransport(
                endpoint: endpoint,
                connection: connection,
                desktopInstanceID: stored.desktopInstanceID,
                deviceID: stored.deviceID,
                credential: stored.credential,
                expectedServerEndpointID: binding.expectedDesktopEndpointID
            )
            try await transport.authenticate()
            return transport
        } catch {
            try? await endpoint.shutdown()
            throw error
        }
    }

    static func pair(
        advertisement: RemoteIrohPairingAdvertisement,
        identitySecret: Data,
        generation: UInt64,
        deviceName: String,
        attemptID: UUID,
        diagnostics: inout RemotePairingTelemetry.Attempt
    ) async throws -> (RemoteIrohPairingResponse, RemoteIrohGatewayTransport) {
        diagnostics.stage = .startEndpoint
        guard let addressJSON = advertisement.server.transportAddressJSON else {
            throw RemoteIrohTransportError.bindingUnavailable
        }
        let endpoint = try await RepoPromptIrohSpike.startApplication(
            secret: identitySecret,
            relayEnabled: true,
            generation: generation
        )
        do {
            let localEndpointID = try endpoint.snapshot().endpointId
            let connection = try await connectStaged(
                endpoint: endpoint,
                addressJSON: addressJSON,
                onDial: { diagnostics.stage = $0 }
            )
            diagnostics.path = pathKind(from: connection.pathSummary())
            diagnostics.stage = .verifyPeer
            guard connection.peerEndpointId() == advertisement.server.endpointID else {
                connection.close()
                throw RemoteIrohTransportError.serverEndpointMismatch
            }
            let request = RemoteIrohPairingRequest(
                desktopInstanceID: advertisement.desktopInstanceID,
                expectedServerEndpointID: advertisement.server.endpointID,
                clientEndpointID: localEndpointID,
                oneTimeSecret: advertisement.oneTimeSecret,
                deviceName: deviceName
            )
            let hello = try RemoteWireFrame(
                kind: .pairingHello,
                messageID: attemptID,
                encoding: RemotePairingHello(request: request)
            )
            // From this point onward the one-time secret may have been consumed
            // even if the response is lost. Request a fresh code after an ambiguous outcome.
            diagnostics.stage = .pairingHello
            diagnostics.helloSent = true
            let responseFrame = try await send(
                hello,
                over: connection,
                encoder: JSONEncoder(),
                decoder: JSONDecoder()
            )
            guard responseFrame.kind == .helloAccepted,
                  responseFrame.messageID == hello.messageID
            else {
                throw remoteError(from: responseFrame)
            }
            diagnostics.stage = .decodeResponse
            let response = try JSONDecoder().decode(
                RemoteIrohPairingResponse.self,
                from: responseFrame.payload
            )
            guard response.serverEndpointID == advertisement.server.endpointID,
                  response.clientEndpointID == localEndpointID
            else {
                throw RemoteIrohTransportError.serverEndpointMismatch
            }
            let transport = RemoteIrohGatewayTransport(
                endpoint: endpoint,
                connection: connection,
                desktopInstanceID: advertisement.desktopInstanceID,
                deviceID: response.pairingResponse.deviceID,
                credential: response.pairingResponse.credential,
                expectedServerEndpointID: advertisement.server.endpointID
            )
            diagnostics.stage = .authenticate
            try await transport.authenticate()
            return (response, transport)
        } catch {
            try? await endpoint.shutdown()
            if diagnostics.helloSent {
                diagnostics.underlyingFailure = RemotePairingTelemetry.failureReason(error)
                throw RemoteIrohTransportError.pairingOutcomeUnknown
            }
            throw error
        }
    }

    func unpair() async throws {
        Self.unpairLogger.info("Sending framed Iroh Unpair RPC")
        let response: RemoteUnpairResponse = try await rpc(.unpair)
        Self.unpairLogger.info("Received framed Iroh Unpair response")
        guard RemoteProtocol.supports(response.protocolVersion), response.unpaired else {
            throw RemoteGatewayError.invalidResponse
        }
    }

    func snapshot() async throws -> RemoteSnapshot {
        try await rpc(.snapshot)
    }

    func diagnostics() async throws -> RemoteDiagnostics {
        try await rpc(.diagnostics)
    }

    func workspaces() async throws -> [RemoteWorkspaceSummary] {
        try await rpc(.workspaces)
    }

    func sessions() async throws -> [RemoteSessionSummary] {
        try await rpc(.sessions)
    }

    func agents() async throws -> [RemoteAgentDescriptor] {
        try await rpc(.agents)
    }

    func workflows() async throws -> [RemoteWorkflowDescriptor] {
        try await rpc(.workflows)
    }

    func contextBuilder(_ request: RemoteCommandRequest) async throws -> RemoteCommandResponse {
        try await rpc(.contextBuilder, payload: encoder.encode(request))
    }

    func command(_ request: RemoteCommandRequest) async throws -> RemoteCommandResponse {
        try await rpc(.command, payload: encoder.encode(request))
    }

    func history(_ request: RemoteHistoryRPCRequest) async throws -> RemoteHistoryPage {
        try await rpc(.history, payload: encoder.encode(request))
    }

    func imageAttachment(_ request: RemoteImageAttachmentRequest) async throws -> RemoteImageAttachmentChunk {
        try await rpc(.imageAttachment, payload: encoder.encode(request))
    }

    func transcript(
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

    func recentTranscript(
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

    func events(after cursor: UInt64) -> AsyncThrowingStream<RemoteEvent, Error> {
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

    func close() {
        lock.lock()
        let shouldClose = !isClosed
        isClosed = true
        lock.unlock()
        guard shouldClose else { return }
        connection.close()
        let endpoint = endpoint
        Task { try? await endpoint.shutdown() }
    }

    private func authenticate() async throws {
        let hello = RemoteAuthenticatedHello(
            desktopInstanceID: desktopInstanceID,
            expectedServerEndpointID: expectedServerEndpointID,
            deviceID: deviceID,
            credential: credential
        )
        let request = try RemoteWireFrame(
            kind: .authenticatedHello,
            messageID: UUID(),
            encoding: hello
        )
        let response = try await send(request)
        guard response.kind == .helloAccepted,
              response.messageID == request.messageID
        else {
            throw Self.remoteError(from: response)
        }
        let accepted = try response.decodedPayload(
            as: RemoteHelloAccepted.self,
            expectedKind: .helloAccepted
        )
        guard accepted.desktopInstanceID == desktopInstanceID,
              accepted.serverEndpointID == expectedServerEndpointID,
              accepted.clientEndpointID == (try endpoint.snapshot().endpointId),
              accepted.deviceID == deviceID
        else {
            throw RemoteIrohTransportError.serverEndpointMismatch
        }
    }

    private func rpc<Response: Decodable>(
        _ operation: RemoteRPCOperation,
        payload: Data = Data()
    ) async throws -> Response {
        let messageID = UUID()
        let request = try RemoteWireFrame(
            kind: .rpcRequest,
            messageID: messageID,
            encoding: RemoteRPCRequest(operation: operation, payload: payload)
        )
        let frame = try await send(request)
        guard frame.kind == .rpcResponse, frame.messageID == messageID else {
            throw Self.remoteError(from: frame)
        }
        let response = try frame.decodedPayload(
            as: RemoteRPCResponse.self,
            expectedKind: .rpcResponse
        )
        if let error = response.error {
            if error.code == "snapshot_required" { throw RemoteGatewayError.snapshotRequired }
            if error.code == "unauthorized" { throw RemoteGatewayError.credentialRejected }
            throw RemoteGatewayError.requestRejected(error)
        }
        guard let result = response.result else { throw RemoteGatewayError.invalidResponse }
        do { return try decoder.decode(Response.self, from: result) }
        catch { throw RemoteGatewayError.invalidResponse }
    }

    private func send(_ frame: RemoteWireFrame) async throws -> RemoteWireFrame {
        try await Self.send(frame, over: connection, encoder: encoder, decoder: decoder)
    }

    private static func connectStaged(
        endpoint: TransportEndpoint,
        addressJSON: String,
        onDial: (RemotePairingTelemetry.Stage) -> Void = { _ in }
    ) async throws -> TransportConnection {
        var lastError: Error = RemoteIrohTransportError.bindingUnavailable
        let policies: [(stage: RemotePairingTelemetry.Stage, allowRelay: Bool, localOnly: Bool, timeout: UInt64)] = [
            (.dialLocal, false, true, 3_500),
            (.dialDirect, false, false, 8_000),
            (.dialRelay, true, false, 20_000)
        ]
        for policy in policies {
            onDial(policy.stage)
            do {
                return try await endpoint.connectWithPolicy(
                    addressJson: addressJSON,
                    alpn: RepoPromptIrohSpike.alpn,
                    allowRelay: policy.allowRelay,
                    localOnly: policy.localOnly,
                    timeoutMillis: policy.timeout
                )
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    private static func send(
        _ frame: RemoteWireFrame,
        over connection: TransportConnection,
        encoder: JSONEncoder,
        decoder: JSONDecoder
    ) async throws -> RemoteWireFrame {
        try frame.validateEncodedLimit(direction: .clientToServer)
        let encoded = try encoder.encode(frame)
        let responseData = try await connection.sendFrame(payload: encoded)
        guard responseData.count <= RemoteWireProtocol.maximumServerResponseFrameBytes else {
            throw RemoteIrohTransportError.frameTooLarge
        }
        return try decoder.decode(RemoteWireFrame.self, from: responseData)
    }

    private static func remoteError(from frame: RemoteWireFrame) -> Error {
        if frame.kind == .streamError,
           let error = try? frame.decodedPayload(
               as: RemoteErrorResponse.self,
               expectedKind: .streamError
           )
        {
            if error.code == "snapshot_required" { return RemoteGatewayError.snapshotRequired }
            if error.code == "unauthorized" { return RemoteGatewayError.credentialRejected }
            if error.code == "endpoint_mismatch" { return RemoteIrohTransportError.serverEndpointMismatch }
            return RemoteGatewayError.requestRejected(error)
        }
        return RemoteIrohTransportError.unexpectedFrame
    }

    private static func pathKind(from summary: String) -> RemoteIrohPathKind {
        let lower = summary.lowercased()
        if lower.contains("relay") { return .relay }
        if lower.contains("192.168.") || lower.contains("10.") || lower.contains("172.16.") {
            return .localDirect
        }
        if lower.contains("direct") || lower.contains("udp") { return .internetDirect }
        return .unknown
    }
}

enum RemoteIrohTransportError: LocalizedError, Equatable {
    case bindingUnavailable
    case localIdentityChanged
    case serverEndpointMismatch
    case unexpectedFrame
    case frameTooLarge
    case pairingOutcomeUnknown

    var errorDescription: String? {
        switch self {
        case .bindingUnavailable: "The paired Mac has no usable Iroh endpoint binding."
        case .localIdentityChanged: "The phone’s pairing identity changed. Pair with the Mac again."
        case .serverEndpointMismatch: "The authenticated Iroh endpoint did not match the paired Mac."
        case .unexpectedFrame: "The Mac returned an unexpected Iroh frame."
        case .frameTooLarge: "The Mac returned an oversized Iroh frame."
        case .pairingOutcomeUnknown:
            "The Mac may have accepted the pairing, but its response was lost. Refresh the QR code and pair again."
        }
    }
}
