import Foundation
import Testing
@testable import HiveSqueueMenu

@Suite("Transactional connection settings")
@MainActor
struct UserSettingsTests {
    @Test
    func editingDraftDoesNotPublishMixedIdentityAndCredential() async {
        let fixture = makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let settings = UserSettings(defaults: fixture.defaults, credentialStore: fixture.store)

        var original = settings.draft
        original.host = "old.example"
        original.username = "alice"
        original.authenticationMode = .passwordOnly
        original.accountPassword = "old-secret"
        #expect(await settings.apply(original))

        var editing = settings.draft
        editing.host = "new.example"
        editing.accountPassword = ""

        #expect(settings.connectionSettings.host == "old.example")
        #expect(settings.connectionSettings.accountPassword == "old-secret")
        #expect(editing.connectionSettings.host == "new.example")
        #expect(editing.connectionSettings.accountPassword == nil)
        #expect(await settings.loadSavedAccountPassword(identity: "alice@new.example") == .loaded(nil))
    }

    @Test
    func applyPublishesOneCompleteCredentialSnapshot() async {
        let fixture = makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let settings = UserSettings(defaults: fixture.defaults, credentialStore: fixture.store)

        var draft = settings.draft
        draft.host = "cluster.example"
        draft.username = "alice"
        draft.authenticationMode = .passwordOnly
        draft.accountPassword = "account-secret"

        #expect(await settings.apply(draft))
        #expect(settings.connectionSettings.trimmedHost == "cluster.example")
        #expect(settings.connectionSettings.trimmedUsername == "alice")
        #expect(settings.connectionSettings.accountPassword == "account-secret")
        #expect(await settings.loadSavedAccountPassword(identity: "alice@cluster.example") == .loaded("account-secret"))
    }

    @Test
    func failedCredentialPersistenceDoesNotPublishTheDraft() async {
        let suiteName = "HiveSqueueMenuTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = UserSettings(defaults: defaults, credentialStore: FailingCredentialStore())
        let original = settings.connectionSettings

        var draft = settings.draft
        draft.host = "cluster.example"
        draft.username = "alice"
        draft.authenticationMode = .passwordOnly
        draft.accountPassword = "must-not-publish"

        #expect(!(await settings.apply(draft)))
        #expect(settings.connectionSettings == original)
        #expect(settings.persistenceIssue?.contains("Keychain") == true)
    }

    @Test
    func keyAndAccountSecretsNeverShareAnActiveConnection() {
        var draft = ConnectionSettingsDraft.empty
        draft.host = "cluster.example"
        draft.username = "alice"
        draft.identityFilePath = "/tmp/id_test"
        draft.accountPassword = "remote-password"
        draft.keyPassphrase = "local-passphrase"

        draft.authenticationMode = .key
        #expect(draft.connectionSettings.keyPassphrase == "local-passphrase")
        #expect(draft.connectionSettings.accountPassword == nil)

        draft.authenticationMode = .passwordOnly
        #expect(draft.connectionSettings.accountPassword == "remote-password")
        #expect(draft.connectionSettings.keyPassphrase == nil)
    }

    @Test
    func inactiveKeySelectionRemainsAvailableWithoutKeepingItsSecretActive() async {
        let fixture = makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        let settings = UserSettings(defaults: fixture.defaults, credentialStore: fixture.store)

        var keyDraft = settings.draft
        keyDraft.host = "cluster.example"
        keyDraft.username = "alice"
        keyDraft.authenticationMode = .key
        keyDraft.identityFilePath = "/tmp/id_test"
        keyDraft.keyPassphrase = "local-secret"
        #expect(await settings.apply(keyDraft))

        var agentDraft = settings.draft
        agentDraft.authenticationMode = .agent
        #expect(await settings.apply(agentDraft))

        #expect(settings.connectionSettings.authentication == .agent)
        #expect(settings.connectionSettings.keyPassphrase == nil)
        #expect(settings.draft.identityFilePath == "/tmp/id_test")
        #expect(await settings.loadSavedKeyPassphrase(identity: "/tmp/id_test") == .loaded("local-secret"))
    }

