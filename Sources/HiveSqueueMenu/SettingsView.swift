import SwiftUI

private struct KeyCredentialLoadRequest: Hashable {
    let identity: String
    let generation: Int
}

struct SettingsView: View {
    @ObservedObject var settings: UserSettings
    @State private var draft = ConnectionSettingsDraft.empty
    @State private var availableKeys: [SSHKeyOption] = []
    @State private var hasLoadedDraft = false
    @State private var isApplying = false
    @State private var isTestingConnection = false
    @State private var diagnostic: ConnectionDiagnostic?
    @State private var diagnosticTask: Task<Void, Never>?
    @State private var diagnosticCancellationToken: SSHCancellationToken?
    @State private var loadedKeyCredentialIdentity: String?
    @State private var keyCredentialLoadGeneration = 0
    @State private var keyCredentialLoadFailed = false

    var body: some View {
        Form {
            Section("Cluster") {
                TextField("Host", text: hostBinding)
                    .textContentType(.URL)
                TextField("Username", text: usernameBinding)
                    .textContentType(.username)
                Picker("Cluster Profile", selection: $draft.clusterProfile) {
                    ForEach(ClusterProfile.allCases) { profile in
                        Text(profile.label).tag(profile)
                    }
                }
                Text("The profile controls remote shell and module initialization. Standard Slurm performs no module bootstrap.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Host Verification") {
                Picker("New Host Policy", selection: $draft.hostTrustPolicy) {
                    ForEach(SSHHostTrustPolicy.allCases) { policy in
                        Text(policy.label).tag(policy)
                    }
                }

                if draft.hostTrustPolicy == .strict {
                    Text("Unknown hosts are rejected. Verify the cluster fingerprint with its administrator and connect once in Terminal to add it to known_hosts.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Label(
                        "This accepts the first key without fingerprint verification and records it in an isolated app trust store. It cannot authorize Password Only later.",
                        systemImage: "exclamationmark.shield.fill"
                    )
                    .font(.footnote)
                    .foregroundStyle(.orange)
                }
            }

            Section("Authentication") {
                Picker("Auth Mode", selection: authenticationModeBinding) {
                    ForEach(SSHAuthenticationMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }

                if draft.authenticationMode == .key {
                    Picker("SSH Key", selection: identityFileBinding) {
                        Text("Select a key…").tag("")
                        ForEach(availableKeys) { option in
                            Text(option.name).tag(option.path)
                        }
                        if let customKeyTag {
                            Text("Custom: \(customKeyTag)").tag(customKeyTag)
                        }
                    }

                    Button("Rescan Keys", action: reloadKeys)
                        .buttonStyle(.borderless)

                    TextField("Custom Key Path", text: identityFileBinding)
                        .textContentType(.none)

                    SecureField("Private Key Passphrase (Optional)", text: keyPassphraseBinding)
                    Text("The passphrase only unlocks this local key. Password and keyboard-interactive fallback are disabled in key mode.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    if isKeyCredentialLoadPending {
                        if keyCredentialLoadFailed {
                            HStack(spacing: 8) {
                                Label("The saved passphrase could not be loaded.", systemImage: "exclamationmark.triangle.fill")
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                                Button("Retry") {
                                    keyCredentialLoadFailed = false
                                    keyCredentialLoadGeneration &+= 1
                                }
                                .buttonStyle(.borderless)
                            }
                        } else {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text("Loading the saved passphrase for this key…")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } else if draft.authenticationMode == .passwordOnly {
                    SecureField("Account Password", text: $draft.accountPassword)
                    Text("Stored for this exact username and host in the macOS Keychain.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("SSH Agent mode ignores stored passwords and relies on your local agent/session.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Remote Command") {
                TextField("Command", text: $draft.remoteCommand, axis: .vertical)
                    .lineLimit(2...4)
                    .textContentType(.none)
                Text("Defaults to squeue --me --json. Advanced overrides execute as shell text on the configured remote account.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Apply Settings") {
                if let validationIssue {
                    Label(validationIssue, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }

                if let issue = settings.persistenceIssue {
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }

                HStack {
                    Button("Revert") {
                        draft = settings.draft
                        keyCredentialLoadGeneration &+= 1
                        keyCredentialLoadFailed = false
                        loadedKeyCredentialIdentity = draft.authenticationMode == .key
                            && settings.activeCredentialLoadSucceeded
                            ? draft.keyCredentialIdentity
                            : nil
                        diagnostic = nil
                    }
                    .disabled(isApplying || !isDirty)

                    Spacer()

                    Button {
                        applyDraft()
                    } label: {
                        Label(isApplying ? "Applying…" : "Apply", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isApplying || !isDirty || validationIssue != nil || isKeyCredentialLoadPending)
                }
            }

            Section("Diagnostics") {
                Button {
                    runConnectionTest()
                } label: {
                    Label(isTestingConnection ? "Testing…" : "Test Draft Connection", systemImage: "network")
                }
                .disabled(isTestingConnection || validationIssue != nil || isKeyCredentialLoadPending)

                if let diagnostic {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(diagnostic.summary)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(diagnosticColor(for: diagnostic))

                        DiagnosticPane(title: "Raw stderr", text: diagnostic.stderr)
                        DiagnosticPane(title: "Stdout Preview", text: diagnostic.stdout)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(minWidth: 560, minHeight: 640)
        .disabled(isApplying)
        .onAppear {
            if !hasLoadedDraft {
                draft = settings.draft
                loadedKeyCredentialIdentity = draft.authenticationMode == .key
                    && settings.activeCredentialLoadSucceeded
                    ? draft.keyCredentialIdentity
                    : nil
                hasLoadedDraft = true
            }
            reloadKeys()
        }
        .onDisappear {
            invalidateDiagnostic()
        }
        .onChange(of: draft) { _, _ in
            invalidateDiagnostic()
        }
        .task(id: accountCredentialLoadID) {
            await loadAccountCredentialIfNeeded()
        }
        .task(id: keyCredentialLoadID) {
            await loadKeyCredentialIfNeeded()
        }
    }

    private var hostBinding: Binding<String> {
        Binding(
            get: { draft.host },
            set: { value in
                guard value != draft.host else { return }
                let previousIdentity = draft.accountCredentialIdentity
                draft.host = value
                if draft.accountCredentialIdentity != previousIdentity {
                    draft.accountPassword = ""
                }
                diagnostic = nil
            }
        )
    }

    private var usernameBinding: Binding<String> {
        Binding(
            get: { draft.username },
            set: { value in
                guard value != draft.username else { return }
                let previousIdentity = draft.accountCredentialIdentity
                draft.username = value
                if draft.accountCredentialIdentity != previousIdentity {
                    draft.accountPassword = ""
                }
                diagnostic = nil
            }
        )
    }

    private var identityFileBinding: Binding<String> {
        Binding(
            get: { draft.identityFilePath },
            set: { value in
                guard value != draft.identityFilePath else { return }
                let previousIdentity = draft.keyCredentialIdentity
                draft.identityFilePath = value
                if draft.keyCredentialIdentity != previousIdentity {
                    draft.keyPassphrase = ""
                    loadedKeyCredentialIdentity = nil
                    keyCredentialLoadFailed = false
                    keyCredentialLoadGeneration &+= 1
                }
                diagnostic = nil
            }
        )
    }

    private var authenticationModeBinding: Binding<SSHAuthenticationMode> {
        Binding(
            get: { draft.authenticationMode },
            set: { value in
                guard value != draft.authenticationMode else { return }
                draft.authenticationMode = value
                keyCredentialLoadFailed = false
                keyCredentialLoadGeneration &+= 1
                diagnostic = nil
            }
        )
    }

    private var keyPassphraseBinding: Binding<String> {
        Binding(
            get: { draft.keyPassphrase },
            set: { value in
                // Invalidate any in-flight Keychain read before recording the
                // user's choice, including an intentional empty passphrase.
                keyCredentialLoadGeneration &+= 1
                draft.keyPassphrase = value
                loadedKeyCredentialIdentity = draft.keyCredentialIdentity
                keyCredentialLoadFailed = false
                diagnostic = nil
            }
        )
    }

    private var customKeyTag: String? {
        let current = draft.identityFilePath
        guard !current.isEmpty else { return nil }
        let matchesKnownKey = availableKeys.contains { $0.path == current }
        return matchesKnownKey ? nil : current
    }

    private var isDirty: Bool {
        draft != settings.draft
    }

    private var validationIssue: String? {
        draft.connectionSettings.configurationIssue
    }

    private var accountCredentialLoadID: String? {
        guard hasLoadedDraft, draft.authenticationMode == .passwordOnly else { return nil }
        return draft.accountCredentialIdentity
    }

    private var keyCredentialLoadID: KeyCredentialLoadRequest? {
        guard hasLoadedDraft,
              draft.authenticationMode == .key,
              let identity = draft.keyCredentialIdentity else { return nil }
        return KeyCredentialLoadRequest(
            identity: identity,
            generation: keyCredentialLoadGeneration
        )
    }

    private var isKeyCredentialLoadPending: Bool {
        guard draft.authenticationMode == .key,
              draft.keyPassphrase.isEmpty,
              let identity = draft.keyCredentialIdentity else { return false }
        return loadedKeyCredentialIdentity != identity
    }

    private func reloadKeys() {
        availableKeys = SSHKeyLibrary.availableKeys()
    }

    private func applyDraft() {
        invalidateDiagnostic()
        isApplying = true
        let draftToApply = draft
        Task {
            let applied = await settings.apply(draftToApply)
            if applied {
                draft = settings.draft
                keyCredentialLoadGeneration &+= 1
                keyCredentialLoadFailed = false
                loadedKeyCredentialIdentity = draft.authenticationMode == .key
                    ? draft.keyCredentialIdentity
                    : nil
            }
            isApplying = false
        }
    }

    private func runConnectionTest() {
        invalidateDiagnostic()
        isTestingConnection = true
        let token = SSHCancellationToken()
        diagnosticCancellationToken = token
        let draftToTest = draft

        diagnosticTask = Task {
            let result = await settings.testConnection(using: draftToTest, cancellationToken: token)
            guard !Task.isCancelled else { return }
            diagnostic = result
            isTestingConnection = false
            diagnosticTask = nil
            diagnosticCancellationToken = nil
        }
    }

    private func loadAccountCredentialIfNeeded() async {
        guard draft.accountPassword.isEmpty,
              let identity = accountCredentialLoadID else { return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled,
              identity == accountCredentialLoadID,
              draft.accountPassword.isEmpty else { return }
        let result = await settings.loadSavedAccountPassword(identity: identity)
        guard !Task.isCancelled,
              identity == accountCredentialLoadID,
              draft.accountPassword.isEmpty else { return }
        settings.recordCredentialLoadResult(result)
        if case .loaded(let stored) = result {
            draft.accountPassword = stored ?? ""
        }
    }

    private func loadKeyCredentialIfNeeded() async {
        guard draft.keyPassphrase.isEmpty,
              let request = keyCredentialLoadID,
              loadedKeyCredentialIdentity != request.identity else { return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled,
              request == keyCredentialLoadID,
              loadedKeyCredentialIdentity != request.identity,
              draft.keyPassphrase.isEmpty else { return }
        let result = await settings.loadSavedKeyPassphrase(identity: request.identity)
        guard !Task.isCancelled,
              request == keyCredentialLoadID,
              loadedKeyCredentialIdentity != request.identity,
              draft.keyPassphrase.isEmpty else { return }
        settings.recordCredentialLoadResult(result)
        switch result {
        case .loaded(let stored):
            draft.keyPassphrase = stored ?? ""
            loadedKeyCredentialIdentity = request.identity
            keyCredentialLoadFailed = false
        case .failed:
            keyCredentialLoadFailed = true
        }
    }

    private func invalidateDiagnostic() {
        diagnosticTask?.cancel()
        diagnosticCancellationToken?.cancel()
        diagnosticTask = nil
        diagnosticCancellationToken = nil
        isTestingConnection = false
        diagnostic = nil
    }

    private func diagnosticColor(for diagnostic: ConnectionDiagnostic) -> Color {
        if diagnostic.isSuccess {
            return .green
        }

        switch diagnostic.kind {
        case .sshAuthenticationFailed:
            return .orange
        case .remoteCommandMissing:
            return .primary
        case .invalidResponse:
            return .blue
        case .notConfigured:
            return .secondary
        case .transportFailure:
            return .red
        case nil:
            return .primary
        }
    }
}

private struct DiagnosticPane: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            ScrollView {
                Text(displayText)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 90, maxHeight: 150)
            .padding(10)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private var displayText: String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "No output." }
        let limit = 20_000
        guard trimmed.count > limit else { return trimmed }
        return String(trimmed.prefix(limit)) + "\n… output truncated …"
    }
}
