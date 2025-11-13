import Combine
import Foundation
import SwiftUI

final class SlurmMonitor: ObservableObject {
    @Published var jobs: [SlurmJob] = []
    @Published var error: String?
    @Published private(set) var host: String
    @Published private(set) var isFetching: Bool = false
    @Published private(set) var lastFetchDate: Date?

    var runningJobs: [SlurmJob] {
        jobs.filter { $0.displayState == .running }
    }

    var pendingJobs: [SlurmJob] {
        jobs.filter { $0.displayState == .pending }
    }

    var menuTitle: String {
        if error != nil {
            return "Slurm: !"
        }

        let runningCount = runningJobs.count
        let pendingCount = pendingJobs.count
        return "Slurm: \(runningCount)R \(pendingCount)Q"
    }

    private var connection: ConnectionSettings
    private let sshPath: String
    private let remoteCommand: String
    private let refreshCooldown: TimeInterval
    private let fetchQueue = DispatchQueue(label: "SlurmMonitor.fetch.queue", qos: .utility)
    private var fetchInFlight = false
    private var latestFetchDate: Date?
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()

    init(
        connection: ConnectionSettings,
        sshPath: String = AppConfig.sshPath,
        remoteCommand: String = AppConfig.remoteCommand,
        refreshCooldown: TimeInterval = AppConfig.manualRefreshCooldown
    ) {
        self.connection = connection
        self.sshPath = sshPath
        self.remoteCommand = remoteCommand
        self.refreshCooldown = refreshCooldown
        self.host = connection.host
    }

    func fetch(force: Bool = false) {
        fetchQueue.async { [weak self] in
            guard let self else { return }

            if self.fetchInFlight {
                return
            }

            let now = Date()
            if !force, let last = self.latestFetchDate, now.timeIntervalSince(last) < self.refreshCooldown {
                return
            }

            self.fetchInFlight = true
            DispatchQueue.main.async {
                self.isFetching = true
            }

            do {
                let jobs = try self.fetchJobs()
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        self.jobs = jobs
                    }
                    self.error = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                }
            }

            let finished = Date()
            self.latestFetchDate = finished
            DispatchQueue.main.async {
                self.lastFetchDate = finished
                self.isFetching = false
            }

            self.fetchInFlight = false
        }
    }

    private func fetchJobs() throws -> [SlurmJob] {
        let data = try runSSH()
        let response = try decoder.decode(SlurmResponse.self, from: data)
        return response.jobs.sorted(by: Self.jobSort)
    }

    private func runSSH() throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: sshPath) else {
            throw SlurmMonitorError.sshUnavailable(sshPath)
        }

        let connection = self.connection

        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = makeArguments(for: connection)

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
            try process.run()
        } catch {
            throw SlurmMonitorError.unableToLaunch(error.localizedDescription)
        }

        process.waitUntilExit()
        if let askPassURL {
            try? FileManager.default.removeItem(at: askPassURL)
        }

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 {
            let errData = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw SlurmMonitorError.commandFailed(message ?? "ssh exited with code \(process.terminationStatus)")
        }

        return output
    }

    func updateConnection(_ newConnection: ConnectionSettings) {
        fetchQueue.async { [weak self] in
            guard let self else { return }
            self.connection = newConnection
            self.latestFetchDate = nil
            self.fetchInFlight = false
        }
        DispatchQueue.main.async {
            self.host = newConnection.host
            self.jobs = []
            self.lastFetchDate = nil
            self.error = nil
            self.isFetching = false
        }
    }

    func timeUntilNextAllowedRefresh(from date: Date = Date()) -> TimeInterval? {
        guard let lastFetchDate else { return nil }
        let remaining = refreshCooldown - date.timeIntervalSince(lastFetchDate)
        return remaining > 0 ? remaining : nil
    }

    private func makeArguments(for connection: ConnectionSettings) -> [String] {
        var arguments: [String] = []
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
        arguments.append(remoteCommand)
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
            throw SlurmMonitorError.unableToLaunch("Unable to encode password for askpass.")
        }
        try data.write(to: scriptURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: Int16(0o700))], ofItemAtPath: scriptURL.path)
        return scriptURL
    }

    private static func jobSort(lhs: SlurmJob, rhs: SlurmJob) -> Bool {
        let lhsPriority = lhs.displayState.priority
        let rhsPriority = rhs.displayState.priority
        if lhsPriority == rhsPriority {
            return lhs.id < rhs.id
        }
        return lhsPriority < rhsPriority
    }
}

enum SlurmMonitorError: LocalizedError {
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

private extension JobState {
    var priority: Int {
        switch self {
        case .running:
            return 0
        case .pending:
            return 1
        case .other:
            return 2
        }
    }
}

private extension String {
    var expandingTilde: String {
        (self as NSString).expandingTildeInPath
    }
}
