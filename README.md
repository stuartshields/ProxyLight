# ProxyLight

Point a URL at a different origin without touching DNS, hosts files, or your app's config. ProxyLight runs a local proxy and rewrites URLs you map to a remote target — including HTTPS, transparently. It ships as a macOS menu bar app, and as a Linux CLI from the same codebase.

Example: serve `https://myapp.example.com/assets/*` from `https://origin.example.net/assets/*` while your browser still shows the original address.

## Requirements

- **macOS app**: macOS 14 or later, on an Apple Silicon Mac.
- **Linux CLI**: any Linux distribution with a Swift 6 toolchain; no packaged binary yet, build from source (see [Linux CLI](#linux-cli)).
- To build from source: Swift 6 toolchain (Xcode 16+ on macOS, or the Swift toolchain on Linux).

## Install (macOS app)

1. Download `ProxyLight.zip` from the [latest release](https://github.com/stuartshields/ProxyLight/releases/latest).
2. Unzip it and drag `ProxyLight.app` to `/Applications`.
3. Double-click to open. The app is signed and notarized, so it opens without a security warning.

ProxyLight has no dock icon — after it launches, look for its icon in the menu bar at the top of the screen.

Prefer to build it yourself? See [Development](#development).

## First steps

1. **Open the menu.** Click the ProxyLight icon in the menu bar, then choose **Edit Mappings…** to open Settings.
2. **Trust the certificate** (needed for HTTPS mappings). In Settings → **Certificate Authority**, click **Trust Certificate…**. This adds ProxyLight's certificate to your login keychain — no admin password required — and Safari and Chrome honor it right away. Reload the page (or restart the browser) so it picks up the new trust.
3. **Add a mapping.** Click **Add Mapping…**. Enter the address you visit under **From** and the real origin under **To**. A trailing `*` maps everything under a path prefix:
   - From: `https://myapp.example.com/assets/*`
   - To: `https://origin.example.net/assets/*`
4. **Turn the proxy on.** Back in the menu, click **Turn Proxy On**. ProxyLight configures a PAC (Automatic Proxy Configuration) URL — `http://127.0.0.1:<port>/proxy.pac` — instead of a global proxy: only hosts with mappings route through ProxyLight, and everything else connects directly, with zero added latency and HTTP/3 intact. Turning it off restores your previous network settings.
5. **Browse.** Requests that match a mapping are rewritten to the remote origin. The original address stays in the address bar.

## Why the certificate step matters

To rewrite HTTPS traffic, ProxyLight decrypts and re-encrypts requests for the hosts you map. It signs those connections with a local certificate authority created on first run. Trusting that certificate (step 2) is what lets your browser accept the rewritten HTTPS responses instead of warning about them.

The certificate is trusted only for your user account, never system-wide. If the menu shows *"HTTPS mappings inactive"*, the certificate authority is unavailable and HTTPS traffic passes through untouched — plain HTTP mappings still work.

## Mapping modes

- **Rewrite** (default): matching requests always go to the remote target.
- **Fallback on 404**: the local origin is served first; on a miss (404 or a wrong content type), ProxyLight refetches from the remote target. Useful when most assets exist locally and only some are missing.

Toggle individual mappings on and off from the menu. Use **Import…** / **Export…** in Settings to share mappings as a JSON file.

## Notes and limits

- The proxy listens on `127.0.0.1` only — it is never exposed to the network.
- HTTP/1.1 only. WebSockets on mapped hosts are not supported.
- The default listen port is `9876` (change it in Settings → Proxy, or with `proxylight start --port` on Linux).
- The CA private key lives in `~/Library/Application Support/ProxyLight/` (macOS) or `$XDG_CONFIG_HOME/proxylight`/`~/.config/proxylight` (Linux).
- If ProxyLight quits or crashes, normal browsing is unaffected — macOS falls back to `DIRECT` once the PAC URL stops responding. Only mapped hosts stop resolving until the app restarts or you turn the proxy off to restore your previous settings.

## Linux CLI

There's no packaged binary yet — build `proxylight-cli` from source with a Swift 6 toolchain:

```
swift build --product proxylight-cli
```

Unlike the macOS app, the CLI doesn't touch system proxy settings or the OS certificate trust store — Linux has no single equivalent to `networksetup`/Keychain, so those steps are manual:

1. **Add a mapping**: `swift run proxylight-cli mapping add "https://myapp.example.com/assets/*" "https://origin.example.net/assets/*"`
2. **Start the proxy**: `swift run proxylight-cli start`. This prints the PAC URL (`http://127.0.0.1:<port>/proxy.pac`) and the path to the generated CA certificate.
3. **Point your browser at the PAC URL** (its network/proxy settings — same idea as step 4 of First steps above, just configured manually instead of by the app) and **import the CA certificate** printed above into your browser's trust store, so it accepts the rewritten HTTPS responses.
4. Stop the proxy with Ctrl-C — it shuts down cleanly.

Other subcommands: `mapping list`, `mapping remove <id>`, `import <file>`, `export <file>`, `ca-path`. Run `proxylight-cli --help` for the full reference.

## Development

- Build (macOS app): `swift build`
- Build (Linux CLI): `swift build --product proxylight-cli`
- Test: `swift test` (macOS; builds and tests the app target too)
- Run macOS app from source: `swift run ProxyLight`
- Run CLI from source: `swift run proxylight-cli start`
- Package the app bundle: `scripts/build-app.sh` → `dist/ProxyLight.app`

See `CLAUDE.md` for architecture and packaging details.
