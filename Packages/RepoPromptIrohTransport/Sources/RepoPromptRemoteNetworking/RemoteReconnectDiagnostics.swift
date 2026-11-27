import Foundation
import RepoPromptIrohTransport
import RepoPromptRemoteProtocol

public enum RemoteReconnectDiagnostics {
    public static let historyLimit = 30
    public static let historyKey = "RepoPromptRemote.reconnectHistory"

    public enum Network: String, Codable {
        case wifi, cellular, ethernet, other, offline, unknown

        public init(interface: String) {
            switch interface {
            case "wifi": self = .wifi
            case "cellular": self = .cellular
            case "wiredEthernet": self = .ethernet
            case "unknown": self = .unknown
            default: self = .other
            }
        }
    }

    public enum Stage: String, Codable {
        case localIdentity = "local_identity"
        case binding
        case endpointStartup = "endpoint_startup"
        case dial
        case authenticate
        case firstSync = "first_sync" // Retain decoding for reports saved by earlier builds.
        case firstSnapshot = "first_snapshot"
        case syncConfirmation = "sync_confirmation"
    }

    public enum Outcome: String, Codable {
        case connected, failed, cancelled
    }

    public enum Reason: String, Codable {
        case networkChanged = "network_changed"
        case cancelled
        case bindingUnavailable = "binding_unavailable"
        case identityChanged = "identity_changed"
        case keychainUnavailable = "keychain_unavailable"
        case endpointStartupFailed = "endpoint_startup_failed"
        case missingRoutes = "missing_routes"
        case invalidAddress = "invalid_address"
        case relayRegistrationTimeout = "relay_registration_timeout"
        case dialTimeout = "dial_timeout"
        case dialFailed = "dial_failed"
        case frameTimeout = "frame_timeout"
        case credentialRejected = "credential_rejected"
        case peerMismatch = "peer_mismatch"
        case protocolMismatch = "protocol_mismatch"
        case invalidResponse = "invalid_response"
        case desktopRejected = "desktop_rejected"
        case transportError = "transport_error"
        case operationFailed = "operation_failed"

        public init(error: Error, stage: Stage) {
            switch error {
            case RemoteIrohTransportError.bindingUnavailable: self = .bindingUnavailable
            case RemoteIrohTransportError.localIdentityChanged: self = .identityChanged
            case RemoteIrohTransportError.serverEndpointMismatch: self = .peerMismatch
            case RemoteGatewayError.credentialRejected: self = .credentialRejected
            case RemoteGatewayError.protocolMismatch: self = .protocolMismatch
            case RemoteGatewayError.requestRejected: self = .desktopRejected
            case RemoteGatewayError.invalidResponse, RemoteIrohTransportError.unexpectedFrame,
                 RemoteIrohTransportError.frameTooLarge, is DecodingError:
                self = .invalidResponse
            case let TransportError.Failure(detail):
                switch detail {
                case "no endpoint addresses satisfy the connection policy": self = .missingRoutes
                case "timed out waiting for relay registration": self = .relayRegistrationTimeout
                case "timed out connecting endpoint": self = .dialTimeout
                case _ where RemoteNetwork.isFrameTimeout(error): self = .frameTimeout
                case let message where message.hasPrefix("decode endpoint address:"): self = .invalidAddress
                default:
                    switch stage {
                    case .endpointStartup: self = .endpointStartupFailed
                    case .dial: self = .dialFailed
                    default: self = .transportError
                    }
                }
            default: self = .operationFailed
            }
        }
    }

    public struct Timing: Codable {
        public let stage: Stage
        public let milliseconds: Int
    }

    public struct Entry: Codable {
        public let startedAt: Date
        public let network: Network
        public let endingNetwork: Network
        public let networkChanged: Bool
        public let attempt: Int
        public let elapsedMilliseconds: Int
        public let recoveryMilliseconds: Int
        public let stage: Stage
        public let timings: [Timing]
        public let outcome: Outcome
        public let reason: Reason?
        public let savedRelayHint: Bool?
        public let localRelayHint: Bool?
        public let route: RemoteIrohPathKind?
        public let snapshotBytes: Int?
    }

    public struct Attempt {
        public init() {}

        public let startedAt = Date()
        public let start = ContinuousClock.now
        public private(set) var stage: Stage = .localIdentity
        private var stageStart = ContinuousClock.now
        private var timings: [Timing] = []
        public var savedRelayHint: Bool?
        public var localRelayHint: Bool?
        public var snapshotBytes: Int?

        public mutating func enter(_ next: Stage) {
            let now = ContinuousClock.now
            timings.append(Timing(stage: stage, milliseconds: milliseconds(stageStart.duration(to: now))))
            stage = next
            stageStart = now
        }

        public func finish(
            network: Network,
            endingNetwork: Network,
            networkChanged: Bool,
            attempt: Int,
            recoveryStart: ContinuousClock.Instant,
            outcome: Outcome,
            reason: Reason? = nil,
            route: RemoteIrohPathKind?
        ) -> Entry {
            let now = ContinuousClock.now
            return Entry(
                startedAt: startedAt, network: network, endingNetwork: endingNetwork, networkChanged: networkChanged,
                attempt: attempt, elapsedMilliseconds: milliseconds(start.duration(to: now)),
                recoveryMilliseconds: milliseconds(recoveryStart.duration(to: now)),
                stage: stage, timings: timings + [Timing(stage: stage, milliseconds: milliseconds(stageStart.duration(to: now)))],
                outcome: outcome, reason: reason, savedRelayHint: savedRelayHint, localRelayHint: localRelayHint,
                route: route, snapshotBytes: snapshotBytes
            )
        }

        private func milliseconds(_ duration: Duration) -> Int {
            let (seconds, attoseconds) = duration.components
            return Int(seconds * 1_000 + attoseconds / 1_000_000_000_000_000)
        }
    }

    public static func relayHint(in addressJSON: String?) -> Bool? {
        guard let addressJSON, addressJSON.utf8.count <= 16_384,
              let address = try? JSONSerialization.jsonObject(with: Data(addressJSON.utf8)) as? [String: Any],
              let addresses = address["addrs"] as? [Any]
        else { return nil }
        return addresses.contains { ($0 as? [String: Any])?["Relay"] is String }
    }

    public static func append(_ entry: Entry, to history: [Entry]) -> [Entry] {
        Array((history + [entry]).suffix(historyLimit))
    }

    public static func report(_ history: [Entry]) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(history) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
