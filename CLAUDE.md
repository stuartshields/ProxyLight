# ProxyLight

Lightweight macOS menu bar app: a local HTTP/HTTPS proxy that rewrites user-mapped URL patterns to remote origins (e.g. `https://myapp.example.com/tachyon/*` → `https://origin.example.net/tachyon/*`).

## Stack

- Swift 6 Package executable (no Xcode project) — macOS 14+, **Apple Silicon**. `swift build` compiles for the host arch only, so the shipped bundle is arm64-only; a universal build needs `swift build --arch arm64 --arch x86_64`.
- SwiftUI `MenuBarExtra` for UI. `ServiceManagement` (`SMAppService`) for launch-at-login.
- SwiftNIO stack: `apple/swift-nio`, `apple/swift-nio-ssl`, `apple/swift-certificates`. No other dependencies without asking.

## Commands

- Build: `swift build`
- Test: `swift test` (integration tests that block on `.wait()` live in a `.serialized` suite; the default parallel runner stalls otherwise)
- Run: `swift run ProxyLight` (note: launch-at-login can't register from `swift run` — it needs a signed bundle; see Conventions)
- Package `.app`: `scripts/build-app.sh` → `dist/ProxyLight.app` (bundles the release binary with `packaging/Info.plist` + `ProxyLight.icns`; unsigned)
- Release (signed + notarized): `scripts/release.sh` → `dist/ProxyLight.zip` (build → sign → notarize → staple → zip). Needs a **Developer ID Application** cert (not "Apple Development") + a `ProxyLight-notary` notarytool profile backed by an **App Store Connect API key** (`.p8`) — app-specific passwords proved unreliable when the signing machine has several Apple accounts on different teams. `SKIP_NOTARIZE=1` signs only; `SIGN_IDENTITY=…` overrides identity detection. **Don't move, open, or otherwise touch `dist/ProxyLight.app` while `release.sh` runs** — it operates on that exact path and will fail mid-run.
- Distribute: attach the zip to a GitHub Release — `gh release create vX.Y.Z dist/ProxyLight.zip --target main --latest`. The README download link points at `/releases/latest`, so it always resolves to the newest release. Bump `CFBundleShortVersionString` in `packaging/Info.plist` to match the tag.

## Conventions

- Design specs live in `docs/superpowers/specs/`; read the current spec before implementing.
- `MappingEngine` stays pure (no I/O) so it remains fully unit-testable.
- Proxy listener binds `127.0.0.1` only — never `0.0.0.0`.
- System proxy config is PAC-based: the listener serves `/proxy.pac` (via `PACResponder`) routing only mapped hostnames through the proxy; everything else goes `DIRECT`. Mapped hosts get no `; DIRECT` failover (fail loudly, never silently hit the real origin). `PACResponder` lives on the outer listener pipeline only — never install it in the rebuilt MITM pipeline. Mapping edits while running must bump the PAC URL's `?v=` (macOS caches the PAC by URL).
- HTTP/1.1 only (ALPN offers `http/1.1`); WebSockets on mapped hosts are out of scope for v1.
- CA private key: `~/Library/Application Support/ProxyLight/`, mode `0600`, never logged.
- Menu-bar accessory app (`LSUIElement` + `.accessory`): it never becomes frontmost on its own, so anything that opens a window (e.g. Settings) must call `NSApp.activate(ignoringOtherApps:)` or the window opens behind other apps.
- App icon (`packaging/ProxyLight.icns`) is custom-drawn — **never use an SF Symbol as the app icon**; Apple's SF Symbols license forbids it. `build-app.sh` installs the icns; it's declared via `CFBundleIconFile`.
- System-facing side effects go through thin, single-purpose wrappers (`SystemProxyManager`, `CATrustManager`, `LoginItemManager`) so `AppState` orchestration stays clean and the wrappers isolate the untestable I/O. Follow this pattern for new OS integrations.
- In-app updates: `UpdateChecker` polls the GitHub `releases/latest` API over a proxy-bypassed session (defense-in-depth — with PAC routing, unmapped hosts go DIRECT anyway, but update checks must never depend on the proxy's state), and `SelfUpdater` installs the zip only after the new bundle satisfies the running app's designated requirement (same bundle ID + team). Self-update therefore works only in signed release builds; dev/unsigned builds fall back to a browser download. Release assets must stay a single zip containing `ProxyLight.app`.
