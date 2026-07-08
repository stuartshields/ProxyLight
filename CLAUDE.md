# ProxyLight

Lightweight macOS menu bar app: a local HTTP/HTTPS proxy that rewrites user-mapped URL patterns to remote origins (e.g. `https://myapp.example.com/tachyon/*` → `https://origin.example.net/tachyon/*`).

## Stack

- Swift 6 Package executable (no Xcode project) — macOS 14+.
- SwiftUI `MenuBarExtra` for UI.
- SwiftNIO stack: `apple/swift-nio`, `apple/swift-nio-ssl`, `apple/swift-certificates`. No other dependencies without asking.

## Commands

- Build: `swift build`
- Test: `swift test` (integration tests that block on `.wait()` live in a `.serialized` suite; the default parallel runner stalls otherwise)
- Run: `swift run ProxyLight`
- Package `.app`: `scripts/build-app.sh` → `dist/ProxyLight.app` (bundles the release binary with `packaging/Info.plist`; unsigned)
- Release (signed + notarized): `scripts/release.sh` → `dist/ProxyLight.zip`. Needs a **Developer ID Application** cert (not "Apple Development") + a `ProxyLight-notary` notarytool credential profile. `SKIP_NOTARIZE=1` signs only; `SIGN_IDENTITY=…` overrides identity detection.

## Conventions

- Design specs live in `docs/superpowers/specs/`; read the current spec before implementing.
- `MappingEngine` stays pure (no I/O) so it remains fully unit-testable.
- Proxy listener binds `127.0.0.1` only — never `0.0.0.0`.
- HTTP/1.1 only (ALPN offers `http/1.1`); WebSockets on mapped hosts are out of scope for v1.
- CA private key: `~/Library/Application Support/ProxyLight/`, mode `0600`, never logged.
