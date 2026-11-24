import Foundation
import RepoPromptIrohTransport
import RepoPromptRemoteProtocol
import Sentry

enum RemotePairingTelemetry {
    typealias TraceStatus = SentrySpanStatus
    private static let completionMessage = "Remote pairing completed on iOS"

    enum Stage: String {
        case decodeQR = "decode_qr"
        case localIdentity = "local_identity"
        case startEndpoint = "start_endpoint"
        case dialLocal = "dial_local"
        case dialDirect = "dial_direct"
        case dialRelay = "dial_relay"
        case verifyPeer = "verify_peer"
        case pairingHello = "pairing_hello"
        case decodeResponse = "decode_response"
        case authenticate
        case saveCredential = "save_credential"
        case initialSnapshot = "initial_snapshot"
    }

    struct Attempt {
        var stage: Stage = .localIdentity
        var underlyingFailure: String?
        var path: RemoteIrohPathKind?
        var helloSent = false
    }

    @MainActor
    static func start() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["REPOPROMPT_TELEMETRY_DISABLED"] != "1" else { return }
        let bundledDSN = Bundle.main.object(forInfoDictionaryKey: "RepoPromptSentryDSN") as? String
        #if DEBUG
        let dsn = environment["REPOPROMPT_SENTRY_DSN"] ?? bundledDSN
        #else
        let dsn = bundledDSN
        #endif
        guard let dsn, URLComponents(string: dsn)?.scheme == "https" else { return }

        SentrySDK.start { options in
            options.dsn = dsn
            #if DEBUG
            options.environment = "debug"
            options.tracesSampleRate = 1
            #else
            options.environment = "production"
            options.tracesSampleRate = 0.1
            #endif
            // Scope collection to explicit pairing events and transactions.
            options.sendDefaultPii = false
            options.enableCrashHandler = false
            options.enableWatchdogTerminationTracking = false
            options.enableAppHangTracking = false
            options.enableMetricKit = false
            options.enableAutoSessionTracking = false
            options.enableLogs = true
            options.enableAutoBreadcrumbTracking = false
            options.enableNetworkBreadcrumbs = false
            options.enableNetworkTracking = false
            options.enableCaptureFailedRequests = false
            options.enableAutoPerformanceTracing = false
            options.enableFileIOTracing = false
            options.enableCoreDataTracing = false
            options.attachStacktrace = false
            options.beforeSend = { event in
                guard event.tags?["component"] == "remote_pairing" else { return nil }
                scrub(event)
                return event
            }
            options.beforeSendLog = { log in
                guard log.body == completionMessage else { return nil }
                log.attributes = log.attributes.filter {
                    ["pairing_attempt", "pairing_side", "pairing_path", "sentry.release", "sentry.environment"].contains($0.key)
                }
                return log
            }
        }
    }

    static func begin(attemptID: UUID) -> Span {
        let span = SentrySDK.startTransaction(name: "Remote pairing", operation: "remote.pairing", bindToScope: false)
        span.setTag(value: "remote_pairing", key: "component")
        span.setTag(value: "ios", key: "pairing_side")
        span.setTag(value: attemptID.uuidString.lowercased(), key: "pairing_attempt")
        return span
    }

    static func failure(_ error: Error, attempt: Attempt, attemptID: UUID? = nil) {
        guard SentrySDK.isEnabled else { return }
        let reason = attempt.underlyingFailure ?? failureReason(error)
        let event = Event(level: .error)
        event.message = SentryMessage(formatted: "Remote pairing failed: \(attempt.stage.rawValue) / \(reason)")
        event.fingerprint = ["remote-pairing", attempt.stage.rawValue, reason]
        var tags = [
            "component": "remote_pairing",
            "pairing_side": "ios",
            "pairing_stage": attempt.stage.rawValue,
            "pairing_reason": reason,
            "pairing_hello_sent": String(attempt.helloSent),
        ]
        if let attemptID { tags["pairing_attempt"] = attemptID.uuidString.lowercased() }
        if let path = attempt.path { tags["pairing_path"] = path.rawValue }
        event.tags = tags
        SentrySDK.capture(event: event)
    }

    static func complete(attemptID: UUID, path: RemoteIrohPathKind?) {
        guard SentrySDK.isEnabled else { return }
        SentrySDK.logger.info(completionMessage, attributes: [
            "pairing_attempt": attemptID.uuidString.lowercased(),
            "pairing_side": "ios",
            "pairing_path": path?.rawValue ?? "unknown",
        ])
    }

    static func failureReason(_ error: Error) -> String {
        switch error {
        case RemotePairingError.expiredQRCode: "expired_qr"
        case RemotePairingError.invalidQRCode: "invalid_qr"
        case RemotePairingError.unsupportedProtocol, RemoteGatewayError.protocolMismatch: "unsupported_protocol"
        case RemotePairingError.unavailableDesktop: "desktop_unreachable"
        case RemoteIrohTransportError.bindingUnavailable: "missing_endpoint_binding"
        case RemoteIrohTransportError.serverEndpointMismatch: "endpoint_mismatch"
        case RemoteIrohTransportError.frameTooLarge: "frame_too_large"
        case RemoteIrohTransportError.unexpectedFrame: "unexpected_frame"
        case RemoteGatewayError.credentialRejected: "credential_rejected"
        case RemoteGatewayError.invalidResponse: "invalid_response"
        case RemoteGatewayError.requestRejected(let response):
            // A remote peer controls the full response. Only known codes enter telemetry.
            switch response.code {
            case "pairing_failed": "desktop_rejected_pairing"
            case "transport_error": "desktop_transport_error"
            default: "desktop_rejected_request"
            }
        case is TransportError: "iroh_transport_error"
        case is DecodingError: "invalid_payload"
        default: "operation_failed"
        }
    }

    private static func scrub(_ event: Event) {
        event.user = nil
        event.request = nil
        event.serverName = nil
        event.breadcrumbs = nil
        event.extra = nil
        event.context = event.context?.filter { $0.key == "trace" }
    }
}
