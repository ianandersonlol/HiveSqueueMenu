import Combine
import Foundation

@MainActor
final class UserSettings: ObservableObject {
    private enum Keys {
        static let host = "sshHost"
        static let username = "sshUsername"
        static let clusterProfile = "clusterProfile"
        static let authenticationMode = "sshAuthenticationMode"
        static let identityFilePath = "sshIdentityFilePath"
        static let remoteCommand = "remoteCommand"
    }

    private let defaults: UserDefaults
    private let keychainService = "HiveSqueueMenu"
    private var isLoadingPassword = false
    private var loadedPasswordAccount: String?
    private var cancellables = Set<AnyCancellable>()

    @Published var host: String {
        didSet {
            defaults.set(host, forKey: Keys.host)
            updateConnectionSettings()
        }
    }

    @Published var username: String {
        didSet {
            defaults.set(username, forKey: Keys.username)
            updateConnectionSettings()
        }
    }

    @Published var clusterProfile: ClusterProfile {
        didSet {
            defaults.set(clusterProfile.rawValue, forKey: Keys.clusterProfile)
            updateConnectionSettings()
        }
    }

    @Published var authenticationMode: SSHAuthenticationMode {
        didSet {
            defaults.set(authenticationMode.rawValue, forKey: Keys.authenticationMode)
            updateConnectionSettings()
        }
    }

    @Published var identityFilePath: String {
        didSet {
            defaults.set(identityFilePath, forKey: Keys.identityFilePath)
            updateConnectionSettings()
        }
    }

    @Published var remoteCommand: String {
        didSet {
            defaults.set(remoteCommand, forKey: Keys.remoteCommand)
            updateConnectionSettings()
        }
    }

    @Published var password: String {
        didSet {
            if isLoadingPassword {
                updateConnectionSettings()
                return
            }

            guard oldValue != password else {
                updateConnectionSettings()
                return
            }

            do {
                guard let account = Self.keychainAccount(host: host, username: username) else {
                    updateConnectionSettings()
                    return
                }

                if password.isEmpty {
                    try KeychainHelper.deletePassword(service: keychainService, account: account)
                } else {
                    try KeychainHelper.savePassword(password, service: keychainService, account: account)
                }
                loadedPasswordAccount = account
                persistenceIssue = nil
            } catch {
                persistenceIssue = "The password could not be saved in Keychain: \(error.localizedDescription)"
            }

            updateConnectionSettings()
        }
    }

    @Published private(set) var connectionSettings: ConnectionSettings
    @Published private(set) var persistenceIssue: String?

    init(defaults: UserDefaults = UserDefaults(suiteName: AppConfig.defaultsSuiteName) ?? .standard) {
        self.defaults = defaults

        let storedHost = defaults.string(forKey: Keys.host)?.nonEmpty ?? AppConfig.clusterHost
        let storedUsername = defaults.string(forKey: Keys.username)?.nonEmpty ?? ""
        let storedClusterProfile = defaults.string(forKey: Keys.clusterProfile)
            .flatMap(ClusterProfile.init(rawValue:))
            ?? ClusterProfile.inferred(forHost: storedHost)
        let storedIdentity = defaults.string(forKey: Keys.identityFilePath)?.nonEmpty ?? ""
        let storedRemoteCommand = defaults.string(forKey: Keys.remoteCommand)?.nonEmpty ?? AppConfig.remoteCommand
        let storedPassword: String
        let passwordLoadIssue: String?
        do {
            storedPassword = try UserSettings.loadPassword(
                service: keychainService,
                host: storedHost,
                username: storedUsername
            ) ?? ""
            passwordLoadIssue = nil
        } catch {
            storedPassword = ""
            passwordLoadIssue = "The password could not be loaded from Keychain: \(error.localizedDescription)"
        }
        let storedMode = UserSettings.storedAuthenticationMode(
            defaults: defaults,
            identityFilePath: storedIdentity.nonEmpty,
            hasPassword: !storedPassword.isEmpty
        )

        isLoadingPassword = true
        host = storedHost
        username = storedUsername
        clusterProfile = storedClusterProfile
        authenticationMode = storedMode
        identityFilePath = storedIdentity
        remoteCommand = storedRemoteCommand
        password = storedPassword
        persistenceIssue = passwordLoadIssue
        isLoadingPassword = false

        loadedPasswordAccount = Self.keychainAccount(host: storedHost, username: storedUsername)
        connectionSettings = ConnectionSettings(
            host: storedHost,
            username: storedUsername,
            clusterProfile: storedClusterProfile,
            authentication: Self.makeAuthentication(mode: storedMode, identityFilePath: storedIdentity),
            password: storedPassword.nonEmpty,
            remoteCommand: storedRemoteCommand
        )

        bindPasswordReload()
    }

