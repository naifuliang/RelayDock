# RelayDock

RelayDock is a native macOS launcher and endpoint bridge project for AI coding tools.

## Fastest installation

Paste this one command into Terminal:

```bash
/usr/bin/curl -fsSL https://raw.githubusercontent.com/naifuliang/RelayDock/main/install.sh | /bin/zsh
```

The installer downloads the latest Universal release from GitHub, verifies its
published SHA-256 checksum and app signature, installs RelayDock in
`/Applications`, and opens it. RelayDock is currently an unsigned,
unnotarized test build; the installer explains every local change and asks for
confirmation before continuing.

<img src="Assets/AppIcon.png" alt="RelayDock app icon" width="180">

The icon is hand-drawn from deterministic vector geometry. Edit
`Assets/AppIcon.svg` or the matching dimensions in `scripts/render-icon.swift`;
`scripts/build-icon.sh` renders the PNG and ICNS assets.

Version 0.5.6 makes Cursor's routed egress complete. Because RelayDock points
Cursor's Chromium switch and `HTTP_PROXY` at the Bridge, every `http://` request
reaches it in absolute form rather than as a CONNECT tunnel; those requests were
rejected with `400`, which silently broke plain-HTTP traffic for the whole
application. The Bridge now forwards them, either straight to the origin with an
origin-form request line or verbatim to a chained upstream proxy, and pins each
forwarded connection so a reused proxy socket cannot deliver another host's
request to the wrong origin. System-proxy selection now scans macOS's whole
ordered proxy list instead of only its first entry, so a Mac with SOCKS listed
ahead of its HTTP proxy uses the HTTP proxy instead of failing closed; an
explicit direct entry is still refused when an unsupported proxy was skipped.
Replacing an endpoint key now clears that endpoint's model verification even
when the stored key was never loaded, and the OpenCode export unlocks
credentials only for the endpoints it actually writes.

Version 0.5.5 fixes OpenCode Desktop 1.18 file-secret substitution. Generated
configs now keep JSON slashes unescaped and use config-relative
`{file:./keys/...}` references, matching OpenCode's raw-text preprocessing
order while retaining mode-`0600` key and Bearer files. It also repairs the
remaining update-time Keychain ACL issue with a new v3 credential vault:
ordinary actions never open an old item, and the UI offers one explicit,
fail-closed repair before model sync is allowed. Cursor's Bridge now chains
both Anthropic and non-Anthropic egress through the pre-existing
`HTTP_PROXY`/`HTTPS_PROXY`/`ALL_PROXY` or macOS default HTTP proxy instead of bypassing it;
unsupported SOCKS/PAC modes fail closed. RelayDock's model tests and GitHub
updater use the same route selection. The obsolete standalone Network Probe
card has been removed from the primary UI.

Version 0.5.4 routes Cursor's Node-based AI traffic through a dedicated local
Bridge in addition to Chromium's proxy path. Its Node-only TLS issuer is passed
only to the Cursor process through `NODE_EXTRA_CA_CERTS`, is never installed in
the system Keychain, is name-constrained to `api.anthropic.com`, and has its
signing private key destroyed immediately after the leaf is created. This
closes the Anthropic path while preserving normal TLS validation for every
other host.

Version 0.5.3 fixes Sub2API routing for Cursor and OpenCode by normalizing
unversioned compatible endpoints to their `/v1` API root. Third-party
Anthropic routes now include Bearer-token authentication while retaining
native `x-api-key` compatibility. A new verified Keychain vault migrates the
old ACL-bound item after one approved read so later edits do not repeatedly
ask for the login-keychain password. Sidebar launcher labels are aligned on a
fixed icon column.

Version 0.5.2 fixes one-click Anthropic Bridge trust installation on current
macOS releases. The app now installs its self-signed, `CA:FALSE` leaf with the
correct `trustRoot` result, scoped only to SSL for `api.anthropic.com`, verifies
the postcondition, and rolls back if verification fails. Its DMG also includes
a non-copy compatibility link so RelayDock 0.5.0 can preflight the hidden
payload and hand off the actual update to the transactional installer.

Version 0.5.1 makes credential and signing continuity explicit. App launch and
endpoint switching never read Keychain secret bytes; older per-endpoint items
are migrated only after the user chooses **Migrate once**, into one verified
RelayDock credential vault. The one-line installer, ZIP, DMG, and in-app update
all use the same transactional installer and refuse an unexpected designated-
requirement change before replacing the existing app.

Version 0.5.0 added verified-model imports and real one-click tool setup.
OpenCode receives an isolated multi-endpoint configuration. Cursor receives its
OpenAI-compatible Base URL/key directly; its Anthropic key is paired with a
loopback TLS bridge restricted to `api.anthropic.com`. Cursor configuration is
version-checked, transactional, and rolled back if its encrypted-key migration
does not complete.

