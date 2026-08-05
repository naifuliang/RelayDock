# RelayDock

RelayDock is a native macOS launcher and endpoint bridge project for AI coding tools.

<img src="Assets/AppIcon.png" alt="RelayDock app icon" width="180">

The icon is hand-drawn from deterministic vector geometry. Edit
`Assets/AppIcon.svg` or the matching dimensions in `scripts/render-icon.swift`;
`scripts/build-icon.sh` renders the PNG and ICNS assets.

Version 0.3.1 adds a verified in-app upgrade flow and visible update-check results. It retains the 0.3 multi-endpoint workspace, automatic model discovery, per-model verification, and direct OpenCode/Cursor launch actions. Cursor remains an explicit **Probe MVP**: RelayDock observes whether Anthropic BYOK traffic connects directly from the Mac, but does not yet redirect or decrypt Cursor traffic.

## Current features

- Multiple independent gateways with OpenAI-compatible, OpenAI Responses,
  Azure OpenAI, and Anthropic modes.
- Automatic model discovery after an endpoint/key connection test.
- One-click verification of every enabled model with per-model results.
- Multiple selectable model IDs and a separate Keychain API key per endpoint.
- One-click generation of an isolated OpenCode configuration through the
  official `OPENCODE_CONFIG` mechanism. Existing global config is not replaced.
- OpenCode keys are exported only to RelayDock-owned files with mode `0600` and
  referenced through OpenCode's `{file:...}` substitution.
- Automatic daily GitHub Release checks and direct DMG download with the
  GitHub-published SHA-256 digest verified when available.
- Visible update results for checking, latest-version, available-version, and
  failure states, including the last check time.
- Verified upgrade handoff: mount the downloaded DMG, verify its version and
  app signature, run the bundled installer, confirm the installed version, and
  restart RelayDock.
- Native SwiftUI window and menu bar utility.
- Provider-aware endpoint health checks and model catalog requests.
- Catalog synchronization keeps text-generation candidates for coding tools;
  Azure's retired legacy deployment-list mode requires manual deployment IDs.
- Local HTTP CONNECT probe bound to `127.0.0.1` on a random port.
- Cursor launcher using an app-scoped `--proxy-server` argument.
- Domain-only connection diagnostics; TLS payloads remain encrypted.
- One-click normal launch actions for OpenCode and Cursor.
- The bundled uninstaller removes settings, generated OpenCode files,
  credentials, and the private local signing identity.
- No system proxy changes, root certificate installation, or HTTPS decryption in this milestone.

## Build

Requirements: macOS 13+, Xcode 16+ or a compatible Swift 6 toolchain.

Release builds are Universal 2 binaries for Apple Silicon and Intel Macs.

```bash
swift test
./scripts/build-app.sh
open dist/RelayDock.app
```

During development, you can also run:

```bash
swift run RelayDock
```

## Installer packages

### Fastest installation for the unsigned test build

Paste this single line into Terminal:

```bash
/usr/bin/curl -fsSL https://raw.githubusercontent.com/naifuliang/RelayDock/main/install.sh | /bin/zsh
```

The script explains its actions before asking for confirmation. It downloads
the latest Universal release from GitHub, checks its published SHA-256 hash and
existing app signature for integrity, installs it in `/Applications`, and
launches it. These checks are not a substitute for Apple notarization. It does
not disable Gatekeeper globally, install a root certificate, or change the
system proxy. For this unsigned test build, it removes quarantine only from the
installed RelayDock copy and signs it with a stable RelayDock-only identity stored
in `~/Library/Keychains/RelayDockLocalSigning.keychain-db`. This keychain is
added only to the user's Keychain search list so macOS can resolve the signing
certificate; no certificate trust is added. The uninstaller removes the
keychain and its search-list entry.

The first upgrade from an older ad-hoc-signed build changes the app's designated
requirement. RelayDock deliberately refuses interactive Keychain authorization
prompts, so an inaccessible older endpoint key is shown as empty and must be
entered again. Releases installed with the stable local identity preserve access
after that migration without password prompts.

