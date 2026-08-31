# SwiftPM Menu Bar App Launch

## Context

SwiftPM builds a raw Mach-O executable in `.build/debug/` or `.build/arm64-apple-macosx/debug/`. Launching that binary directly from a terminal session can leave a SwiftUI `MenuBarExtra` app running as a terminal child process instead of a normal desktop app. The result is confusing:

- the process exists, but no menu bar item appears
- `open /path/to/binary` does nothing useful because the target is not an app bundle
- debugging from terminal output makes it look like the app launched successfully even though LaunchServices never treated it as an app

## Fix

Wrap the built executable in a minimal `.app` bundle and launch that bundle with `open`.

Run:

```bash
bash .Codex/skills/swiftpm-menubar-app-launch/build_app_bundle.sh \
  .build/debug/HiveSqueueMenu \
  /tmp/HiveSqueueMenu.app \
  local.HiveSqueueMenu
open /tmp/HiveSqueueMenu.app
```

If `.build/debug/HiveSqueueMenu` does not exist, use the architecture-specific path instead:

```bash
bash .Codex/skills/swiftpm-menubar-app-launch/build_app_bundle.sh \
  .build/arm64-apple-macosx/debug/HiveSqueueMenu \
  /tmp/HiveSqueueMenu.app \
  local.HiveSqueueMenu
open /tmp/HiveSqueueMenu.app
```

## Notes

- This is a launch workaround, not a replacement for a proper Xcode app bundle.
- The generated app is ad-hoc signed so LaunchServices will run it locally.
- The helper script also copies any adjacent SwiftPM resource bundles into `Contents/Resources`, which is required if the executable target uses packaged images or other resources.
- For menu bar verification, prefer the `.app` path over running the raw executable with `./.build/debug/HiveSqueueMenu`.
