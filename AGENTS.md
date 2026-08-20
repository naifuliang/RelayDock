# AGENTS.md

## Cursor Cloud specific instructions

RelayDock is a **macOS-native application** and cannot be built, tested, or run
on the Linux Cloud Agent VM. Cloud Agents run Linux (Ubuntu) microVMs; macOS is
not available. Do not spend time trying to make `swift build`, `swift test`, or
`swift run RelayDock` succeed here — they cannot.

Why it is macOS-only (see `Package.swift`, which declares `platforms: [.macOS(.v13)]`):

- The `RelayDock` target imports Apple-only frameworks that have no Linux
  implementation in the open-source Swift toolchain: `SwiftUI`, `AppKit`,
  `Security`, `CryptoKit`, `Network`, `CFNetwork`, and `LocalAuthentication`
  (plus `SQLite3`). On Linux these fail with `error: no such module '...'`.
- The `RelayDockTests` target depends on `RelayDock`, so the test module also
  fails to compile on Linux even though some individual test files only use
  Foundation.
- `scripts/build-app.sh` builds with `--triple arm64-apple-macosx13.0` /
  `x86_64-apple-macosx13.0` and packages with macOS-only `lipo` and `codesign`.

What this means for a Cloud Agent:

- You can still read, search, and statically reason about the Swift source, and
  edit non-code files. You cannot compile or run anything.
- Any lint / build / test / run verification of code changes must be done on a
  real macOS host (macOS 13+, Xcode 16+ or a Swift 6 toolchain), not here.

Standard commands (run on macOS only — do not run on this VM). See `README.md`
"Build" section for details:

- Tests: `swift test`
- Run in dev mode: `swift run RelayDock`
- Build the `.app` bundle: `./scripts/build-app.sh`
- Package release artifacts (DMG/ZIP): `./scripts/package-release.sh`
