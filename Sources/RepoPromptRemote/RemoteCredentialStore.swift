import Foundation
import RepoPromptRemoteNetworking
import Security

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
