import Foundation

enum CredentialLoadResult: Equatable, Sendable {
    case loaded(String?)
    case failed(String)
}

@MainActor
final class UserSettings: ObservableObject {
    private enum Keys {
        static let host = "sshHost"
        static let username = "sshUsername"
        static let clusterProfile = "clusterProfile"
        static let authenticationMode = "sshAuthenticationMode"
        static let identityFilePath = "sshIdentityFilePath"
        static let hostTrustPolicy = "sshHostTrustPolicy"
        static let remoteCommand = "remoteCommand"
    }

    nonisolated private static let keychainService = "HiveSqueueMenu"
    nonisolated private static let accountPasswordPrefix = "account-password:"
    nonisolated private static let keyPassphrasePrefix = "key-passphrase:"

    private let defaults: UserDefaults
    private let credentialStore: any CredentialStoring

    @Published private(set) var host: String
    @Published private(set) var username: String
    @Published private(set) var clusterProfile: ClusterProfile
    @Published private(set) var authenticationMode: SSHAuthenticationMode
    @Published private(set) var identityFilePath: String
    @Published private(set) var hostTrustPolicy: SSHHostTrustPolicy
    @Published private(set) var remoteCommand: String
    @Published private(set) var accountPassword: String
    @Published private(set) var keyPassphrase: String
    @Published private(set) var connectionSettings: ConnectionSettings
    @Published private(set) var persistenceIssue: String?
    private(set) var activeCredentialLoadSucceeded: Bool

    init(
        defaults: UserDefaults = UserDefaults(suiteName: AppConfig.defaultsSuiteName) ?? .standard,
        credentialStore: any CredentialStoring = KeychainCredentialStore()
    ) {
        self.defaults = defaults
        self.credentialStore = credentialStore

        let storedHost = defaults.string(forKey: Keys.host)?.nonEmpty ?? AppConfig.clusterHost
        let storedUsername = defaults.string(forKey: Keys.username)?.nonEmpty ?? ""
        let storedClusterProfile = defaults.string(forKey: Keys.clusterProfile)
            .flatMap(ClusterProfile.init(rawValue:))
            ?? ClusterProfile.inferred(forHost: storedHost)
        let storedIdentity = defaults.string(forKey: Keys.identityFilePath)?.nonEmpty ?? ""
        let storedTrustPolicy = defaults.string(forKey: Keys.hostTrustPolicy)
            .flatMap(SSHHostTrustPolicy.init(rawValue:))
            ?? .strict
        let storedRemoteCommand = defaults.string(forKey: Keys.remoteCommand)?.nonEmpty ?? AppConfig.remoteCommand

        let legacySecret: String?
        let legacyAccount: String?
        let legacyLoadIssue: String?
        do {
            let legacy = try Self.loadLegacySecret(
                store: credentialStore,
                host: storedHost,
                username: storedUsername
            )
            legacySecret = legacy.secret
            legacyAccount = legacy.account
            legacyLoadIssue = nil
        } catch {
            legacySecret = nil
            legacyAccount = nil
            legacyLoadIssue = "Credentials could not be loaded from Keychain: \(error.localizedDescription)"
        }

        let storedMode = Self.storedAuthenticationMode(
            defaults: defaults,
            identityFilePath: storedIdentity.nonEmpty,
            hasLegacySecret: legacySecret?.isEmpty == false
        )

        var loadedAccountPassword = ""
        var loadedKeyPassphrase = ""
        var loadIssue = legacyLoadIssue
        var didLoadActiveCredential = true
        do {
            switch storedMode {
            case .passwordOnly:
                if let identity = Self.accountIdentity(host: storedHost, username: storedUsername) {
                    let account = Self.accountPasswordAccount(identity: identity)
                    if let stored = try credentialStore.load(service: Self.keychainService, account: account) {
                        loadedAccountPassword = stored
                        if let legacyAccount {
                            try credentialStore.delete(service: Self.keychainService, account: legacyAccount)
                        }
                    } else if let legacySecret, let legacyAccount {
                        try credentialStore.save(legacySecret, service: Self.keychainService, account: account)
                        loadedAccountPassword = legacySecret
                        try credentialStore.delete(service: Self.keychainService, account: legacyAccount)
                    }
                }
            case .key:
                if let identity = Self.keyIdentity(path: storedIdentity) {
                    let account = Self.keyPassphraseAccount(identity: identity)
                    if let stored = try credentialStore.load(service: Self.keychainService, account: account) {
                        loadedKeyPassphrase = stored
                        if let legacyAccount {
                            try credentialStore.delete(service: Self.keychainService, account: legacyAccount)
                        }
                    } else if let legacySecret, let legacyAccount {
                        try credentialStore.save(legacySecret, service: Self.keychainService, account: account)
                        loadedKeyPassphrase = legacySecret
                        try credentialStore.delete(service: Self.keychainService, account: legacyAccount)
                    }
                }
            case .agent:
                if let legacySecret, let legacyAccount {
                    let destinationAccount: String?
                    if let identity = Self.keyIdentity(path: storedIdentity) {
                        destinationAccount = Self.keyPassphraseAccount(identity: identity)
                    } else if let identity = Self.accountIdentity(host: storedHost, username: storedUsername) {
                        destinationAccount = Self.accountPasswordAccount(identity: identity)
                    } else {
                        destinationAccount = nil
                    }

                    if let destinationAccount {
                        if try credentialStore.load(
                            service: Self.keychainService,
                            account: destinationAccount
                        ) == nil {
                            try credentialStore.save(
                                legacySecret,
                                service: Self.keychainService,
                                account: destinationAccount
                            )
                        }
                        try credentialStore.delete(
                            service: Self.keychainService,
                            account: legacyAccount
                        )
                    }
                }
            }
        } catch {
            loadIssue = "Credentials could not be loaded from Keychain: \(error.localizedDescription)"
            if storedMode != .agent {
                didLoadActiveCredential = false
            }
        }

        let initialConnection = ConnectionSettings(
            host: storedHost,
            username: storedUsername,
            clusterProfile: storedClusterProfile,
            authentication: Self.makeAuthentication(mode: storedMode, identityFilePath: storedIdentity),
            hostTrustPolicy: storedTrustPolicy,
            accountPassword: loadedAccountPassword.nonEmpty,
            keyPassphrase: loadedKeyPassphrase.nonEmpty,
            remoteCommand: storedRemoteCommand
        )

        host = storedHost
        username = storedUsername
        clusterProfile = storedClusterProfile
        authenticationMode = storedMode
        identityFilePath = storedIdentity
        hostTrustPolicy = storedTrustPolicy
        remoteCommand = storedRemoteCommand
        accountPassword = loadedAccountPassword
        keyPassphrase = loadedKeyPassphrase
        connectionSettings = initialConnection
        persistenceIssue = loadIssue
        activeCredentialLoadSucceeded = didLoadActiveCredential
    }

