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
                }
                Button("Rescan Keys", action: reloadKeys)
                    .buttonStyle(.borderless)
                TextField("Custom Key Path", text: $settings.identityFilePath)

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
    }

    private func reloadKeys() {
        availableKeys = SSHKeyLibrary.availableKeys()
    }
}

#Preview {
    SettingsView(settings: UserSettings())
}
