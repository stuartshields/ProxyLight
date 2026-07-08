#!/usr/bin/env bash
# Build, sign, notarize, and package ProxyLight.app for distribution outside the
# Mac App Store. Produces dist/ProxyLight.zip, ready to send.
#
# Requirements:
#   - A "Developer ID Application" certificate in your login keychain
#     (Xcode > Settings > Accounts > Manage Certificates > + >
#      "Developer ID Application"; needs a paid Apple Developer Program).
#   - A stored notarytool credential profile (default name: ProxyLight-notary):
#       xcrun notarytool store-credentials "ProxyLight-notary" \
#         --apple-id "you@example.com" --team-id "TEAMID" \
#         --password "<app-specific-password>"
#
# Env vars:
#   NOTARY_PROFILE   notarytool keychain profile name (default: ProxyLight-notary)
#   SIGN_IDENTITY    override the auto-detected signing identity
#   SKIP_NOTARIZE=1  sign only, skip notarization/stapling (for local testing)
#   OUT_DIR          output directory (default: dist)
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="ProxyLight"
OUT_DIR="${OUT_DIR:-dist}"
APP="$OUT_DIR/$APP_NAME.app"
ZIP="$OUT_DIR/$APP_NAME.zip"
NOTARY_PROFILE="${NOTARY_PROFILE:-ProxyLight-notary}"

# 1. Build the .app bundle.
scripts/build-app.sh "$OUT_DIR"

# 2. Resolve the Developer ID Application signing identity.
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/{print $2; exit}')}"
if [[ -z "${IDENTITY:-}" ]]; then
	cat >&2 <<'MSG'
error: no "Developer ID Application" certificate found in your keychain.
       Create one in Xcode > Settings > Accounts > Manage Certificates > + >
       "Developer ID Application" (requires a paid Apple Developer Program
       membership), then re-run. You can override detection with SIGN_IDENTITY=...
MSG
	exit 1
fi
echo "==> Signing with: $IDENTITY"

# 3. Sign with a hardened runtime + secure timestamp (both required to notarize).
#    The bundle has no nested code, so one signing pass covers app + executable.
codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

if [[ "${SKIP_NOTARIZE:-0}" == "1" ]]; then
	ditto -c -k --keepParent "$APP" "$ZIP"
	echo "==> Signed (notarization skipped): $ZIP"
	echo "    Without notarization, other Macs still warn on first open."
	exit 0
fi

# 4. Zip and submit for notarization (notarytool accepts a zip).
echo "==> Notarizing via profile '$NOTARY_PROFILE' (can take a few minutes)..."
ditto -c -k --keepParent "$APP" "$ZIP"
xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait

# 5. Staple the ticket so Gatekeeper accepts it offline, then re-zip the stapled app.
xcrun stapler staple "$APP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

# 6. Confirm Gatekeeper will accept it.
echo "==> Gatekeeper assessment:"
spctl --assess --type execute --verbose=4 "$APP" || true

echo "==> Done: $ZIP (signed, notarized, stapled) — ready to distribute."
