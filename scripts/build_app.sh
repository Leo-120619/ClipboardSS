#!/usr/bin/env bash
set -euo pipefail

INSTALL_APP=0
if [[ "${1:-}" == "--install" ]]; then
    INSTALL_APP=1
elif [[ "${1:-}" != "" ]]; then
    echo "Usage: $0 [--install]" >&2
    exit 64
fi

CLEANUP_DIRS=()
cleanup() {
    for dir in "${CLEANUP_DIRS[@]}"; do
        rm -rf "$dir"
    done
}
trap cleanup EXIT

generate_app_icon() {
    local source_icon="Assets/clipboard.png"
    local resources_dir="$APP_DIR/Contents/Resources"

    if [[ ! -f "$source_icon" ]]; then
        echo "Missing app icon source: $source_icon" >&2
        exit 66
    fi

    cp "$source_icon" "$resources_dir/clipboard.png"

    local iconset_root
    iconset_root="$(mktemp -d "${TMPDIR:-/tmp}/clipboardss-iconset.XXXXXX")"
    CLEANUP_DIRS+=("$iconset_root")

    local iconset="$iconset_root/clipboard.iconset"
    mkdir -p "$iconset"

    for size in 16 32 128 256 512; do
        sips -z "$size" "$size" "$source_icon" --out "$iconset/icon_${size}x${size}.png" >/dev/null
        local double_size=$((size * 2))
        sips -z "$double_size" "$double_size" "$source_icon" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
    done

    iconutil -c icns "$iconset" -o "$resources_dir/clipboard.icns"
}

swift build -c release

REPO_BUILD_APP_DIR="build/ClipboardSS.app"
INSTALL_DIR="/Applications/ClipboardSS.app"

if [[ "$INSTALL_APP" == "1" ]]; then
    STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/clipboardss-install.XXXXXX")"
    CLEANUP_DIRS+=("$STAGING_ROOT")
    APP_DIR="$STAGING_ROOT/ClipboardSS.app"
else
    APP_DIR="$REPO_BUILD_APP_DIR"
fi

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp ".build/release/ClipboardSS" "$APP_DIR/Contents/MacOS/ClipboardSS"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>ClipboardSS</string>
    <key>CFBundleExecutable</key>
    <string>ClipboardSS</string>
    <key>CFBundleIconFile</key>
    <string>clipboard</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.ClipboardSS</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>ClipboardSS</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 ClipboardSS</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

generate_app_icon

DEFAULT_SIGN_IDENTITY="ClipboardSS Local Code Signing"
if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
    SIGN_IDENTITY="$CODESIGN_IDENTITY"
elif security find-identity -v -p codesigning | grep -F "\"$DEFAULT_SIGN_IDENTITY\"" >/dev/null; then
    SIGN_IDENTITY="$DEFAULT_SIGN_IDENTITY"
else
    SIGN_IDENTITY="-"
fi

if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "Warning: no code-signing identity found; using ad-hoc signing for local development." >&2
else
    echo "Signing with identity: $SIGN_IDENTITY"
fi

codesign --force --deep --sign "$SIGN_IDENTITY" "$APP_DIR" >/dev/null

echo "Built $APP_DIR"

if [[ "$INSTALL_APP" == "1" ]]; then
    rm -rf "$INSTALL_DIR"
    ditto "$APP_DIR" "$INSTALL_DIR"
    codesign --force --deep --sign "$SIGN_IDENTITY" "$INSTALL_DIR" >/dev/null
    echo "Installed $INSTALL_DIR"
    rm -rf "$REPO_BUILD_APP_DIR"
    find .build -path "*/ClipboardSS.app" -prune -exec rm -rf {} +
    echo "Removed repo-local app bundles from build outputs"
fi
