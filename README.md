# Slurm Menu Bar Monitor

A lightweight macOS menu bar app that tracks your personal Slurm jobs (e.g., UC Davis HIVE) and renders a glassy SwiftUI panel with job details.

## Features
- Menu-bar-only SwiftUI app built with `MenuBarExtra`.
- Periodically shells out to `ssh <host> "squeue --me --json"` and decodes the response into `SlurmJob` models.
- Shows live counts for running (`R`) and pending (`Q`) jobs directly in the menu bar.
- Dropdown panel uses Apple “liquid glass” aesthetics with SwiftUI materials, stat bubbles, and detailed job rows.
- Error banner when SSH/JSON parsing fails; the menu bar label falls back to `Slurm: !`.
- Built-in Preferences window to set host, username, password (stored in Keychain), and pick an SSH key from `~/.ssh`.
- Manual refresh button with a 30-second cooldown so the cluster isn’t polled continuously in the background.

## Requirements
- macOS 14+ with Swift 6.2 toolchain (Xcode 16 or newer).
- Working SSH key-based access to your Slurm cluster and `/usr/bin/ssh` available locally.

## Configuration / Preferences
- Click **Preferences…** in the dropdown (or open the app’s Settings from the system menu) to configure:
  - Cluster host (default: `hive.hpc.ucdavis.edu`).
  - Username (enter `icanders` or whichever account you use on the cluster).
  - SSH key path (auto-populated with the private keys found in `~/.ssh`; you can pick “None” or type a custom path).
  - Password (optional). When filled in, it is stored securely in the macOS Keychain per host and supplied to `ssh` through the askpass flow, so you can operate without an SSH key. Leave it blank to rely on your SSH agent/key.
`AppConfig.swift` centralizes values such as the SSH binary path, manual-refresh cooldown, and maximum visible jobs if you need to tweak those defaults in code.

## Refreshing & Rate Limits
- The app does **not** auto-refresh; it loads data only when you click **Refresh** in the dropdown.
- After every fetch, the refresh button is disabled for 30 seconds (and the monitor enforces the same limit internally) to avoid hammering the Slurm scheduler. The status text shows “Next refresh available in Ns” during this cooldown.
- If you truly need more frequent updates, you can change `AppConfig.manualRefreshCooldown`, but be mindful of your cluster admins.

## Building & Running
1. Ensure your SSH credentials work: `ssh hive.hpc.ucdavis.edu "squeue --me --json"`. If you rely on a password, launch the app once, open Preferences, set your host/username/password, and the app will remember the credentials in Keychain.
2. Build using SwiftPM or open in Xcode:
   - `swift build` (or `swift run`) from the repo root.
   - `open Package.swift` in Xcode for IDE-driven development/signing.
3. Launch the resulting binary/app bundle; open the menu bar dropdown and hit **Refresh** whenever you want an updated job list (no Dock icon is shown).

> **Note:** In the provided environment `swift build` cannot complete because SwiftPM cannot write to its global cache directories; run the build locally on your Mac for a successful compile/sign.

## Architecture Notes
- `UserSettings` persists host/username/key-path in `UserDefaults` and passwords in Keychain, exposing a `ConnectionSettings` snapshot that the monitor consumes.
- `SlurmMonitor` encapsulates SSH execution (`Process` + `Pipe`), password askpass handling, JSON decoding, manual refresh throttling, and `@Published` state used by SwiftUI.
- `SlurmMenuView` renders the liquid-glass UI with stat bubbles, scrollable job rows (capped at `maxVisibleJobs`), and an error banner.
- `HiveSqueueMenuApp` hosts a single `MenuBarExtra`, immediately starts the monitor, and hides the Dock icon via `NSApplication.shared.setActivationPolicy(.accessory)`.

## Next Steps & Ideas
1. Actions on job rows (e.g., `scancel`).
2. Multi-cluster / multi-profile management.
3. Rust core via FFI for the SSH/Slurm fetch to share code with other platforms.
