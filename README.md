# ProxyLight

Point a URL at a different origin without touching DNS, hosts files, or your app's config. ProxyLight is a macOS menu bar app that runs a local proxy and rewrites URLs you map to a remote target — including HTTPS, transparently.

Example: serve `https://myapp.example.com/assets/*` from `https://origin.example.net/assets/*` while your browser still shows the original address.

## Requirements

- macOS 14 or later.
- To build from source: Swift 6 toolchain (Xcode 16+ or the Swift toolchain).

## Install

Grab `ProxyLight.app` (from a release zip or `scripts/build-app.sh`), move it to `/Applications`, and open it. ProxyLight has no dock icon — look for its icon in the menu bar at the top of the screen.

To build the app bundle yourself:

```
scripts/build-app.sh      # → dist/ProxyLight.app
```

## First steps

1. **Open the menu.** Click the ProxyLight icon in the menu bar, then choose **Edit Mappings…** to open Settings.
2. **Trust the certificate** (needed for HTTPS mappings). In Settings → **Certificate Authority**, click **Trust Certificate…**. This adds ProxyLight's certificate to your login keychain — no admin password required — and Safari and Chrome honor it right away. Reload the page (or restart the browser) so it picks up the new trust.
3. **Add a mapping.** Click **Add Mapping…**. Enter the address you visit under **From** and the real origin under **To**. A trailing `*` maps everything under a path prefix:
   - From: `https://myapp.example.com/assets/*`
   - To: `https://origin.example.net/assets/*`
4. **Turn the proxy on.** Back in the menu, click **Turn Proxy On**. ProxyLight points your Mac's system proxy at itself automatically; turning it off restores your previous network settings.
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
- The default listen port is `9876` (change it in Settings → Proxy).
- The CA private key lives in `~/Library/Application Support/ProxyLight/`.

## Development

- Build: `swift build`
- Test: `swift test`
- Run from source: `swift run ProxyLight`

See `CLAUDE.md` for architecture and packaging details.
