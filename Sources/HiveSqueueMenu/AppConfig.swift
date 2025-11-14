import Foundation

enum AppConfig {
    /// Default cluster host; replace with your actual login host.
    static let clusterHost = "hive.hpc.ucdavis.edu"
    /// Maximum number of jobs to render inside the panel for readability.
    static let maxVisibleJobs = 20
    /// Minimum seconds between manual refresh actions.
    static let manualRefreshCooldown: TimeInterval = 30
    /// SSH binary path. Adjust if you need a custom SSH client.
    static let sshPath = "/usr/bin/ssh"
    /// Command executed on the cluster to obtain job JSON.
    /// Uses full path to avoid needing module system or bashrc
    static let remoteCommand = "/cvmfs/hpc.ucdavis.edu/sw/spack/environments/core/view/generic/slurm/bin/squeue --me --json"
}
