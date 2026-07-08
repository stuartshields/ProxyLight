#!/usr/bin/env bash
# Build ProxyLight and assemble a macOS .app bundle from the SwiftPM executable.
# Usage: scripts/build-app.sh [output-dir]   (default: dist)
set -euo pipefail

cd "$(dirname "$0")/.."

APP_NAME="ProxyLight"
CONFIG="release"
OUT_DIR="${1:-dist}"
APP="$OUT_DIR/$APP_NAME.app"

echo "==> Building ${APP_NAME} (${CONFIG})..."
swift build -c "$CONFIG"

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"
BIN="$BIN_DIR/$APP_NAME"
if [[ ! -f "$BIN" ]]; then
	echo "error: built executable not found at $BIN" >&2
	exit 1
fi

echo "==> Assembling bundle at ${APP}..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp packaging/Info.plist "$APP/Contents/Info.plist"
cp packaging/ProxyLight.icns "$APP/Contents/Resources/ProxyLight.icns"
# Legacy type/creator file some tooling still checks for.
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Validate the Info.plist and bundle before declaring success.
plutil -lint "$APP/Contents/Info.plist" >/dev/null

echo "==> Built $APP"
echo "    Run it with:  open \"$APP\""
echo "    Note: unsigned — first launch needs right-click > Open (or a Developer ID signature to distribute)."
