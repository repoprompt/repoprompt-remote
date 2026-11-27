import Foundation
import RepoPromptIrohTransport
import RepoPromptRemoteProtocol

public enum RemoteNetworkError: LocalizedError {
    case peerMismatch
    case responseTooLarge

    public var errorDescription: String? {
        switch self {
        case .peerMismatch: "The authenticated endpoint did not match the paired device."
        case .responseTooLarge: "The Iroh response exceeds its size limit."
        }
    }
}

public enum RemoteNetwork {
    public static func endpointID(for secret: Data) throws -> String {
        try endpointIdForSecret(secretKey: secret)
    }

    public static func isFrameTimeout(_ error: Error) -> Bool {
        guard case let TransportError.Failure(detail) = error else { return false }
        return detail.hasPrefix("frame I/O timed out") || detail == "response frame I/O timed out"
    }

    static func path(from summary: String) -> RemoteIrohPathKind {
        if let selected = RemoteIrohPathKind(rawValue: summary) { return selected }
        let path = summary.lowercased()
        if path.contains("relay") { return .relay }
        if path.contains("192.168.") || path.contains("10.") || path.contains("172.16.") { return .localDirect }
        if path.contains("direct") || path.contains("udp") { return .internetDirect }
        return .unknown
    }

    static func mayRetry(_ operation: RemoteRPCOperation) -> Bool {
        switch operation {
        case .snapshot, .diagnostics, .workspaces, .sessions, .agents, .workflows, .history, .transcript:
            true
        case .unpair, .command, .contextBuilder, .imageAttachment:
            false
        }
    }
}

public final class RemoteNetworkEndpoint: Sendable {
    private let endpoint: TransportEndpoint

    private init(_ endpoint: TransportEndpoint) {
        self.endpoint = endpoint
    }

    public static func start(secret: Data, relayEnabled: Bool = true, generation: UInt64) async throws -> RemoteNetworkEndpoint {
        let endpoint = try await RepoPromptIrohSpike.startApplication(
            secret: secret, relayEnabled: relayEnabled, generation: generation
        )
        guard !Task.isCancelled else {
            try? await endpoint.shutdown()
            throw CancellationError()
        }
        return RemoteNetworkEndpoint(endpoint)
    }

    public func address(waitForRelay: Bool = false) async throws -> RemoteIrohEndpointAddress {
        if waitForRelay, let snapshot = try? await endpoint.waitUntilOnline(timeoutMillis: 5_000) {
            return Self.address(of: snapshot)
        }
        try Task.checkCancellation()
        return try currentAddress()
    }

    public func currentAddress() throws -> RemoteIrohEndpointAddress {
        try Self.address(of: endpoint.snapshot())
    }

    private static func address(of snapshot: EndpointSnapshot) -> RemoteIrohEndpointAddress {
        .init(endpointID: snapshot.endpointId, transportAddressJSON: snapshot.addressJson)
    }

    func connect(addressJSON: String, expectedPeerID: String) async throws -> RemoteNetworkConnection {
        try Task.checkCancellation()
        let connection = try await endpoint.connectWithPolicy(
            addressJson: addressJSON, alpn: RepoPromptIrohSpike.alpn,
            allowRelay: true, localOnly: false, timeoutMillis: 20_000
        )
        if Task.isCancelled || connection.peerEndpointId() != expectedPeerID {
            connection.close()
            try Task.checkCancellation()
            throw RemoteNetworkError.peerMismatch
        }
        return RemoteNetworkConnection(connection)
    }

    @MainActor
    public func listen(
        onAccept: @escaping @MainActor () -> Void,
        onFailure: @escaping @MainActor (Error) -> Void,
        handle: @escaping @MainActor (RemoteNetworkRequest) async -> Void
    ) -> Task<Void, Never> {
        Task {
            var backoff = RemoteConnectionBackoff()
            while !Task.isCancelled {
                do {
                    let request = try await endpoint.acceptRequest()
                    guard !Task.isCancelled else {
                        request.close()
                        return
                    }
                    backoff.connected()
                    onAccept()
                    Task { @MainActor in await handle(RemoteNetworkRequest(request)) }
                } catch {
                    guard !Task.isCancelled else { return }
                    onFailure(error)
                    backoff.failed(at: .now)
                    if let next = backoff.nextAttempt {
                        try? await ContinuousClock().sleep(until: next)
                    }
                }
            }
        }
    }