    @Test
    func legacyCredentialMigratesOnceToTheStoredIdentity() async throws {
        let fixture = makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.defaults.set("cluster.example", forKey: "sshHost")
        fixture.defaults.set("alice", forKey: "sshUsername")
        fixture.defaults.set(SSHAuthenticationMode.passwordOnly.rawValue, forKey: "sshAuthenticationMode")
        try fixture.store.save("legacy-secret", service: "HiveSqueueMenu", account: "alice@cluster.example")

        let settings = UserSettings(defaults: fixture.defaults, credentialStore: fixture.store)

        #expect(settings.connectionSettings.accountPassword == "legacy-secret")
        #expect(try fixture.store.load(service: "HiveSqueueMenu", account: "alice@cluster.example") == nil)
        #expect(await settings.loadSavedAccountPassword(identity: "alice@cluster.example") == .loaded("legacy-secret"))
        #expect(await settings.loadSavedAccountPassword(identity: "bob@cluster.example") == .loaded(nil))
    }

    @Test
    func legacyAgentCredentialUsesAccountScopeWhenNoKeyWasSelected() async throws {
        let fixture = makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.defaults.set("Cluster.Example", forKey: "sshHost")
        fixture.defaults.set("alice", forKey: "sshUsername")
        fixture.defaults.set(SSHAuthenticationMode.agent.rawValue, forKey: "sshAuthenticationMode")
        try fixture.store.save("legacy-secret", service: "HiveSqueueMenu", account: "alice@Cluster.Example")

        let settings = UserSettings(defaults: fixture.defaults, credentialStore: fixture.store)

        #expect(settings.connectionSettings.authentication == .agent)
        #expect(settings.connectionSettings.accountPassword == nil)
        #expect(await settings.loadSavedAccountPassword(identity: "alice@cluster.example") == .loaded("legacy-secret"))
        #expect(try fixture.store.load(service: "HiveSqueueMenu", account: "alice@Cluster.Example") == nil)
    }

    @Test
    func ambiguousLegacyAgentCredentialStaysLocalWhenAKeyWasSelected() async throws {
        let fixture = makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
        fixture.defaults.set("cluster.example", forKey: "sshHost")
        fixture.defaults.set("alice", forKey: "sshUsername")
        fixture.defaults.set(SSHAuthenticationMode.agent.rawValue, forKey: "sshAuthenticationMode")
        fixture.defaults.set("/tmp/id_test", forKey: "sshIdentityFilePath")
        try fixture.store.save("legacy-secret", service: "HiveSqueueMenu", account: "alice@cluster.example")

        let settings = UserSettings(defaults: fixture.defaults, credentialStore: fixture.store)

        #expect(settings.connectionSettings.authentication == .agent)
        #expect(await settings.loadSavedKeyPassphrase(identity: "/tmp/id_test") == .loaded("legacy-secret"))
        #expect(await settings.loadSavedAccountPassword(identity: "alice@cluster.example") == .loaded(nil))
    }

    private func makeFixture() -> (
        suiteName: String,
        defaults: UserDefaults,
        store: InMemoryCredentialStore
    ) {
        let suiteName = "HiveSqueueMenuTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (suiteName, defaults, InMemoryCredentialStore())
    }
}

private struct FailingCredentialStore: CredentialStoring {
    struct Failure: Error {}

    func save(_ secret: String, service: String, account: String) throws {
        throw Failure()
    }

    func load(service: String, account: String) throws -> String? {
        throw Failure()
    }

    func delete(service: String, account: String) throws {
        throw Failure()
    }
}

private final class InMemoryCredentialStore: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]

    func save(_ secret: String, service: String, account: String) throws {
        lock.lock()
        secrets[key(service: service, account: account)] = secret
        lock.unlock()
    }

    func load(service: String, account: String) throws -> String? {
        lock.lock()
        let secret = secrets[key(service: service, account: account)]
        lock.unlock()
        return secret
    }

    func delete(service: String, account: String) throws {
        lock.lock()
        secrets.removeValue(forKey: key(service: service, account: account))
        lock.unlock()
    }

    private func key(service: String, account: String) -> String {
        service + "\u{0}" + account
    }
}
