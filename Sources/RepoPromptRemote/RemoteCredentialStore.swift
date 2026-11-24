import Foundation
import RepoPromptRemoteProtocol
import Security

struct StoredRemoteIrohBinding: Codable, Equatable {
    let expectedDesktopEndpointID: String
    let localMobileEndpointID: String
    let wireVersion: Int
    let serverAddress: RemoteIrohEndpointAddress

    init(
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

struct StoredRemoteCredential: Codable, Equatable {
    let desktopInstanceID: String
    let deviceID: String
    let credential: String
    let irohBinding: StoredRemoteIrohBinding

    init(
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

struct StoredRemotePairingAttempt: Codable, Equatable {
    let id: UUID
    let advertisement: RemoteIrohPairingAdvertisement
    let localEndpointID: String
}

enum StoredRemotePairing: Codable, Equatable {
    case preparing(StoredRemotePairingAttempt)
    case confirming(StoredRemoteCredential, attemptID: UUID)
    case paired(StoredRemoteCredential)

    func encodedForKeychain() throws -> Data {
        let encoder = JSONEncoder()
        switch self {
        case let .paired(credential): return try encoder.encode(credential)
        case .preparing, .confirming: return try encoder.encode(self)
        }
    }

    static func decode(_ data: Data) throws -> Self {
        let decoder = JSONDecoder()
        if let pairing = try? decoder.decode(Self.self, from: data) { return pairing }
        return .paired(try decoder.decode(StoredRemoteCredential.self, from: data))
    }
}

enum RemoteCredentialStoreError: LocalizedError {
    case invalidKeychainData
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidKeychainData:
            "The saved pairing could not be read. Retry Keychain or reset pairing."
        case let .keychain(status):
            "Pairing could not be accessed in Keychain (status \(status)). Unlock the phone and retry."
        }
    }
}

protocol RemoteCredentialStoring {
    func load() throws -> StoredRemotePairing?
    func save(_ pairing: StoredRemotePairing) throws
    func delete() throws
}

/// Keychain-backed storage for the one paired device. The credential is never
/// put in UserDefaults, snapshots, analytics, or diagnostic strings.
final class RemoteCredentialStore: RemoteCredentialStoring {
    private let service = "com.repoprompt.remote.credential"
    private let account = "paired-desktop"

    func load() throws -> StoredRemotePairing? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw RemoteCredentialStoreError.keychain(status) }
        guard let data = result as? Data else { throw RemoteCredentialStoreError.invalidKeychainData }
        do {
            return try StoredRemotePairing.decode(data)
        } catch {
            throw RemoteCredentialStoreError.invalidKeychainData
        }
    }

    func save(_ pairing: StoredRemotePairing) throws {
        let data = try pairing.encodedForKeychain()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw RemoteCredentialStoreError.keychain(addStatus) }
        } else if updateStatus != errSecSuccess {
            throw RemoteCredentialStoreError.keychain(updateStatus)
        }
    }

    func delete() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw RemoteCredentialStoreError.keychain(status)
        }
    }
}