    var draft: ConnectionSettingsDraft {
        var current = ConnectionSettingsDraft(connection: connectionSettings)
        current.host = host
        current.username = username
        current.clusterProfile = clusterProfile
        current.authenticationMode = authenticationMode
        current.identityFilePath = identityFilePath
        current.hostTrustPolicy = hostTrustPolicy
        current.accountPassword = accountPassword
        current.keyPassphrase = keyPassphrase
        current.remoteCommand = remoteCommand
        return current
    }

    @discardableResult
    func apply(_ draft: ConnectionSettingsDraft) async -> Bool {
        let candidate = draft.connectionSettings
        if let issue = candidate.configurationIssue {
            persistenceIssue = issue
            return false
        }

        let store = credentialStore
        let accountIdentity = draft.accountCredentialIdentity
        let keyIdentity = draft.keyCredentialIdentity
        let authenticationMode = draft.authenticationMode
        let accountPassword = draft.accountPassword
        let keyPassphrase = draft.keyPassphrase

        let persistenceError = await Task.detached(priority: .utility) { () -> String? in
            do {
                switch authenticationMode {
                case .agent:
                    break
                case .passwordOnly:
                    guard let accountIdentity else {
                        return "A host and username are required before saving a password."
                    }
                    let account = Self.accountPasswordAccount(identity: accountIdentity)
                    if accountPassword.isEmpty {
                        try store.delete(service: Self.keychainService, account: account)
                    } else {
                        try store.save(accountPassword, service: Self.keychainService, account: account)
                    }
                case .key:
                    guard let keyIdentity else {
                        return "Select an SSH key before saving its passphrase."
                    }
                    let account = Self.keyPassphraseAccount(identity: keyIdentity)
                    if keyPassphrase.isEmpty {
                        try store.delete(service: Self.keychainService, account: account)
                    } else {
                        try store.save(keyPassphrase, service: Self.keychainService, account: account)
                    }
                }
                return nil
            } catch {
                return error.localizedDescription
            }
        }.value

        if let persistenceError {
            persistenceIssue = "Credentials could not be saved in Keychain: \(persistenceError)"
            return false
        }

        defaults.set(draft.host, forKey: Keys.host)
        defaults.set(draft.username, forKey: Keys.username)
        defaults.set(draft.clusterProfile.rawValue, forKey: Keys.clusterProfile)
        defaults.set(draft.authenticationMode.rawValue, forKey: Keys.authenticationMode)
        defaults.set(draft.identityFilePath, forKey: Keys.identityFilePath)
        defaults.set(draft.hostTrustPolicy.rawValue, forKey: Keys.hostTrustPolicy)
        defaults.set(draft.remoteCommand, forKey: Keys.remoteCommand)

        host = draft.host
        username = draft.username
        clusterProfile = draft.clusterProfile
        self.authenticationMode = draft.authenticationMode
        identityFilePath = draft.identityFilePath
        hostTrustPolicy = draft.hostTrustPolicy
        remoteCommand = draft.remoteCommand
        self.accountPassword = candidate.accountPassword ?? ""
        self.keyPassphrase = candidate.keyPassphrase ?? ""
        connectionSettings = candidate
        persistenceIssue = nil
        activeCredentialLoadSucceeded = true
        return true
    }

