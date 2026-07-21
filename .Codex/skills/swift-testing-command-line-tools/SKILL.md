# Swift Testing with standalone Command Line Tools

## Context

On some macOS installations, `xcode-select` points at `/Library/Developer/CommandLineTools` while full Xcode is unavailable because its license has not been accepted. SwiftPM may then report `no such module 'Testing'` even though `Testing.framework` is bundled under the Command Line Tools directory.

Adding only `-F` compiles the tests but fails at runtime because neither `Testing.framework` nor `lib_TestingInterop.dylib` is on the test bundle's runtime search path.

## Solution

From the repository root, run:

```bash
bash .Codex/skills/swift-testing-command-line-tools/run_tests.sh
```

The script adds the bundled framework at compile/link time and adds runtime rpaths for both the framework and its interop library. Prefer a normal `swift test` when a fully configured Xcode toolchain is selected; use this workaround only for the standalone Command Line Tools layout.

## Expected locations

- `Testing.framework`: `/Library/Developer/CommandLineTools/Library/Developer/Frameworks`
- `lib_TestingInterop.dylib`: `/Library/Developer/CommandLineTools/Library/Developer/usr/lib`

If either location changes, locate the files with `find /Library/Developer/CommandLineTools -name 'Testing.framework' -o -name 'lib_TestingInterop.dylib'` and update the script.