## Current features

- Multiple independent gateways with OpenAI-compatible, OpenAI Responses,
  Azure OpenAI, and Anthropic modes.
- Quick-connect presets for the OpenAI API, Kimi Code, and Volcengine
  Ark Coding Plan. A preset fills the supported protocol and official API base;
  the user still supplies that service's API key.
- Automatic model discovery after an endpoint/key connection test.
- One-click verification of every enabled model with per-model results;
  definitively unsupported models are removed, while auth/rate-limit/network
  failures are retained for correction.
- Multiple selectable model IDs with endpoint keys held in one RelayDock
  Keychain vault. The ordinary endpoint configuration never serializes keys.
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
- A functional Sub2API Bridge bound to `127.0.0.1` on a random port. Requests
  for `api.anthropic.com` are terminated and rewritten; every other CONNECT stays
  a byte tunnel and absolute-form `http://` requests are forwarded unchanged in
  meaning.
- Transactional Cursor 3.x configuration import with a mode-`0600` rollback
  snapshot and verification that Cursor migrated temporary keys into its own
  encrypted SecretStorage.
- OpenAI-compatible Cursor import writes the selected Base URL/key and verified
  model IDs. Anthropic import writes only the Claude key; the loopback bridge
  rewrites the fixed Anthropic destination to the selected HTTPS gateway.
- Streaming Anthropic request/response forwarding over HTTP/1.1, including SSE;
  prompts, bodies, responses, and credentials are never logged.
- A self-signed leaf certificate scoped to `api.anthropic.com` only (`CA:FALSE`,
  server-auth EKU), with one-click install and removal.
- The bundled uninstaller removes settings, generated OpenCode files,
  credentials, and the private local signing identity.
- No global system-proxy change and no CA installed system-wide. Chromium uses
  the explicitly installed `api.anthropic.com` leaf trust; Cursor's Node issuer
  is process-scoped, name-constrained, and cannot sign again after setup.

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

The script explains its actions before asking for confirmation. It downloads
the latest Universal release from GitHub, checks its published SHA-256 hash and
existing app signature for integrity, installs it in `/Applications`, and
launches it. These checks are not a substitute for Apple notarization. It does
not disable Gatekeeper globally, install a root CA, or change the
system proxy. For this unsigned test build, it removes quarantine only from the
installed RelayDock copy and signs it with a stable RelayDock-only identity stored
in `~/Library/Keychains/RelayDockLocalSigning.keychain-db`. The installer names
this keychain explicitly when signing; it is not added to the user's general
Keychain search list and no TLS trust is added during app installation. If the user later
enables the Anthropic Bridge, RelayDock separately asks macOS to trust one
`CA:FALSE` leaf for `api.anthropic.com`. The uninstaller removes that trust,
certificate/private key and signing keychain. It also cleans an old search-list
entry left by earlier releases.

RelayDock never reads API Key bytes at startup or when switching endpoints.
When an older Keychain vault or per-endpoint item exists, the app offers an
explicit **Repair Keychain once** action. Model sync and other ordinary actions
will not open old ACL-bound items. macOS may request authorization only after
the user starts the repair; RelayDock commits the new v3 vault only after every
old credential was read and the new vault was verified non-interactively. An
empty verified v3 tombstone prevents undeletable legacy ACL residue from being
imported again after the last active key is removed. A damaged local signing
identity is never silently rotated: the installer stops, preserves it in a
recovery directory, and offers a separately confirmed repair path.

### Build or install from the DMG

Create a guided-installer DMG and the one-line installer archive:

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
  step-by-step install, Cursor Bridge, and OpenCode guides.
- `Install RelayDock.command`, which copies the app to `/Applications`, removes
  the quarantine attribute from that local copy, and applies a stable local
  RelayDock-only signature. The ZIP and application updater invoke this same
  installer rather than maintaining separate replacement logic.
- `Uninstall RelayDock.command`, which removes the app, RelayDock preferences,
  all endpoint API keys, generated configuration, the Anthropic Bridge
  certificate/private key/trust, and the private signing keychain.

For an unsigned personal build, open Terminal, type `/bin/zsh ` (including the
trailing space), drag `Install RelayDock.command` from the mounted DMG into the
Terminal window, and press Return. Prefixing the dragged path with `/bin/zsh`
is required; executing the `.command` path itself can still be blocked by
Gatekeeper. The drag step also avoids hard-coding a volume name that macOS may
suffix when the DMG is mounted more than once.

Do not copy a raw `RelayDock.app` out of an archive or an older build over the
installed app. Unsigned payloads are intentionally kept inside `.payload` so
every supported installation path performs the same requirement comparison,
post-install verification, and rollback.

