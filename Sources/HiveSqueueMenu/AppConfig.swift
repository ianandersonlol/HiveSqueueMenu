import Foundation

enum AppConfig {
    /// Stable defaults suite so settings survive across raw SwiftPM runs and temporary app bundles.
    static let defaultsSuiteName = "HiveSqueueMenu"
    /// Default cluster host; replace with your actual login host.
    static let clusterHost = "hive.hpc.ucdavis.edu"
    /// Maximum number of jobs to render inside the panel for readability.
    static let maxVisibleJobs = 20
    /// Minimum seconds between manual refresh actions.
    static let manualRefreshCooldown: TimeInterval = 30
    /// SSH binary path. Adjust if you need a custom SSH client.
    static let sshPath = "/usr/bin/ssh"
    /// SSH connection timeout to avoid hanging forever when hosts are unreachable.
    static let sshConnectTimeout: TimeInterval = 15
    /// Hard cap on total SSH command runtime before we kill it and surface an error.
    static let sshCommandTimeout: TimeInterval = 45
    /// Maximum captured stdout per SSH command. Pipe data beyond this is still drained but not retained.
    static let maxSSHStdoutBytes = 16 * 1_024 * 1_024
    /// Maximum captured stderr per SSH command.
    static let maxSSHStderrBytes = 2 * 1_024 * 1_024
    /// Command executed on the cluster to obtain job JSON.
    static let remoteCommand = "squeue --me --json"
    /// Upper bound for one atomic credential response in the in-memory askpass FIFO.
    static let maxCredentialUTF8Bytes = 512
}
