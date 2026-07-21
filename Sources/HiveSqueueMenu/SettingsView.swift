import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: UserSettings
    @State private var availableKeys: [SSHKeyOption] = []
    @State private var isTestingConnection = false
    @State private var diagnostic: ConnectionDiagnostic?

    var body: some View {
        Form {
            Section("Cluster") {
                TextField("Host", text: $settings.host)
                    .textContentType(.URL)
                TextField("Username", text: $settings.username)
                    .textContentType(.username)
                Picker("Cluster Profile", selection: $settings.clusterProfile) {
                    ForEach(ClusterProfile.allCases) { profile in
                        Text(profile.label).tag(profile)
                    }
                }
                Text("The profile controls remote shell and module initialization. Standard Slurm performs no module bootstrap.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Authentication") {
                Picker("Auth Mode", selection: $settings.authenticationMode) {
                    ForEach(SSHAuthenticationMode.allCases) { mode in
                        Text(mode.label).tag(mode)
                    }
                }

                if settings.authenticationMode == .key {
                    Picker("SSH Key", selection: $settings.identityFilePath) {
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

                    TextField("Custom Key Path", text: $settings.identityFilePath)
                        .textContentType(.none)
                }

                if settings.authenticationMode == .passwordOnly || settings.authenticationMode == .key {
                    SecureField(passwordLabel, text: $settings.password)
                    Text(passwordHelpText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("SSH Agent mode ignores the stored password and relies on your local agent/session.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if let issue = settings.persistenceIssue {
                    Label(issue, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }

            Section("Remote Command") {
                TextField("Command", text: $settings.remoteCommand, axis: .vertical)
                    .lineLimit(2...4)
                    .textContentType(.none)
                Text("Defaults to squeue --me --json. Override this if HIVE needs a different wrapper or module path.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section("Diagnostics") {
                Button {
                    runConnectionTest()
                } label: {
                    if isTestingConnection {
                        Label("Testing…", systemImage: "hourglass")
                    } else {
                        Label("Test Connection", systemImage: "network")
                    }
                }
                .disabled(isTestingConnection)

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
        .frame(minWidth: 520, minHeight: 560)
        .onAppear(perform: reloadKeys)
    }

    private var customKeyTag: String? {
        let current = settings.identityFilePath
        guard !current.isEmpty else { return nil }
        let matchesKnownKey = availableKeys.contains { $0.path == current }
        return matchesKnownKey ? nil : current
    }

    private var passwordLabel: String {
        switch settings.authenticationMode {
        case .passwordOnly:
            return "Password"
        case .key:
            return "Key Passphrase / Password"
        case .agent:
            return "Password"
        }
    }

    private var passwordHelpText: String {
        switch settings.authenticationMode {
        case .passwordOnly:
            return "Stored in the macOS Keychain and sent to ssh via askpass."
        case .key:
            return "Optional. Use this if the selected SSH key needs a passphrase."
        case .agent:
            return ""
        }
    }

    private func reloadKeys() {
        availableKeys = SSHKeyLibrary.availableKeys()
    }

    private func runConnectionTest() {
        diagnostic = nil
        isTestingConnection = true

        Task {
            let result = await settings.testConnection()
            await MainActor.run {
                diagnostic = result
                isTestingConnection = false
            }
        }
    }

    private func diagnosticColor(for diagnostic: ConnectionDiagnostic) -> Color {
        if diagnostic.isSuccess {
            return .green
        }

        switch diagnostic.kind {
        case .sshAuthenticationFailed:
            return .orange
        case .remoteCommandMissing:
            return .yellow
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
        return trimmed.isEmpty ? "No output." : trimmed
    }
}
