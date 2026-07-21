# HiveSqueueMenu

A small macOS menu-bar app for checking your personal Slurm queue over SSH. It shows queue counts in the menu bar and a compact SwiftUI panel with state, runtime, resources, nodes, and working-directory details for the first 20 jobs.

## What it does

- Connects with the system `/usr/bin/ssh` client using your SSH agent, a private key, or a Keychain-backed password.
- Uses the normal OpenSSH `known_hosts` file with `StrictHostKeyChecking=accept-new`; changed host keys are rejected.
- Performs a lightweight count query followed by detailed JSON only for visible jobs.
- Handles plain and wrapped Slurm JSON values, job arrays, heterogeneous jobs, TRES resources, and common Slurm states.
- Refreshes only when requested. A 30-second manual-refresh cooldown protects the scheduler; Retry explicitly bypasses it after an error.
- Stores non-secret preferences in `UserDefaults` and passwords in the macOS Keychain with when-unlocked accessibility.

The app does not submit, modify, or cancel jobs.

## Requirements

- macOS 14 or newer
- Swift 6.2 or newer (Xcode 26 or a compatible Swift toolchain)
- `/usr/bin/ssh`
- A Slurm cluster that provides `squeue`

## Configure and use

1. Build and open the app bundle:

   ```bash
   Scripts/package-app.sh .build/HiveSqueueMenu.app
   open .build/HiveSqueueMenu.app
   ```

2. Open **Preferences** from the menu panel.
3. Enter the cluster host and username.
4. Select a cluster profile:
   - **Standard Slurm** performs no remote module setup.
   - **UC Davis HIVE** initializes Environment Modules and loads the unversioned `slurm` module.
5. Select an authentication mode:
   - **SSH Agent** uses keys already available to your local agent/session.
   - **SSH Key File** uses a detected or custom private-key path. An optional passphrase is supplied through askpass.
   - **Password Only** requires a password stored in Keychain.
6. Use **Test Connection**, then close Preferences and click **Refresh**.

On the first connection to a host, OpenSSH records its host key in your normal `~/.ssh/known_hosts`. A later key change fails rather than being silently accepted.

The remote command defaults to `squeue --me --json`. The Preferences override is intentionally powerful and executes as shell text on the configured remote account; only enter commands you trust.

## Development

Build the executable:

```bash
swift build
```

Run the test suite with a normal Xcode toolchain:

```bash
swift test
```

If standalone Command Line Tools cannot locate their bundled Swift Testing framework, use the documented local workaround:

```bash
.Codex/skills/swift-testing-command-line-tools/run_tests.sh
```

Create a release build and ad-hoc-signed local app bundle:

```bash
Scripts/package-app.sh .build/HiveSqueueMenu.app
```

For Developer ID signing, provide an installed signing identity:

```bash
CODE_SIGN_IDENTITY="Developer ID Application: Example" \
  MARKETING_VERSION=1.0.0 \
  Scripts/package-app.sh dist/HiveSqueueMenu.app
```

The script verifies the resulting signature. Notarization still requires your Apple Developer credentials and is deliberately left outside the repository.

## Architecture

- `SSHClient` owns OpenSSH arguments, host trust, askpass, concurrent pipe draining, and command timeouts.
- `SlurmService` owns remote commands, failure classification, count/detail fetching, and JSON parsing.
- `SlurmMonitor` owns main-actor UI state, cooldowns, failure throttling, and refresh cancellation/generation safety.
- `ClusterProfile` owns cluster-specific remote bootstrap behavior.
- `SlurmJob`, `SlurmDecoding`, `SlurmWireValues`, `SlurmJobPresentation`, and `JobState` separate domain identity, wire compatibility, and display formatting.
- `UserSettings` and `KeychainHelper` persist preferences and credentials.
- `MenuViews` and `SettingsView` contain the SwiftUI interface.

GitHub Actions builds, tests, packages the app on `macos-26`, and creates a release archive for tags matching `v*`. The automated archive is ad-hoc signed unless a signing identity is explicitly provisioned.

## Troubleshooting

- **Host key verification failed:** inspect the host’s current fingerprint with your cluster administrator before changing `known_hosts`.
- **Authentication failed:** confirm the selected mode and test the equivalent connection in Terminal.
- **`squeue` not found:** choose the correct cluster profile or customize the remote command.
- **No tests run under Command Line Tools:** use the repository test-workaround script above or select a licensed full Xcode installation.

## License

MIT; see [LICENSE](LICENSE).
