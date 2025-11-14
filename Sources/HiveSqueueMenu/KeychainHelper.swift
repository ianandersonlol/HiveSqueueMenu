import Foundation
import Security

enum KeychainHelper {
    static func savePassword(_ password: String, service: String, account: String) throws {
        print("[Keychain] SAVING password for service: \(service), account: \(account)")
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
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch status {
        case errSecSuccess:
            print("[Keychain] Password updated successfully")
            return
        case errSecItemNotFound:
            var newItem = query
            newItem[kSecValueData as String] = passwordData
            newItem[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(newItem as CFDictionary, nil)
            if addStatus != errSecSuccess {
                print("[Keychain] ERROR adding password: \(addStatus)")
                throw KeychainError.osStatus(addStatus)
            }
            print("[Keychain] Password added successfully")
        default:
            print("[Keychain] ERROR updating password: \(status)")
            throw KeychainError.osStatus(status)
        }
    }

    static func loadPassword(service: String, account: String) -> String? {
        print("[Keychain] LOADING password for service: \(service), account: \(account)")
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else {
            print("[Keychain] Password not found or error: \(status)")
            return nil
        }
        print("[Keychain] Password loaded successfully (length: \(password.count))")
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
    case osStatus(OSStatus)

    var errorDescription: String? {
        switch self {
        case .unableToEncode:
            return "Unable to encode password."
        case .osStatus(let status):
            if let message = SecCopyErrorMessageString(status, nil) as String? {
                return "Keychain error (\(status)): \(message)"
            } else {
                return "Keychain error (\(status))."
            }
        }
    }
}
