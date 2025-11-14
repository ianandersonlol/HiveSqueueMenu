import Combine
import Foundation

final class UserSettings: ObservableObject {
    private enum Keys {
        static let host = "sshHost"
        static let username = "sshUsername"
        static let identityFilePath = "sshIdentityFilePath"
    }

    private let defaults: UserDefaults
    private let keychainService = "HiveSqueueMenu"
    private var isLoadingPassword = false

    @Published var host: String {
        didSet {
            defaults.set(host, forKey: Keys.host)
            reloadPasswordForCurrentHost()
            updateConnectionSettings()
        }
    }

    @Published var username: String {
        didSet {
            defaults.set(username, forKey: Keys.username)
            updateConnectionSettings()
        }
    }

    @Published var identityFilePath: String {
        didSet {
            defaults.set(identityFilePath, forKey: Keys.identityFilePath)
            updateConnectionSettings()
        }
    }

    @Published var password: String {
        didSet {
            guard !isLoadingPassword else {
                print("[UserSettings] Skipping password save - loading from keychain")
                return
            }
            // Only save if password actually changed from what's stored
            if oldValue == password {
                print("[UserSettings] Password unchanged, skipping save")
                return
            }
            print("[UserSettings] Password changed (old length: \(oldValue.count), new length: \(password.count))")
            do {
                if password.isEmpty {
                    try KeychainHelper.deletePassword(service: keychainService, account: host)
                } else {
                    try KeychainHelper.savePassword(password, service: keychainService, account: host)
                }
            } catch {
                NSLog("HiveSqueueMenu: Unable to save password - \(error.localizedDescription)")
            }
            updateConnectionSettings()
        }
    }

    @Published private(set) var connectionSettings: ConnectionSettings

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedHost = defaults.string(forKey: Keys.host)?.nonEmpty ?? AppConfig.clusterHost
        let storedUsername = defaults.string(forKey: Keys.username)?.nonEmpty ?? ""
        let storedIdentity = defaults.string(forKey: Keys.identityFilePath)?.nonEmpty ?? ""
        let storedPassword = KeychainHelper.loadPassword(service: keychainService, account: storedHost) ?? ""

        print("[UserSettings] Loaded from storage - host: \(storedHost), user: \(storedUsername), key: \(storedIdentity), hasPassword: \(!storedPassword.isEmpty)")

        // Set loading flag BEFORE setting password to prevent didSet
        isLoadingPassword = true
        host = storedHost
        username = storedUsername
        identityFilePath = storedIdentity
        password = storedPassword
        isLoadingPassword = false

        let initialSettings = ConnectionSettings(
            host: storedHost,
            username: storedUsername,
            identityFilePath: storedIdentity.nonEmpty,
            password: storedPassword.nonEmpty
        )
        print("[UserSettings] ConnectionSettings created - isConfigured: \(initialSettings.isConfigured)")
        print("[UserSettings] Details - host: \(initialSettings.host), user: \(initialSettings.username), identityPath: \(initialSettings.identityFilePath ?? "nil"), hasPassword: \(initialSettings.password != nil)")
        connectionSettings = initialSettings
    }

    private func reloadPasswordForCurrentHost() {
        isLoadingPassword = true
        password = KeychainHelper.loadPassword(service: keychainService, account: host) ?? ""
        isLoadingPassword = false
    }

    private func updateConnectionSettings() {
        let newSettings = ConnectionSettings(
            host: host,
            username: username,
            identityFilePath: identityFilePath.nonEmpty,
            password: password.nonEmpty
        )
        print("[UserSettings] updateConnectionSettings - old: \(connectionSettings), new: \(newSettings), equal: \(connectionSettings == newSettings)")
        // Only update if actually different to avoid triggering observers
        guard connectionSettings != newSettings else {
            print("[UserSettings] Skipping update - settings unchanged")
            return
        }
        connectionSettings = newSettings
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
