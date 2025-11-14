import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: UserSettings
    @ObservedObject var monitor: SlurmMonitor
    @State private var availableKeys: [SSHKeyOption] = []

    var body: some View {
        Form {
            Section("Cluster") {
                TextField("Host", text: $settings.host)
                    .textContentType(.URL)
                TextField("Username", text: $settings.username)
                    .textContentType(.username)
            }

            Section("Authentication") {
                Picker("SSH Key", selection: $settings.identityFilePath) {
                    Text("None").tag("")
                    ForEach(availableKeys) { option in
                        Text(option.name).tag(option.path)
                    }
                }
                Button("Rescan Keys", action: reloadKeys)
                    .buttonStyle(.borderless)
                TextField("Custom Key Path", text: $settings.identityFilePath)

                
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text("Security Warning")
                            .font(.headline)
                    }
                    Text("Password authentication is strongly discouraged as it is less secure and may store credentials insecurely. Please use SSH keys whenever possible.")
                        .font(.footnote)
                }
                .padding(10)
                .background(.yellow.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                
                SecureField("Password (stored per-host in Keychain)", text: $settings.password)
                Text("Passwords are stored securely in the macOS Keychain and used via SSH's askpass flow when key-based login is not available.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(minWidth: 400)
        .onAppear(perform: reloadKeys)
        .onChange(of: settings.connectionSettings) { oldValue, newValue in
            print("[SettingsView] Connection settings changed: \(newValue.username)@\(newValue.host), configured: \(newValue.isConfigured)")
            monitor.updateConnection(newValue)
        }
    }

    private func reloadKeys() {
        availableKeys = SSHKeyLibrary.availableKeys()
    }
}

// #Preview {
//     SettingsView(settings: UserSettings())
// }
