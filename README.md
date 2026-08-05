# RelayDock

RelayDock is a native macOS launcher and endpoint bridge project for AI coding tools.

<img src="Assets/AppIcon.png" alt="RelayDock app icon" width="180">

The icon is hand-drawn from deterministic vector geometry. Edit
`Assets/AppIcon.svg` or the matching dimensions in `scripts/render-icon.swift`;
`scripts/build-icon.sh` renders the PNG and ICNS assets.

Version 0.2.0 adds a multi-endpoint workspace, OpenCode integration, and GitHub update checks. Cursor remains an explicit **Probe MVP**: RelayDock observes whether Anthropic BYOK traffic connects directly from the Mac, but does not yet redirect or decrypt Cursor traffic.

## Current features

- Multiple independent gateways with OpenAI-compatible, OpenAI Responses,
  Azure OpenAI, and Anthropic modes.
- Multiple selectable model IDs and a separate Keychain API key per endpoint.
- One-click generation of an isolated OpenCode configuration through the
  official `OPENCODE_CONFIG` mechanism. Existing global config is not replaced.
- OpenCode keys are exported only to RelayDock-owned files with mode `0600` and
  referenced through OpenCode's `{file:...}` substitution.
- Automatic daily GitHub Release checks and direct DMG download with the
  GitHub-published SHA-256 digest verified when available.
- Native SwiftUI window and menu bar utility.
- Endpoint health check through `GET /v1/models`.
- Local HTTP CONNECT probe bound to `127.0.0.1` on a random port.
- Cursor launcher using an app-scoped `--proxy-server` argument.
- Domain-only connection diagnostics; TLS payloads remain encrypted.
- One-click removal of settings, generated OpenCode files, and credentials.
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
installed RelayDock copy and applies a local ad-hoc signature.

### Build or install from the DMG

Create both a drag-to-install DMG and a flat macOS installer package:

```bash
./scripts/package-release.sh
```

Artifacts are written to `dist/`:

- `RelayDock-<version>.dmg`
- `RelayDock-<version>.pkg`
- `RelayDock-mac-universal.zip`
- `RelayDock-mac-universal.zip.sha256`
- `SHA256SUMS`

The DMG contains:

- `Install Guide.html` and `安装说明.html`, with matching English and Chinese
  step-by-step install and probe guides.
- `Install RelayDock.command`, which copies the app to `/Applications`, removes
  the quarantine attribute from that local copy, and applies an ad-hoc local
  signature.
- `Uninstall RelayDock.command`, which removes the app, RelayDock preferences,
  and the gateway API key stored in Keychain.

For an unsigned personal build, open Terminal, type `/bin/zsh ` (including the
trailing space), drag `Install RelayDock.command` from the mounted DMG into the
Terminal window, and press Return. Prefixing the dragged path with `/bin/zsh`
is required; executing the `.command` path itself can still be blocked by
Gatekeeper. The drag step also avoids hard-coding a volume name that macOS may
suffix when the DMG is mounted more than once.

Local builds are ad-hoc app signed and the PKG is unsigned unless signing
identities are supplied:

```bash
RELAYDOCK_APP_SIGN_IDENTITY="Developer ID Application: Example" \
RELAYDOCK_INSTALLER_SIGN_IDENTITY="Developer ID Installer: Example" \
./scripts/package-release.sh
```

Public distribution without Gatekeeper warnings additionally requires Apple
Developer ID certificates and notarization.

## OpenCode workflow

1. Add one or more gateways in the RelayDock sidebar.
2. Choose the protocol, Base URL, API key, and model IDs for each endpoint.
3. Save each endpoint, then choose **Configure and launch OpenCode**.
4. RelayDock launches OpenCode with its isolated generated configuration;
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
- RelayDock currently installs no certificates or privileged helpers.

## License

MIT. See [LICENSE](LICENSE).
