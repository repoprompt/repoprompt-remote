import RepoPromptRemoteNetworking
import Foundation
import RepoPromptIrohTransport
import RepoPromptRemoteProtocol
import Sentry

enum RemotePairingTelemetry {
    typealias TraceStatus = SentrySpanStatus
    private static let completionMessage = "Remote pairing completed on iOS"
    private static let reconnectMessage = "Remote reconnect outcome on iOS"
    private static let reconnectAttributes: Set<String> = [
        "network", "ending_network", "network_changed", "attempt", "elapsed_ms", "recovery_ms",
        "stage", "outcome", "reason", "saved_relay_hint", "local_relay_hint", "route",
        "local_identity_ms", "binding_ms", "endpoint_startup_ms", "dial_ms", "authenticate_ms",
        "first_snapshot_ms", "sync_confirmation_ms", "snapshot_bytes",
        "sentry.release", "sentry.environment",
    ]

    enum Stage: String {
        case decodeQR = "decode_qr"
        case localIdentity = "local_identity"
        case saveAttempt = "save_attempt"
        case preparePairing = "prepare_pairing"
        case dial
        case saveCredential = "save_credential"
        case confirmPairing = "confirm_pairing"
        case saveConfirmation = "save_confirmation"
        case authenticate
        case initialSnapshot = "first_sync"
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
            // Scope collection to explicit pairing and reconnect diagnostics.
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
                let allowed: Set<String>
                switch log.body {
                case completionMessage:
                    allowed = ["pairing_attempt", "pairing_side", "pairing_path", "sentry.release", "sentry.environment"]
                case reconnectMessage:
                    allowed = reconnectAttributes
                default:
                    return nil
                }
                log.attributes = log.attributes.filter { allowed.contains($0.key) }
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

    static func failure(_ error: Error, stage: Stage, path: RemoteIrohPathKind? = nil, attemptID: UUID? = nil) {
        guard SentrySDK.isEnabled else { return }
        let reason = failureReason(error)
        let event = Event(level: .error)
        event.message = SentryMessage(formatted: "Remote pairing failed: \(stage.rawValue) / \(reason)")
        event.fingerprint = ["remote-pairing", stage.rawValue, reason]
        var tags = [
            "component": "remote_pairing",
            "pairing_side": "ios",
            "pairing_stage": stage.rawValue,
            "pairing_reason": reason,
        ]
        if let attemptID { tags["pairing_attempt"] = attemptID.uuidString.lowercased() }
        if let path { tags["pairing_path"] = path.rawValue }
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

    static func logReconnect(_ entry: RemoteReconnectDiagnostics.Entry) {
        guard SentrySDK.isEnabled else { return }
        var attributes: [String: Any] = [
            "network": entry.network.rawValue,
            "ending_network": entry.endingNetwork.rawValue,
            "network_changed": entry.networkChanged,
            "attempt": entry.attempt,
            "elapsed_ms": entry.elapsedMilliseconds,
            "recovery_ms": entry.recoveryMilliseconds,
            "stage": entry.stage.rawValue,
            "outcome": entry.outcome.rawValue,
            "route": entry.route?.rawValue ?? "unknown",
        ]
        if let reason = entry.reason { attributes["reason"] = reason.rawValue }
        if let hint = entry.savedRelayHint { attributes["saved_relay_hint"] = hint }
        if let hint = entry.localRelayHint { attributes["local_relay_hint"] = hint }
        if let bytes = entry.snapshotBytes { attributes["snapshot_bytes"] = bytes }
        for timing in entry.timings {
            attributes["\(timing.stage.rawValue)_ms"] = timing.milliseconds
        }
        if entry.outcome == .failed {
            SentrySDK.logger.warn(reconnectMessage, attributes: attributes)
        } else {
            SentrySDK.logger.info(reconnectMessage, attributes: attributes)
        }
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
        case RemoteIrohTransportError.confirmationUnavailable: "confirmation_unavailable"
        case RemoteGatewayError.credentialRejected: "credential_rejected"
        case RemoteGatewayError.invalidResponse: "invalid_response"
        case RemoteGatewayError.requestRejected(let response):
            // A remote peer controls the full response. Only known codes enter telemetry.
            switch response.code {
            case "pairing_failed": "desktop_rejected_pairing"
            case "pairing_expired": "expired_code"
            case "pairing_unavailable": "unavailable_code"
            case "pairing_upgrade_required": "upgrade_required"
            case "pairing_confirmation_rejected": "confirmation_rejected"
            case "pairing_storage_unavailable": "desktop_storage_unavailable"
            case "pairing_in_progress": "pairing_in_progress"
            case "already_paired": "already_paired"
            case "gateway_unavailable": "gateway_unavailable"
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
