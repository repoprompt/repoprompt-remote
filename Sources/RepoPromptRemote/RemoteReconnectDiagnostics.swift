import Foundation
import RepoPromptIrohTransport
import RepoPromptRemoteProtocol

enum RemoteReconnectDiagnostics {
    static let historyLimit = 30
    static let historyKey = "RepoPromptRemote.reconnectHistory"

    enum Network: String, Codable {
        case wifi, cellular, ethernet, other, offline, unknown

        init(interface: String) {
            switch interface {
            case "wifi": self = .wifi
            case "cellular": self = .cellular
            case "wiredEthernet": self = .ethernet
            case "unknown": self = .unknown
            default: self = .other
            }
        }
    }

    enum Stage: String, Codable {
        case localIdentity = "local_identity"
        case binding
        case endpointStartup = "endpoint_startup"
        case dial
        case authenticate
        case firstSync = "first_sync"
    }

    enum Outcome: String, Codable {
        case connected, failed, cancelled
    }

    enum Reason: String, Codable {
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

        init(error: Error, stage: Stage) {
            switch error {
            case is RemoteIrohIdentityStoreError: self = .keychainUnavailable
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
                case "frame I/O timed out", "response frame I/O timed out": self = .frameTimeout
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

    struct Timing: Codable {
        let stage: Stage
        let milliseconds: Int
    }

    struct Entry: Codable {
        let startedAt: Date
        let network: Network
        let endingNetwork: Network
        let networkChanged: Bool
        let attempt: Int
        let elapsedMilliseconds: Int
        let recoveryMilliseconds: Int
        let stage: Stage
        let timings: [Timing]
        let outcome: Outcome
        let reason: Reason?
        let savedRelayHint: Bool?
        let localRelayHint: Bool?
        let route: RemoteIrohPathKind?
    }

    struct Attempt {
        let startedAt = Date()
        let start = ContinuousClock.now
        private(set) var stage: Stage = .localIdentity
        private var stageStart = ContinuousClock.now
        private var timings: [Timing] = []
        var savedRelayHint: Bool?
        var localRelayHint: Bool?

        mutating func enter(_ next: Stage) {
            let now = ContinuousClock.now
            timings.append(Timing(stage: stage, milliseconds: milliseconds(stageStart.duration(to: now))))
            stage = next
            stageStart = now
        }

        func finish(
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
                outcome: outcome, reason: reason, savedRelayHint: savedRelayHint, localRelayHint: localRelayHint, route: route
            )
        }

        private func milliseconds(_ duration: Duration) -> Int {
            let (seconds, attoseconds) = duration.components
            return Int(seconds * 1_000 + attoseconds / 1_000_000_000_000_000)
        }
    }

    static func relayHint(in addressJSON: String?) -> Bool? {
        guard let addressJSON, addressJSON.utf8.count <= 16_384,
              let address = try? JSONSerialization.jsonObject(with: Data(addressJSON.utf8)) as? [String: Any],
              let addresses = address["addrs"] as? [Any]
        else { return nil }
        return addresses.contains { ($0 as? [String: Any])?["Relay"] is String }
    }

    static func append(_ entry: Entry, to history: [Entry]) -> [Entry] {
        Array((history + [entry]).suffix(historyLimit))
    }

    static func report(_ history: [Entry]) -> String? {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(history) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
