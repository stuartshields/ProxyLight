# ProxyLight

A local HTTP/HTTPS proxy that rewrites user-mapped URL patterns to remote origins (e.g. `https://myapp.example.com/tachyon/*` → `https://origin.example.net/tachyon/*`). Ships as a macOS menu bar app and, from the same codebase, a Linux CLI.

## Stack

- Swift 6 Package (no Xcode project) split into three targets sharing one core:
  - `ProxyLightCore` (library, cross-platform): mapping engine, PAC generation, CA/leaf cert generation, the SwiftNIO proxy pipeline, config persistence, and `ProxyOrchestrator` (the plain-Swift start/stop/mapping-mutation API both frontends drive).
  - `ProxyLight` (executable, **macOS 14+, Apple Silicon**): the SwiftUI `MenuBarExtra` app. `swift build` compiles for the host arch only, so the shipped bundle is arm64-only; a universal build needs `swift build --arch arm64 --arch x86_64`. Depends on `ProxyLightCore` plus macOS-only wrappers (`SystemProxyManager`, `CATrustManager`, `LoginItemManager`, `SelfUpdater`, `ProxyRestoreStore`) under `Sources/ProxyLight/MacOS/`. `ServiceManagement` (`SMAppService`) drives launch-at-login.
  - `proxylight-cli` (executable, Linux + macOS): a thin `swift-argument-parser` CLI over `ProxyOrchestrator` — no system-proxy automation, no CA auto-trust, no login item, no self-update (see Conventions). This is what makes the Linux build viable: it depends only on `ProxyLightCore`, never on `ProxyLight`.
- SwiftNIO stack: `apple/swift-nio`, `apple/swift-nio-ssl`, `apple/swift-certificates`. `swift-argument-parser` for the CLI. No other dependencies without asking.
- `ProxyLightCore` is intentionally the only target required to build and test on Linux; `ProxyLight` (SwiftUI/AppKit/Security/ServiceManagement) will never compile there and isn't meant to.

## Commands