Local builds are ad-hoc app signed. PKG output is intentionally unsupported:
component packages replace the application outside RelayDock's transactional
installer and cannot provide the same preflight identity check and rollback.
Use the DMG, ZIP, one-line installer, or in-app updater for every installation.

A future Developer ID build can be created with:

```bash
RELAYDOCK_APP_SIGN_IDENTITY="Developer ID Application: Example" \
./scripts/package-release.sh
```

On the first local-signature to Developer ID update, the installer displays the
incoming Team ID and requires the user to type it. RelayDock records that exact
Team ID and bundle identifier; all later updates must match it.

Public distribution without Gatekeeper warnings additionally requires Apple
Developer ID certificates and notarization.

## OpenCode workflow

1. Use a quick-connect preset for OpenAI API, Kimi Code, or Ark Coding
   Plan, or add a custom endpoint inside the single **Endpoints** card.
2. Enter the service API key, then use **Sync Models** to test
   the connection and fetch the endpoint's model catalog.
3. Use **Verify All** to send a minimal request to every enabled model. Only
   models that pass are exported; a definitively unsupported model is removed.
   This can incur a very small amount of API usage.
4. Save each endpoint, then choose **Configure and open OpenCode**.
5. RelayDock launches OpenCode with its isolated generated configuration;
   global and project OpenCode configuration precedence is preserved.

Quit OpenCode.app completely before launching it through RelayDock. OpenCode's
desktop build is single-instance, so an already-running process cannot inherit
the newly supplied `OPENCODE_CONFIG` environment variable. RelayDock detects
this state and stops instead of reporting a false success.

RelayDock detects OpenCode.app, `~/.opencode/bin`, `~/.local/bin`, Apple Silicon
Homebrew, Intel Homebrew, or `/usr/bin`.

### What quick connect means

Quick connect creates a RelayDock endpoint with a known compatible protocol and
API base URL. It does not purchase a plan, sign in to a provider account, or
convert a web subscription into API access. OpenAI requires an OpenAI Platform
API key (a ChatGPT Plus/Pro subscription is separate); Kimi Code uses a
dedicated Kimi Code Console key that is not interchangeable with a Kimi API
Platform key; and Ark Coding Plan uses its
provider-issued Coding Plan API key. Kimi Code and Ark presets include their
documented recommended model aliases as a fallback when catalog discovery is
unavailable; **Sync Models** still replaces them with the returned catalog when
the provider exposes one.

RelayDock writes keys to one macOS Keychain vault only when an endpoint is
saved or the user explicitly migrates an old credential. Launch and endpoint
selection do not read secret bytes.

## Cursor one-click workflow

1. Create and save an OpenAI Compatible endpoint and/or an Anthropic endpoint.
2. **Sync Models**, then **Verify All**. Only models that pass are importable.
3. In **Cursor one-click Sub2API**, select the desired endpoint for each
   protocol and click **Configure and open Cursor**.
4. RelayDock fully quits Cursor, checks the supported Cursor 3.x database
   schema, creates a private rollback snapshot, writes Base URL/key/model
   settings in one transaction, starts the Bridge when Anthropic is selected,
   and launches Cursor.
5. RelayDock reports success only after Cursor removes the temporary plaintext
   key records and creates its encrypted SecretStorage records. Any failure
   stops the Bridge and restores the original records.

The first Anthropic setup invokes a deliberate macOS trust prompt for the
domain-scoped leaf certificate. **Uninstall Bridge** removes its trust,
certificate, and private key. Keep RelayDock running while using Anthropic in
Cursor because the bridge is local to RelayDock.

## Security model

- The proxy listens on loopback only.
- The functional Anthropic Bridge accepts only the two Cursor message POST
  routes and requires the incoming `x-api-key` to match the selected endpoint
  key before it can forward a request.
- Remote gateway profiles require HTTPS; plain HTTP is accepted only for loopback gateways.
- Non-target connections are tunneled byte-for-byte.
- The Bridge stores no request bodies, headers, prompts, responses, or
  credentials. Its diagnostics record only destination host, port, and outcome.
- Gateway keys are stored with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
- The unsigned installer creates a private, self-signed code-signing identity in
  `~/Library/Keychains/RelayDockLocalSigning.keychain-db` so future local signatures remain stable. It is
  not trusted as a root certificate, is not used for TLS, and is removed by the
  uninstaller.
- Anthropic Bridge TLS uses a separate `CA:FALSE` leaf whose SAN contains only
  `api.anthropic.com`. It cannot issue certificates for another host and is
  removed by the in-app Bridge uninstaller and bundled app uninstaller.

## License

MIT. See [LICENSE](LICENSE).
