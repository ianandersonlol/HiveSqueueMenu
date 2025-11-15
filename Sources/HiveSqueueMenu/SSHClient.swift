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

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        let stderrHandle = stderr.fileHandleForReading
        let stderrBuffer = ThreadSafeDataBuffer()
        stderrHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            stderrBuffer.append(chunk)
            if let text = String(data: chunk, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                print("[SSHClient][stderr] \(text)")
            }
        }

        var askPassURL: URL?
        var environmentOverrides: [String: String] = [:]
        var environment = ProcessInfo.processInfo.environment
        if let password = connection.password, !password.isEmpty {
            askPassURL = try generateAskPassScript(for: password)
            environment["DISPLAY"] = environment["DISPLAY"] ?? "HiveSqueueMenu"
            environment["SSH_ASKPASS"] = askPassURL?.path
            environment["SSH_ASKPASS_REQUIRE"] = "force"
            environmentOverrides["DISPLAY"] = environment["DISPLAY"]
            environmentOverrides["SSH_ASKPASS"] = askPassURL?.lastPathComponent
            environmentOverrides["SSH_ASKPASS_REQUIRE"] = environment["SSH_ASKPASS_REQUIRE"]
            print("[SSHClient] Using askpass script at \(askPassURL!.path)")
        }

        if !environment.isEmpty {
            process.environment = environment
        }
        if !environmentOverrides.isEmpty {
            print("[SSHClient] Environment overrides set: \(environmentOverrides)")
        }

        let timeoutLock = NSLock()
        var timeoutTriggered = false
        let timeoutWorkItem = DispatchWorkItem {
            guard process.isRunning else { return }
            timeoutLock.lock()
            timeoutTriggered = true
            timeoutLock.unlock()
            print("[SSHClient] WARNING: ssh command exceeded \(Int(AppConfig.sshCommandTimeout))s. Terminating process.")
            process.terminate()
        }

        do {
            print("[SSHClient] Launching SSH process...")
            try process.run()
            print("[SSHClient] SSH process started, waiting for completion...")
            if let stdinPipe = process.standardInput as? Pipe {
                stdinPipe.fileHandleForWriting.closeFile()
            }
            DispatchQueue.global().asyncAfter(
                deadline: .now() + AppConfig.sshCommandTimeout,
                execute: timeoutWorkItem
            )
        } catch {
            print("[SSHClient] ERROR: Failed to launch SSH - \(error.localizedDescription)")
            stderrHandle.readabilityHandler = nil
            throw SSHClientError.unableToLaunch(error.localizedDescription)
        }

        let waitStart = Date()
        process.waitUntilExit()
        timeoutWorkItem.cancel()
        stderrHandle.readabilityHandler = nil
        let remainingStderr = stderr.fileHandleForReading.readDataToEndOfFile()
        if !remainingStderr.isEmpty {
            stderrBuffer.append(remainingStderr)
            if let text = String(data: remainingStderr, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !text.isEmpty {
                print("[SSHClient][stderr] \(text)")
            }
        }
        let waitDuration = Date().timeIntervalSince(waitStart)
        print("[SSHClient] SSH process exited with status: \(process.terminationStatus) after \(String(format: "%.2f", waitDuration))s")
        if let askPassURL {
            try? FileManager.default.removeItem(at: askPassURL)
            print("[SSHClient] Cleaned up askpass script")
        }

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        var timedOut = false
        timeoutLock.lock()
        timedOut = timeoutTriggered
        timeoutLock.unlock()
        if process.terminationStatus != 0 {
            let message = String(data: stderrBuffer.snapshot(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let defaultMessage: String
            if timedOut {
                defaultMessage = "ssh command timed out after \(Int(AppConfig.sshCommandTimeout))s"
            } else {
                defaultMessage = "ssh exited with code \(process.terminationStatus)"
            }
            print("[SSHClient] ERROR: SSH failed - \(message ?? defaultMessage)")
            throw SSHClientError.commandFailed(message ?? defaultMessage)
        }

        if timedOut {
            print("[SSHClient] WARNING: ssh appeared to finish after timeout triggered")
        }
        print("[SSHClient] SSH completed successfully, got \(output.count) bytes")
        return output
    }

    private func makeArguments(for command: String) -> [String] {
        var arguments: [String] = []

        // Disable strict host key checking to avoid interactive prompts
        arguments.append(contentsOf: ["-o", "StrictHostKeyChecking=no"])
        arguments.append(contentsOf: ["-o", "UserKnownHostsFile=/dev/null"])
        arguments.append("-T")

        // Only use BatchMode if we don't have a password (for passphrase-less keys)
        // If we have a password, it could be for key passphrase or server auth
        if connection.password == nil || connection.password!.isEmpty {
            arguments.append(contentsOf: ["-o", "BatchMode=yes"])
        }

        arguments.append(contentsOf: ["-o", "ConnectTimeout=\(Int(AppConfig.sshConnectTimeout))"])

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
        arguments.append(nonInteractiveCommandWrapper(for: command))
        return arguments
    }

    private func nonInteractiveCommandWrapper(for command: String) -> String {
        var scriptLines: [String] = []
        scriptLines.append("set +e")
        scriptLines.append("echo '[HiveSqueueMenu] Remote wrapper starting' >&2")
        scriptLines.append("export PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin")
        scriptLines.append("export LC_ALL=C")
        if let initScript = AppConfig.moduleInitScript {
            scriptLines.append("if [ -f \(initScript) ]; then source \(initScript); fi")
        }
        if let slurmModule = AppConfig.slurmModule {
            var moduleLoader = "if command -v module >/dev/null 2>&1; then module load \(slurmModule);"
            if let moduleCmdPath = AppConfig.moduleCommandPath {
                moduleLoader += " elif [ -x \(moduleCmdPath) ]; then eval \"$(\(moduleCmdPath) bash load \(slurmModule))\";"
            }
            moduleLoader += " else echo \"Warning: module command not found on remote host\" >&2; fi"
            scriptLines.append("(\(moduleLoader)) || true")
        }
        scriptLines.append("echo '[HiveSqueueMenu] Executing Slurm command' >&2")
        scriptLines.append(command)
        scriptLines.append("echo '[HiveSqueueMenu] Slurm command finished with status $?' >&2")

        let script = scriptLines.joined(separator: " ; ")
        let sanitized = script
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "'\\''")
        return #"/bin/bash --noprofile --norc -c '"# + sanitized + "'"
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
        print("[SSHClient] Generated askpass script at \(scriptURL.path)")
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

final class ThreadSafeDataBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()

    func append(_ chunk: Data) {
        lock.lock()
        storage.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        let copy = storage
        lock.unlock()
        return copy
    }
}

private extension String {
    var expandingTilde: String {
        (self as NSString).expandingTildeInPath
    }
}
