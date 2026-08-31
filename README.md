# HiveSqueueMenu

A small macOS menu-bar app for checking your personal Slurm queue over SSH. It shows queue counts in the menu bar and a compact SwiftUI panel with state, runtime, resources, nodes, and working-directory details for the first 20 jobs.

## What it does

- Connects with the system `/usr/bin/ssh` client using your SSH agent, a private key, or a Keychain-backed account password.
- Verifies hosts against the normal OpenSSH `known_hosts` file in strict mode by default. Trust-on-first-use (`accept-new`) is an explicit opt-in; changed host keys are always rejected.
- Uses one authenticated SSH session to count compressed queue records and fetch detailed JSON only for a bounded set of representative visible jobs.
- Handles plain and wrapped Slurm JSON values, job arrays, heterogeneous jobs, TRES resources, and common Slurm states.
- Refreshes only when requested. A 30-second manual-refresh cooldown protects the scheduler; Retry explicitly bypasses it after an error.
- Applies connection edits as one validated snapshot, stores non-secret preferences in `UserDefaults`, and keeps account passwords and private-key passphrases in separate identity-scoped Keychain entries.

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
6. Choose a host-verification policy. **Verified Hosts Only** is the safe default; **Trust New Hosts Automatically** is available for a verified first-use setup.
7. Use **Test Draft Connection**, then **Apply**. Close Preferences and click **Refresh**.

With the default strict policy, an unknown host is rejected. Verify its fingerprint with the cluster administrator, then connect once in Terminal to add it to `~/.ssh/known_hosts`. If you explicitly choose trust-on-first-use, OpenSSH records the first key it sees in an isolated app-only store. That unverified key is never consulted by strict Password Only connections, so switching policies cannot make it eligible to receive an account password. A later key change fails under either policy.

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
bash .Codex/skills/swift-testing-command-line-tools/run_tests.sh
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

- `SSHClient` owns OpenSSH arguments, provenance-separated host trust, prompt-scoped askpass, streamed remote bootstrap scripts, concurrent pipe draining, cancellation, and command timeouts.
- `SlurmService` owns remote commands, failure classification, bounded count/detail fetching, compressed-array cardinality, and JSON parsing.
- `SlurmMonitor` owns main-actor UI state, cooldowns, failure throttling, and refresh cancellation/generation safety.
- `HiveSqueueAppModel` keeps settings-to-monitor synchronization alive independently of the transient menu panel.
- `ClusterProfile` owns cluster-specific remote bootstrap behavior.
- `SlurmJob`, `SlurmDecoding`, `SlurmWireValues`, `SlurmJobPresentation`, and `JobState` separate domain identity, wire compatibility, and display formatting.
- `ConnectionSettingsDraft`, `UserSettings`, and `KeychainHelper` validate and atomically publish settings while keeping account and key credentials separate.
- `MenuViews` and `SettingsView` contain the SwiftUI interface.

GitHub Actions builds, tests, packages the app on `macos-26`, and creates a release archive for tags matching `v*`. The automated archive is ad-hoc signed unless a signing identity is explicitly provisioned.

## Troubleshooting

- **Host key verification failed:** inspect the host’s current fingerprint with your cluster administrator before changing `known_hosts`.
- **Authentication failed:** confirm the selected mode and test the equivalent connection in Terminal.
- **`squeue` not found:** choose the correct cluster profile or customize the remote command.
- **No tests run under Command Line Tools:** use the repository test-workaround script above or select a licensed full Xcode installation.

## License

MIT; see [LICENSE](LICENSE).