    func testConnection() async -> ConnectionDiagnostic {
        let settings = connectionSettings
        return await Task.detached(priority: .utility) {
            SlurmService(connection: settings).diagnoseConnection()
        }.value
    }

    private func bindPasswordReload() {
        Publishers.CombineLatest($host, $username)
            .dropFirst()
            .debounce(for: .milliseconds(350), scheduler: RunLoop.main)
            .sink { [weak self] host, username in
                self?.reloadPassword(host: host, username: username)
            }
            .store(in: &cancellables)
    }

    private func reloadPassword(host: String, username: String) {
        guard let account = Self.keychainAccount(host: host, username: username) else {
            loadedPasswordAccount = nil
            isLoadingPassword = true
            password = ""
            isLoadingPassword = false
            return
        }

        guard account != loadedPasswordAccount else { return }

        isLoadingPassword = true
        do {
            password = try Self.loadPassword(service: keychainService, host: host, username: username) ?? ""
            persistenceIssue = nil
        } catch {
            password = ""
            persistenceIssue = "The password could not be loaded from Keychain: \(error.localizedDescription)"
        }
        isLoadingPassword = false
        loadedPasswordAccount = account
    }

    private func updateConnectionSettings() {
        let newSettings = ConnectionSettings(
            host: host,
            username: username,
            clusterProfile: clusterProfile,
            authentication: Self.makeAuthentication(mode: authenticationMode, identityFilePath: identityFilePath),
            password: password.nonEmpty,
            remoteCommand: remoteCommand
        )

        guard connectionSettings != newSettings else { return }
        connectionSettings = newSettings
    }

    private static func storedAuthenticationMode(
        defaults: UserDefaults,
        identityFilePath: String?,
        hasPassword: Bool
    ) -> SSHAuthenticationMode {
        if let rawMode = defaults.string(forKey: Keys.authenticationMode),
           let mode = SSHAuthenticationMode(rawValue: rawMode) {
            return mode
        }

        if identityFilePath != nil {
            return .key
        }

        return hasPassword ? .passwordOnly : .agent
    }

    private static func makeAuthentication(mode: SSHAuthenticationMode, identityFilePath: String) -> SSHAuthentication {
        switch mode {
        case .agent:
            return .agent
        case .key:
            return .key(path: identityFilePath.trimmingCharacters(in: .whitespacesAndNewlines))
        case .passwordOnly:
            return .passwordOnly
        }
    }

    private static func loadPassword(service: String, host: String, username: String) throws -> String? {
        if let account = keychainAccount(host: host, username: username),
           let password = try KeychainHelper.loadPassword(service: service, account: account) {
            return password
        }

        guard let legacyAccount = legacyKeychainAccount(host: host) else {
            return nil
        }

        guard let password = try KeychainHelper.loadPassword(service: service, account: legacyAccount) else {
            return nil
        }

        if let account = keychainAccount(host: host, username: username) {
            try KeychainHelper.savePassword(password, service: service, account: account)
        }

        return password
    }

    private static func keychainAccount(host: String, username: String) -> String? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, !trimmedUsername.isEmpty else { return nil }
        return "\(trimmedUsername)@\(trimmedHost)"
    }

    private static func legacyKeychainAccount(host: String) -> String? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedHost.isEmpty ? nil : trimmedHost
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
