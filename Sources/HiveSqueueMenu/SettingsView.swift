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

                
                SecureField("Password (optional)", text: $settings.password)
                Text("Enter either your SSH key passphrase or server password. Stored securely in macOS Keychain. Leave empty for passphrase-less keys.")
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
