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
    /// SSH connection timeout to avoid hanging forever when hosts are unreachable.
    static let sshConnectTimeout: TimeInterval = 15
    /// Hard cap on total SSH command runtime before we kill it and surface an error.
    static let sshCommandTimeout: TimeInterval = 45
    /// Optional shell script that initializes the environment modules system on remote hosts.
    static let moduleInitScript: String? = "/etc/profile.d/modules.sh"
    /// Optional Slurm module to load before running the remote command (set to nil if not needed).
    static let slurmModule: String? = "slurm/25-05-0-1"
    /// Optional path to the `modulecmd` binary for environments without the `module` shell function.
    static let moduleCommandPath: String? = "/usr/share/Modules/bin/modulecmd"
    /// Command executed on the cluster to obtain job JSON.
    /// Uses full path to avoid needing module system or bashrc
    static let remoteCommand = "/cvmfs/hpc.ucdavis.edu/sw/spack/environments/core/view/generic/slurm/bin/squeue --me --json"
}
