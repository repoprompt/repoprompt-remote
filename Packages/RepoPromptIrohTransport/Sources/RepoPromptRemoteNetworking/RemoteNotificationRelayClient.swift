import Foundation
import RepoPromptRemoteProtocol

public final class RemoteNotificationRelayClient: Sendable {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        session = URLSession(configuration: configuration)
    }

    public func deliver(
        to relayURL: URL,
        registration: RemoteNotificationRegistration,
        desktopInstanceID: String,
        deviceID: String,
        envelope: RemoteNotificationEnvelope
    ) async throws {
        guard Self.isAllowedRelayURL(relayURL) else { throw RelayError.insecureURL }
        let body = Delivery(
            platform: registration.platform, deviceToken: registration.deviceToken,
            desktopInstanceID: desktopInstanceID, deviceID: deviceID, envelope: envelope
        )
        var request = URLRequest(url: relayURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(body)
        let (_, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200 ..< 300).contains(status) else { throw RelayError.http(status) }
    }

    private static func isAllowedRelayURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else {
            return false
        }
        if scheme == "https" { return true }
        guard scheme == "http" else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }

    private enum RelayError: LocalizedError {
        case insecureURL
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .insecureURL:
                "Notification relay URL must use HTTPS (HTTP is allowed only for loopback development URLs)."
            case let .http(status):
                "Notification relay returned HTTP \(status)."
            }
        }
    }

    private struct Delivery: Encodable {
        let platform: RemoteNotificationPlatform
        let deviceToken: String
        let desktopInstanceID: String
        let deviceID: String
        let envelope: RemoteNotificationEnvelope
    }
}
