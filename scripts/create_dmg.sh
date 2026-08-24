#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="ClipboardSS"
APP_BUNDLE="build/${APP_NAME}.app"
DMG_NAME="build/${APP_NAME}.dmg"
VOL_NAME="${APP_NAME}"

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "Error: App bundle not found at $APP_BUNDLE."
    echo "Please run ./scripts/build_app.sh first."
    exit 1
fi

echo "Creating staging directory for DMG..."
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/clipboardss-dmg.XXXXXX")"

# Ensure cleanup of the temporary staging directory on exit
cleanup() {
    rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

# Copy the app bundle to the staging directory
echo "Copying app bundle..."
ditto "$APP_BUNDLE" "$STAGING_DIR/${APP_NAME}.app"

# Create a symlink to /Applications to allow easy drag-and-drop installation
echo "Creating Applications symlink..."
ln -s /Applications "$STAGING_DIR/Applications"

# Remove existing DMG if it exists to avoid hdiutil errors
if [[ -f "$DMG_NAME" ]]; then
    rm "$DMG_NAME"
fi

echo "Generating DMG..."
# Use hdiutil to create a compressed DMG from the staging directory
hdiutil create \
  -volname "$VOL_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov -format UDZO \
  "$DMG_NAME"

echo "✅ Successfully created DMG at $DMG_NAME"
echo "You can now share this DMG file. Users can open it and drag $APP_NAME to their Applications folder."
