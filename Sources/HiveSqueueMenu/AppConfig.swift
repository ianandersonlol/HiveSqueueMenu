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
    /// Command executed on the cluster to obtain job JSON.
    static let remoteCommand = "squeue --me --json"
    /// Environment variable used by the fixed askpass helper. The password is never written into the helper source.
    static let askPassSecretEnvironmentKey = "HIVESQUEUE_ASKPASS_SECRET"
}
