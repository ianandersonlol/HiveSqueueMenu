import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: UserSettings
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
                    if let customKeyTag {
                        Text("Custom: \(customKeyTag)").tag(customKeyTag)
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
    }

    private func reloadKeys() {
        availableKeys = SSHKeyLibrary.availableKeys()
    }

    private var customKeyTag: String? {
        let current = settings.identityFilePath
        guard !current.isEmpty else { return nil }
        let matchesKnownKey = availableKeys.contains { $0.path == current }
        return matchesKnownKey ? nil : current
    }
}

// #Preview {
//     SettingsView(settings: UserSettings())
// }
