#!/usr/bin/env bash
set -euo pipefail

# Builds ClipboardSS (with its embedded Share Extension) via xcodebuild.
# The extension can only be compiled/embedded by Xcode, not `swift build`, so this
# script generates the project with xcodegen, builds unsigned, stamps the icon, then
# code-signs inside-out with the SynCity FZE Developer ID identity, the embedded
# provisioning profile, and the entitlement files.

INSTALL_APP=0
if [[ "${1:-}" == "--install" ]]; then
    INSTALL_APP=1
elif [[ "${1:-}" != "" ]]; then
    echo "Usage: $0 [--install]" >&2
    exit 64
fi

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# xcodebuild needs a full Xcode; the active developer dir is often just the CLTs.
source "$REPO_ROOT/scripts/xcode_env.sh"

CLEANUP_DIRS=()
cleanup() {
    for dir in ${CLEANUP_DIRS[@]+"${CLEANUP_DIRS[@]}"}; do
        rm -rf "$dir"
    done
}
trap cleanup EXIT

generate_app_icon() {
    local app_dir="$1"
    local source_icon="Assets/clipboard.png"
    local resources_dir="$app_dir/Contents/Resources"

    if [[ ! -f "$source_icon" ]]; then
        echo "Missing app icon source: $source_icon" >&2
        exit 66
    fi

    mkdir -p "$resources_dir"
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

# 1. Regenerate the Xcode project from project.yml.
xcodegen generate

# 2. Build unsigned (we sign manually below with the entitlement files).
SYMROOT="$REPO_ROOT/build/sym"
rm -rf "$SYMROOT"
xcodebuild \
    -project ClipboardSS.xcodeproj \
    -target ClipboardSS \
    -configuration Release \
    SYMROOT="$SYMROOT" \
    CODE_SIGNING_ALLOWED=NO \
    DEBUG_INFORMATION_FORMAT=dwarf \
    build

BUILT_APP="$SYMROOT/Release/ClipboardSS.app"
if [[ ! -d "$BUILT_APP" ]]; then
    echo "Build did not produce $BUILT_APP" >&2
    exit 70
fi

# 3. Choose destination bundle.
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
mkdir -p "$(dirname "$APP_DIR")"
ditto "$BUILT_APP" "$APP_DIR"
# iCloud Drive tags build products with extended attributes that codesign rejects
# ("resource fork, Finder information, or similar detritus not allowed").
xattr -cr "$APP_DIR"

# 4. Stamp the app icon.
generate_app_icon "$APP_DIR"

# 5. Resolve the signing identity. The app carries restricted keychain entitlements
#    (Touch ID-guarded pair keys), so it must be signed by team H2GP3VABB6 with the
#    matching provisioning profile embedded, or macOS refuses to launch it.
TEAM_ID="H2GP3VABB6"
PROFILE="$REPO_ROOT/Signing/ClipboardSS.provisionprofile"
DEFAULT_SIGN_IDENTITY="Developer ID Application: SynCity FZE ($TEAM_ID)"
SIGN_IDENTITY="${CODESIGN_IDENTITY:-$DEFAULT_SIGN_IDENTITY}"
if ! security find-identity -v -p codesigning | grep -F "\"$SIGN_IDENTITY\"" >/dev/null; then
    echo "Error: signing identity not found: $SIGN_IDENTITY" >&2
    echo "Install the SynCity FZE Developer ID certificate, or set CODESIGN_IDENTITY to another" >&2
    echo "team $TEAM_ID identity from: security find-identity -v -p codesigning" >&2
    exit 1
fi
if [[ "$SIGN_IDENTITY" != *"($TEAM_ID)"* ]]; then
    echo "Error: $SIGN_IDENTITY is not a team $TEAM_ID identity; the app would not launch." >&2
    exit 1
fi
if [[ ! -f "$PROFILE" ]]; then
    echo "Missing provisioning profile: $PROFILE" >&2
    exit 66
fi
cp "$PROFILE" "$APP_DIR/Contents/embedded.provisionprofile"
echo "Signing with identity: $SIGN_IDENTITY"

# 6. Sign inside-out: the extension first, then the app.
APPEX="$APP_DIR/Contents/PlugIns/ShareExtension.appex"
if [[ -d "$APPEX" ]]; then
    codesign --force --options runtime --timestamp=none \
        --entitlements ShareExtension.entitlements \
        --sign "$SIGN_IDENTITY" "$APPEX"
else
    echo "Warning: ShareExtension.appex missing from build output — share sheet won't appear." >&2
fi
codesign --force --options runtime --timestamp=none \
    --entitlements ClipboardSS.entitlements \
    --sign "$SIGN_IDENTITY" "$APP_DIR"

codesign --verify --deep --strict "$APP_DIR"
echo "Built $APP_DIR"

# 7. Install if requested.
if [[ "$INSTALL_APP" == "1" ]]; then
    rm -rf "$INSTALL_DIR"
    ditto "$APP_DIR" "$INSTALL_DIR"
    # Register with LaunchServices so the share extension is discovered immediately.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -f "$INSTALL_DIR" >/dev/null 2>&1 || true
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -u "$APP_DIR" >/dev/null 2>&1 || true
    rm -rf "$APP_DIR"
    # Drop the unsigned intermediate too, or Launchpad shows it as a second, iconless copy.
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
        -u "$BUILT_APP" >/dev/null 2>&1 || true
    rm -rf "$SYMROOT"
    echo "Installed $INSTALL_DIR"
fi
