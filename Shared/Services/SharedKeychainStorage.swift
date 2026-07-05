import Foundation
import Security
import Supabase

/// Stores the Supabase auth session in a keychain access group shared between
/// the main app and the share extension, so a share from TikTok/Instagram can
/// authenticate without the user ever opening the extension UI.
struct SharedKeychainStorage: AuthLocalStorage {
    private let service = "com.ehubbartt.socialsaver.auth"

    private var accessGroup: String {
        let prefix = Bundle.main.object(forInfoDictionaryKey: "AppIdentifierPrefix") as? String
            ?? teamIdentifierPrefix()
        return prefix + SupabaseConfig.keychainAccessGroup
    }

    func store(key: String, value: Data) throws {
        var query = baseQuery(key: key)
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let update: [String: Any] = [kSecValueData as String: value]
            let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
            guard updateStatus == errSecSuccess else { throw KeychainError.status(updateStatus) }
        } else {
            query[kSecValueData as String] = value
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.status(addStatus) }
        }
    }

    func retrieve(key: String) throws -> Data? {
        var query = baseQuery(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.status(status)
        }
    }

    func remove(key: String) throws {
        let status = SecItemDelete(baseQuery(key: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.status(status)
        }
    }

    private func baseQuery(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecAttrAccessGroup as String: accessGroup,
        ]
    }

    /// Resolves the team ID prefix by reading the access group of a probe item.
    private func teamIdentifierPrefix() -> String {
        let probe: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service + ".probe",
            kSecAttrAccount as String: "probe",
            kSecReturnAttributes as String: true,
        ]
        var result: AnyObject?
        var status = SecItemCopyMatching(probe as CFDictionary, &result)
        if status == errSecItemNotFound {
            SecItemAdd(probe as CFDictionary, nil)
            status = SecItemCopyMatching(probe as CFDictionary, &result)
        }
        guard status == errSecSuccess,
              let attrs = result as? [String: Any],
              let group = attrs[kSecAttrAccessGroup as String] as? String,
              let dotIndex = group.firstIndex(of: ".")
        else { return "" }
        return String(group[...dotIndex])
    }

    enum KeychainError: Error {
        case status(OSStatus)
    }
}
