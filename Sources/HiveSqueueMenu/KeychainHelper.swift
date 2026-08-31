import Foundation
import Security

protocol CredentialStoring: Sendable {
    func save(_ secret: String, service: String, account: String) throws
    func load(service: String, account: String) throws -> String?
    func delete(service: String, account: String) throws
}

struct KeychainCredentialStore: CredentialStoring {
    func save(_ secret: String, service: String, account: String) throws {
        try KeychainHelper.savePassword(secret, service: service, account: account)
    }

    func load(service: String, account: String) throws -> String? {
        try KeychainHelper.loadPassword(service: service, account: account)
    }

    func delete(service: String, account: String) throws {
        try KeychainHelper.deletePassword(service: service, account: account)
    }
}

enum KeychainHelper {
    static func savePassword(_ password: String, service: String, account: String) throws {
        guard let passwordData = password.data(using: .utf8) else {
            throw KeychainError.unableToEncode
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: passwordData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var newItem = query
            newItem[kSecValueData as String] = passwordData
            newItem[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            if addStatus != errSecSuccess {
                throw KeychainError.osStatus(addStatus)
            }
        default:
            throw KeychainError.osStatus(status)
        }
    }

    static func loadPassword(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.osStatus(status)
        }
        guard let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            throw KeychainError.unableToDecode
        }
        return password
    }

    static func deletePassword(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw KeychainError.osStatus(status)
        }
    }
}

enum KeychainError: Error, LocalizedError {
    case unableToEncode
    case unableToDecode
    case osStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unableToEncode:
            return "Unable to encode password."
        case .unableToDecode:
            return "Unable to decode the stored password."
        case .osStatus(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "Keychain error (\(status)): \(message)"
            } else {
                return "Keychain error (\(status))."
            }
        }
    }
}
