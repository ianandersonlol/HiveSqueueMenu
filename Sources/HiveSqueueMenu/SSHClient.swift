import Foundation

struct SSHClient {
    let connection: ConnectionSettings
    private let sshPath: String

    init(connection: ConnectionSettings, sshPath: String = AppConfig.sshPath) {
        self.connection = connection
        self.sshPath = sshPath
    }

    func runCommand(_ command: String) throws -> Data {
        print("[SSHClient] runCommand starting...")
        print("[SSHClient] Connection: \(connection.username)@\(connection.host)")
        print("[SSHClient] Identity file: \(connection.identityFilePath ?? "none")")
        print("[SSHClient] Has password: \(connection.password != nil && !connection.password!.isEmpty)")

        guard FileManager.default.isExecutableFile(atPath: sshPath) else {
            print("[SSHClient] ERROR: SSH not found at \(sshPath)")
            throw SSHClientError.sshUnavailable(sshPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = makeArguments(for: command)
        print("[SSHClient] SSH args: \(process.arguments ?? [])")

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        var askPassURL: URL?
        var environment = ProcessInfo.processInfo.environment
        if let password = connection.password, !password.isEmpty {
            askPassURL = try generateAskPassScript(for: password)
            environment["DISPLAY"] = environment["DISPLAY"] ?? "HiveSqueueMenu"
            environment["SSH_ASKPASS"] = askPassURL?.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
        }

        if !environment.isEmpty {
            process.environment = environment
        }

        do {
            print("[SSHClient] Launching SSH process...")
            try process.run()
            print("[SSHClient] SSH process started, waiting for completion...")
        } catch {
            print("[SSHClient] ERROR: Failed to launch SSH - \(error.localizedDescription)")
            throw SSHClientError.unableToLaunch(error.localizedDescription)
        }

        process.waitUntilExit()
        print("[SSHClient] SSH process exited with status: \(process.terminationStatus)")
        if let askPassURL {
            try? FileManager.default.removeItem(at: askPassURL)
        }

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            print("[SSHClient] ERROR: SSH failed - \(message ?? "no error message")")
            throw SSHClientError.commandFailed(message ?? "ssh exited with code \(process.terminationStatus)")
        }

        print("[SSHClient] SSH completed successfully, got \(output.count) bytes")
        return output
    }

    private func makeArguments(for command: String) -> [String] {
        var arguments: [String] = []

        // Disable strict host key checking to avoid interactive prompts
        arguments.append(contentsOf: ["-o", "StrictHostKeyChecking=no"])
        arguments.append(contentsOf: ["-o", "UserKnownHostsFile=/dev/null"])

        // Only use BatchMode if we don't have a password (for passphrase-less keys)
        // If we have a password, it could be for key passphrase or server auth
        if connection.password == nil || connection.password!.isEmpty {
            arguments.append(contentsOf: ["-o", "BatchMode=yes"])
        }

        if let identity = connection.identityFilePath?.expandingTilde {
            arguments.append(contentsOf: ["-i", identity])
        }

        let destination: String
        if connection.username.isEmpty {
            destination = connection.host
        } else {
            destination = "\(connection.username)@\(connection.host)"
        }

        arguments.append(destination)
        // Run command directly - squeue should have full path in AppConfig
        arguments.append(command)
        return arguments
    }

    private func generateAskPassScript(for password: String) throws -> URL {
        let scriptURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HiveSqueueMenu-askpass-\(UUID().uuidString)")
        let escapedPassword = password
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        #!/bin/sh
        /bin/echo "\(escapedPassword)"
        """
        guard let data = script.data(using: .utf8) else {
            throw SSHClientError.unableToLaunch("Unable to encode password for askpass.")
        }
        try data.write(to: scriptURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: scriptURL.path)
        return scriptURL
    }
}

enum SSHClientError: LocalizedError {
    case sshUnavailable(String)
    case unableToLaunch(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .sshUnavailable(let path):
            return "SSH client missing at \(path)."
        case .unableToLaunch(let reason):
            return "Unable to launch ssh: \(reason)"
        case .commandFailed(let message):
            return "ssh failed: \(message)"
        }
    }
}

private extension String {
    var expandingTilde: String {
        (self as NSString).expandingTildeInPath
    }
}
