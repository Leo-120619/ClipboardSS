#!/usr/bin/env bash
# Resolves a full Xcode toolchain and exports DEVELOPER_DIR.
#
# `xcode-select -p` often points at /Library/Developer/CommandLineTools, which has
# no xcodebuild and cannot load the SwiftUI macro plugin (`swift build` then fails
# with ~114 "SwiftUIMacros.StateMacro could not be found" errors). Rather than
# requiring `sudo xcode-select -s`, every entry point sources this file.
#
# Usage:
#   source "$(dirname "$0")/xcode_env.sh"     # from a script
#   . scripts/xcode_env.sh && swift build     # from a shell

_clipboardss_is_full_xcode() {
    [[ -n "$1" && -x "$1/usr/bin/xcodebuild" ]]
}

# Normalizes "/path/Xcode.app" to "/path/Xcode.app/Contents/Developer".
_clipboardss_developer_dir() {
    local path="$1"
    if [[ "$path" == *.app ]]; then
        path="$path/Contents/Developer"
    fi
    printf '%s' "$path"
}

_clipboardss_resolve_xcode() {
    local candidate

    # 1. An explicit DEVELOPER_DIR from the caller always wins.
    if [[ -n "${DEVELOPER_DIR:-}" ]]; then
        candidate="$(_clipboardss_developer_dir "$DEVELOPER_DIR")"
        if _clipboardss_is_full_xcode "$candidate"; then
            printf '%s' "$candidate"
            return 0
        fi
        echo "Warning: DEVELOPER_DIR=$DEVELOPER_DIR is not a full Xcode; ignoring it." >&2
    fi

    # 2. The active developer directory, if it is a full Xcode rather than CLT.
    candidate="$(xcode-select -p 2>/dev/null || true)"
    if _clipboardss_is_full_xcode "$candidate"; then
        printf '%s' "$candidate"
        return 0
    fi

    # 3. Any Xcode installed anywhere on the machine, newest bundle version first.
    local app
    while IFS= read -r app; do
        [[ -n "$app" ]] || continue
        candidate="$(_clipboardss_developer_dir "$app")"
        if _clipboardss_is_full_xcode "$candidate"; then
            printf '%s' "$candidate"
            return 0
        fi
    done < <(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null)

    # 4. Spotlight can be disabled or the app unindexed; try the usual locations.
    for app in /Applications/Xcode.app /Applications/Xcode-beta.app \
               "$HOME/Applications/Xcode.app" "$HOME/Applications/Xcode-beta.app" \
               "$HOME/Downloads/Xcode.app" "$HOME/Downloads/Xcode-beta.app"; do
        candidate="$(_clipboardss_developer_dir "$app")"
        if _clipboardss_is_full_xcode "$candidate"; then
            printf '%s' "$candidate"
            return 0
        fi
    done

    return 1
}

if _clipboardss_developer_dir_resolved="$(_clipboardss_resolve_xcode)"; then
    export DEVELOPER_DIR="$_clipboardss_developer_dir_resolved"
    unset _clipboardss_developer_dir_resolved
else
    echo "Error: no full Xcode installation found." >&2
    echo "ClipboardSS needs Xcode (not just the Command Line Tools) for xcodebuild and the SwiftUI macro plugin." >&2
    echo "Install Xcode, or set DEVELOPER_DIR to an existing one, e.g.:" >&2
    echo "  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer" >&2
    return 1 2>/dev/null || exit 69
fi

unset -f _clipboardss_is_full_xcode _clipboardss_developer_dir _clipboardss_resolve_xcode