    func loadSavedAccountPassword(identity: String) async -> CredentialLoadResult {
        await loadCredential(account: Self.accountPasswordAccount(identity: identity))
    }

    func loadSavedKeyPassphrase(identity: String) async -> CredentialLoadResult {
        await loadCredential(account: Self.keyPassphraseAccount(identity: identity))
    }

    func recordCredentialLoadResult(_ result: CredentialLoadResult) {
        switch result {
        case .loaded:
            persistenceIssue = nil
        case .failed(let message):
            persistenceIssue = message
        }
    }

    func testConnection(
        using draft: ConnectionSettingsDraft? = nil,
        cancellationToken: SSHCancellationToken = SSHCancellationToken()
    ) async -> ConnectionDiagnostic {
        let settings = draft?.connectionSettings ?? connectionSettings
        return await Task.detached(priority: .utility) {
            SlurmService(
                connection: settings,
                cancellationToken: cancellationToken
            ).diagnoseConnection()
        }.value
    }

    private func loadCredential(account: String) async -> CredentialLoadResult {
        let store = credentialStore
        do {
            let secret = try await Task.detached(priority: .utility) {
                try store.load(service: Self.keychainService, account: account)
            }.value
            return .loaded(secret)
        } catch {
            let message = "Credentials could not be loaded from Keychain: \(error.localizedDescription)"
            return .failed(message)
        }
    }

    private static func storedAuthenticationMode(
        defaults: UserDefaults,
        identityFilePath: String?,
        hasLegacySecret: Bool
    ) -> SSHAuthenticationMode {
        if let rawMode = defaults.string(forKey: Keys.authenticationMode),
           let mode = SSHAuthenticationMode(rawValue: rawMode) {
            return mode
        }
        if identityFilePath != nil {
            return .key
        }
        return hasLegacySecret ? .passwordOnly : .agent
    }

    private static func makeAuthentication(
        mode: SSHAuthenticationMode,
        identityFilePath: String
    ) -> SSHAuthentication {
        switch mode {
        case .agent:
            return .agent
        case .key:
            return .key(path: identityFilePath.trimmingCharacters(in: .whitespacesAndNewlines))
        case .passwordOnly:
            return .passwordOnly
        }
    }

    private static func accountIdentity(host: String, username: String) -> String? {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, !trimmedUsername.isEmpty else { return nil }
        return "\(trimmedUsername)@\(trimmedHost)"
    }

    private static func keyIdentity(path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (trimmed as NSString).expandingTildeInPath
    }

    nonisolated private static func accountPasswordAccount(identity: String) -> String {
        accountPasswordPrefix + identity
    }

    nonisolated private static func keyPassphraseAccount(identity: String) -> String {
        keyPassphrasePrefix + identity
    }

    private static func loadLegacySecret(
        store: any CredentialStoring,
        host: String,
        username: String
    ) throws -> (secret: String?, account: String?) {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedHost.isEmpty, !trimmedUsername.isEmpty {
            let legacyExactAccount = "\(trimmedUsername)@\(trimmedHost)"
            let normalizedExactAccount = accountIdentity(host: host, username: username)
            var candidates = [legacyExactAccount]
            if let normalizedExactAccount, normalizedExactAccount != legacyExactAccount {
                candidates.append(normalizedExactAccount)
            }

            for account in candidates {
                if let secret = try store.load(service: keychainService, account: account) {
                    return (secret, account)
                }
            }
        }

        guard !trimmedHost.isEmpty,
              let secret = try store.load(service: keychainService, account: trimmedHost) else {
            return (nil, nil)
        }
        return (secret, trimmedHost)
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : self
    }
}