### Build or install from the DMG

Create a drag-to-install DMG and the one-line installer archive:

```bash
./scripts/package-release.sh
```

Artifacts are written to `dist/`:

- `RelayDock-<version>.dmg`
- `RelayDock-mac-universal.zip`
- `RelayDock-mac-universal.zip.sha256`
- `SHA256SUMS`

The DMG contains:

- `Install Guide.html` and `安装说明.html`, with matching English and Chinese
  step-by-step install and probe guides.
- `Install RelayDock.command`, which copies the app to `/Applications`, removes
  the quarantine attribute from that local copy, and applies a stable local
  RelayDock-only signature.
- `Uninstall RelayDock.command`, which removes the app, RelayDock preferences,
  all endpoint API keys, generated configuration, and the private signing
  keychain.

For an unsigned personal build, open Terminal, type `/bin/zsh ` (including the
trailing space), drag `Install RelayDock.command` from the mounted DMG into the
Terminal window, and press Return. Prefixing the dragged path with `/bin/zsh`
is required; executing the `.command` path itself can still be blocked by
Gatekeeper. The drag step also avoids hard-coding a volume name that macOS may
suffix when the DMG is mounted more than once.

Local builds are ad-hoc app signed. A PKG is emitted only when both Developer ID
Application and Developer ID Installer identities are supplied; unsigned PKGs
are intentionally not produced because their post-install re-signing would not
preserve Keychain access across updates:

```bash
RELAYDOCK_APP_SIGN_IDENTITY="Developer ID Application: Example" \
RELAYDOCK_INSTALLER_SIGN_IDENTITY="Developer ID Installer: Example" \
./scripts/package-release.sh
```

Public distribution without Gatekeeper warnings additionally requires Apple
Developer ID certificates and notarization.

## OpenCode workflow

1. Add one or more endpoints inside the single **Endpoints** configuration card.
2. Choose the protocol, Base URL, and API key, then use **Sync Models** to test
   the connection and fetch the endpoint's model catalog.
3. Use **Verify All** to send a minimal request to every enabled model and see
   its individual result. This can incur a very small amount of API usage.
4. Save each endpoint, then choose **Configure and open OpenCode**.
5. RelayDock launches OpenCode with its isolated generated configuration;
   global and project OpenCode configuration precedence is preserved.

Quit OpenCode.app completely before launching it through RelayDock. OpenCode's
desktop build is single-instance, so an already-running process cannot inherit
the newly supplied `OPENCODE_CONFIG` environment variable. RelayDock detects
this state and stops instead of reporting a false success.

RelayDock detects OpenCode.app, `~/.opencode/bin`, `~/.local/bin`, Apple Silicon
Homebrew, Intel Homebrew, or `/usr/bin`.

## Cursor probe workflow

1. Open RelayDock and start the probe proxy.
2. Fully quit any existing Cursor process.
3. Click **Launch Cursor through proxy**.
4. Configure Anthropic BYOK in Cursor and send one request.
5. Look for `api.anthropic.com` in RelayDock diagnostics.

If a direct Anthropic connection is observed, the next milestone can add a narrowly scoped TLS bridge for that host. If only Cursor backend domains appear, local endpoint substitution cannot be done transparently.

## Security model

- The proxy listens on loopback only.
- Remote gateway profiles require HTTPS; plain HTTP is accepted only for loopback gateways.
- Non-target connections are tunneled byte-for-byte.
- The probe stores no request bodies, headers, prompts, or responses.
- Gateway keys are stored with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- The unsigned installer creates a private, self-signed code-signing identity in
  `~/Library/Keychains/RelayDockLocalSigning.keychain-db` so future local signatures remain stable. It is
  not trusted as a root certificate, is not used for TLS, and is removed by the
  uninstaller.

## License

MIT. See [LICENSE](LICENSE).