- Build (macOS app): `swift build` (builds everything — will fail if run from a machine without SwiftUI/AppKit, i.e. non-macOS)
- Build (Linux CLI only): `swift build --product proxylight-cli` — note `--product`, not `--target`; `--target` compiles the module but skips the link step and silently leaves no runnable binary.
- Test (portable core): `swift test --filter ProxyLightCoreTests` builds `ProxyLight` too as a package-wide side effect of `swift test`'s target resolution, so on Linux this still fails — see "Verifying the Linux side" below.
- Test (macOS app + Core together): `swift test` (integration tests that block on `.wait()` live in a `.serialized` suite; the default parallel runner stalls otherwise)
- Run macOS app from source: `swift run ProxyLight` (note: launch-at-login can't register from `swift run` — it needs a signed bundle; see Conventions)
- Run CLI from source: `swift run proxylight-cli start` (or `swift run proxylight-cli --help` for the full subcommand list: `start`, `mapping add/list/remove`, `import`, `export`, `ca-path`)
- Package `.app`: `scripts/build-app.sh` → `dist/ProxyLight.app` (bundles the release binary with `packaging/Info.plist` + `ProxyLight.icns`; unsigned)
- Release (signed + notarized): `scripts/release.sh` → `dist/ProxyLight.zip` (build → sign → notarize → staple → zip). Needs a **Developer ID Application** cert (not "Apple Development") + a `ProxyLight-notary` notarytool profile backed by an **App Store Connect API key** (`.p8`) — app-specific passwords proved unreliable when the signing machine has several Apple accounts on different teams. `SKIP_NOTARIZE=1` signs only; `SIGN_IDENTITY=…` overrides identity detection. **Don't move, open, or otherwise touch `dist/ProxyLight.app` while `release.sh` runs** — it operates on that exact path and will fail mid-run. Linux has no equivalent packaging step yet — `swift build --product proxylight-cli` produces a plain debug/release binary only.
- Distribute: attach the zip to a GitHub Release — `gh release create vX.Y.Z dist/ProxyLight.zip --target main --latest`. The README download link points at `/releases/latest`, so it always resolves to the newest release. Bump `CFBundleShortVersionString` in `packaging/Info.plist` to match the tag.

### Verifying the Linux side from a macOS or Linux dev machine

There's no CI job for this yet (see Conventions). To check `ProxyLightCore`/`proxylight-cli` build and test on Linux without a native Linux machine, use the official Docker image — `swift build`/`swift test` against the real `Package.swift` still try to build the macOS-only `ProxyLight`/`ProxyLightTests` targets and fail on `import SwiftUI`, so scope the run to the portable targets:

```
docker run --rm -v "$PWD":/src -w /src swift:6.1 swift build --product proxylight-cli
docker run --rm -v "$PWD":/src -w /src swift:6.1 swift build --target ProxyLightCoreTests
```

For a real `swift test` run (not just a compile check) you need a package manifest that omits the `ProxyLight`/`ProxyLightTests` targets — copy the repo (excluding `.build`), delete `Sources/ProxyLight` and `Tests/ProxyLightTests`, and swap in a `Package.swift` with only `ProxyLightCore`, `proxylight-cli`, and `ProxyLightCoreTests`, then run `swift test` in that copy. Don't commit such a trimmed manifest — it's a throwaway verification step, not a shipped configuration.

## Conventions

- Design specs live in `docs/superpowers/specs/`; read the current spec before implementing.
- `MappingEngine` stays pure (no I/O) so it remains fully unit-testable.
- Proxy listener binds `127.0.0.1` only — never `0.0.0.0`.
- System proxy config is PAC-based: the listener serves `/proxy.pac` (via `PACResponder`) routing only mapped hostnames through the proxy; everything else goes `DIRECT`. Mapped hosts get no `; DIRECT` failover (fail loudly, never silently hit the real origin). `PACResponder` lives on the outer listener pipeline only — never install it in the rebuilt MITM pipeline. Mapping edits while running must bump the PAC URL's `?v=` (macOS caches the PAC by URL).
- HTTP/1.1 only (ALPN offers `http/1.1`); WebSockets on mapped hosts are out of scope for v1.
- CA private key: macOS `~/Library/Application Support/ProxyLight/`, Linux `$XDG_CONFIG_HOME/proxylight` or `~/.config/proxylight` (see `MappingStore.defaultDirectory(environment:)`), mode `0600`, never logged.
- Menu-bar accessory app (`LSUIElement` + `.accessory`): it never becomes frontmost on its own, so anything that opens a window (e.g. Settings) must call `NSApp.activate(ignoringOtherApps:)` or the window opens behind other apps.
- App icon (`packaging/ProxyLight.icns`) is custom-drawn — **never use an SF Symbol as the app icon**; Apple's SF Symbols license forbids it. `build-app.sh` installs the icns; it's declared via `CFBundleIconFile`.
- System-facing side effects go through thin, single-purpose wrappers (`SystemProxyManager`, `CATrustManager`, `LoginItemManager`) so `AppState` orchestration stays clean and the wrappers isolate the untestable I/O. Follow this pattern for new OS integrations. These wrappers, plus `SelfUpdater` and `ProxyRestoreStore`, live under `Sources/ProxyLight/MacOS/` — they're macOS-only by design (Keychain, `networksetup`, code-signing APIs, `SMAppService` have no Linux equivalent) and must never move into `ProxyLightCore`.
- `ProxyOrchestrator` (`Sources/ProxyLightCore/ProxyOrchestrator.swift`) is the single shared control surface: config load/save, the live mapping set, CA access, and NIO listener start/stop — no SwiftUI/`ObservableObject`, no system-proxy coupling. `AppState` wraps it for the macOS app (adds system-proxy snapshot/restore, CA trust, login item, self-update, update checks); `proxylight-cli` drives it directly. Add new *proxy-behavior* logic here so both frontends get it for free; add new *OS-integration* logic as a macOS-only wrapper instead (see above) or, if it's Linux-specific, as a new thin wrapper under `Sources/proxylight-cli/`.
- The CLI is deliberately minimal scope: no automated system-proxy config, no CA auto-trust install, no login-at-boot, no self-update on Linux. `proxylight start` prints the PAC URL and the CA cert path; the user points their browser/OS at the PAC URL and imports the CA cert manually. Don't add Linux system-proxy or trust-store automation without discussing it first — Linux's trust-store/session-startup landscape is fragmented and often needs root, unlike macOS's Keychain/`networksetup`/`SMAppService`.
- CLI signal handling: `DispatchSource` signal sources for SIGINT/SIGTERM must run on a dedicated `DispatchQueue`, never `.main` — the CLI's `run()` blocks the main thread on a semaphore instead of running a run loop, so `.main` never drains and Ctrl-C/kill hangs forever.
- In-app updates: `UpdateChecker` polls the GitHub `releases/latest` API over a proxy-bypassed session (defense-in-depth — with PAC routing, unmapped hosts go DIRECT anyway, but update checks must never depend on the proxy's state), and `SelfUpdater` installs the zip only after the new bundle satisfies the running app's designated requirement (same bundle ID + team). Self-update therefore works only in signed release builds; dev/unsigned builds fall back to a browser download. Release assets must stay a single zip containing `ProxyLight.app`. `UpdateChecker` itself lives in `ProxyLightCore` (portable, no code-signing dependency) but `proxylight-cli` doesn't wire it up — self-update is out of scope for the CLI.
