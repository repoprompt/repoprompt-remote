import Foundation
import RepoPromptRemoteProtocol

public struct StoredRemoteIrohBinding: Codable, Equatable {
    public let expectedDesktopEndpointID: String
    public let localMobileEndpointID: String
    public let wireVersion: Int
    public let serverAddress: RemoteIrohEndpointAddress

    public init(
        expectedDesktopEndpointID: String,
        localMobileEndpointID: String,
        wireVersion: Int = RemoteWireProtocol.currentVersion,
        serverAddress: RemoteIrohEndpointAddress
    ) {
        self.expectedDesktopEndpointID = expectedDesktopEndpointID
        self.localMobileEndpointID = localMobileEndpointID
        self.wireVersion = wireVersion
        self.serverAddress = serverAddress
    }
}

public struct StoredRemoteCredential: Codable, Equatable {
    public let desktopInstanceID: String
    public let deviceID: String
    public let credential: String
    public let irohBinding: StoredRemoteIrohBinding

    public init(
        desktopInstanceID: String,
        deviceID: String,
        credential: String,
        irohBinding: StoredRemoteIrohBinding
    ) {
        self.desktopInstanceID = desktopInstanceID
        self.deviceID = deviceID
        self.credential = credential
        self.irohBinding = irohBinding
    }
}

public struct StoredRemotePairingAttempt: Codable, Equatable {
    public let id: UUID
    public let advertisement: RemoteIrohPairingAdvertisement
    public let localEndpointID: String
    // Older Macs can consume the QR without an acknowledgment the phone can recover.
    public var legacyHelloMayHaveBeenSent: Bool?

    public init(
        id: UUID,
        advertisement: RemoteIrohPairingAdvertisement,
        localEndpointID: String,
        legacyHelloMayHaveBeenSent: Bool? = nil
    ) {
        self.id = id
        self.advertisement = advertisement
        self.localEndpointID = localEndpointID
        self.legacyHelloMayHaveBeenSent = legacyHelloMayHaveBeenSent
    }
}

public enum StoredRemotePairing: Codable, Equatable {
    case preparing(StoredRemotePairingAttempt)
    case confirming(StoredRemoteCredential, attemptID: UUID)
    case paired(StoredRemoteCredential)

    public func encodedForKeychain() throws -> Data {
        let encoder = JSONEncoder()
        switch self {
        case let .paired(credential): return try encoder.encode(credential)
        case .preparing, .confirming: return try encoder.encode(self)
        }
    }

    public static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        if let pairing = try? decoder.decode(Self.self, from: data) { return pairing }
        return .paired(try decoder.decode(StoredRemoteCredential.self, from: data))
    }
}