    public func shutdown() async throws {
        try await endpoint.shutdown()
    }
}

final class RemoteNetworkConnection: Sendable {
    private let connection: TransportConnection

    fileprivate init(_ connection: TransportConnection) {
        self.connection = connection
    }

    var path: RemoteIrohPathKind {
        RemoteNetwork.path(from: connection.pathSummary())
    }

    func exchange(_ frame: RemoteWireFrame, read operation: RemoteRPCOperation? = nil) async throws -> RemoteWireFrame {
        try Task.checkCancellation()
        let encoded = try JSONEncoder().encode(frame)
        guard encoded.count <= RemoteWireProtocol.maximumClientFrameBytes else {
            throw RemoteWireContractError.frameTooLarge(
                actual: encoded.count, maximum: RemoteWireProtocol.maximumClientFrameBytes
            )
        }
        let response: Data
        do {
            response = try await connection.sendFrame(payload: encoded)
        } catch where (operation.map(RemoteNetwork.mayRetry) == true || frame.kind == .eventSubscribe)
            && RemoteNetwork.isFrameTimeout(error)
        {
            // QUIC stream timeouts are isolated. Repeat the read on a fresh stream
            // while retaining the authenticated connection and the original request identity.
            try await Task.sleep(for: .milliseconds(Int.random(in: 200 ... 400)))
            response = try await connection.sendFrame(payload: encoded)
        }
        try Task.checkCancellation()
        let maximum = RemoteWireProtocol.maximumServerResponseFrameBytes
        guard response.count <= maximum else {
            throw RemoteWireContractError.frameTooLarge(actual: response.count, maximum: maximum)
        }
        let decoded = try JSONDecoder().decode(RemoteWireFrame.self, from: response)
        guard decoded.wireVersion == RemoteWireProtocol.currentVersion else {
            throw RemoteWireContractError.unsupportedWireVersion(decoded.wireVersion)
        }
        return decoded
    }

    func close() {
        connection.close()
    }
}

public struct RemoteNetworkRequest: Sendable {
    private let request: IncomingRequest

    fileprivate init(_ request: IncomingRequest) {
        self.request = request
    }

    public var peerEndpointID: String { request.peerEndpointId() }
    public var generation: UInt64 { request.generation() }
    public var path: RemoteIrohPathKind { RemoteNetwork.path(from: request.pathSummary()) }

    public func frame() throws -> RemoteWireFrame {
        let data = request.payload()
        let maximum = RemoteWireProtocol.maximumClientFrameBytes
        guard data.count <= maximum else {
            throw RemoteWireContractError.frameTooLarge(actual: data.count, maximum: maximum)
        }
        return try JSONDecoder().decode(RemoteWireFrame.self, from: data)
    }

    @MainActor
    public func respond(_ frame: RemoteWireFrame) async throws {
        let direction: RemoteWireDirection = frame.kind == .event ? .serverEvent : .serverResponse
        let encoded = try JSONEncoder().encode(frame)
        guard encoded.count <= direction.maximumEncodedFrameBytes else {
            throw RemoteNetworkError.responseTooLarge
        }
        try await request.respond(payload: encoded)
    }

    public func close() {
        request.close()
    }
}

public struct RemoteConnectionBackoff {
    public private(set) var nextAttempt: ContinuousClock.Instant?
    private var failures = 0

    public init() {}

    public mutating func started(at now: ContinuousClock.Instant) {
        nextAttempt = now.advanced(by: .seconds(2))
    }

    public mutating func connected() {
        failures = 0
    }

    public mutating func failed(at now: ContinuousClock.Instant) {
        let delay = pow(2.0, Double(failures)) * Double.random(in: 0.8 ... 1.2)
        failures = min(failures + 1, 4)
        let retry = now.advanced(by: .seconds(delay))
        nextAttempt = max(nextAttempt ?? retry, retry)
    }
}
