#!/usr/bin/env bash
#
# build_app_bundle.sh — Assemble a proper .app bundle for SessionCopilot
# and ad-hoc sign it with a stable identifier.
#
# WHY THIS SCRIPT EXISTS
# -----------------------
# `swift run` produces a bare executable at .build/debug/SessionCopilot.
# That executable has no Info.plist, no bundle identifier, and is
# regenerated on every build. macOS TCC (Privacy & Security) tracks
# permissions by (bundle ID, executable CDHash, executable path). A
# `swift run` binary's CDHash changes on every build, so previously
# granted Screen Recording / Microphone / Speech Recognition permissions
# silently become invalid.
#
# SCStream's specific failure mode under missing/unstable TCC grant is:
#   - `startCapture()` returns noErr
#   - Delegate callback `stream(_:didOutputSampleBuffer:of:)` never fires
#   - No errors, no stops — the stream is a "running zombie"
#
# Bundling as a .app with a stable identifier + ad-hoc signature makes
# TCC grants persist across rebuilds and causes the system to actually
# prompt the user for permissions.
#
# USAGE
# -----
#   cd /path/to/SessionCopilot
#   ./scripts/build_app_bundle.sh             # build release + bundle
#   ./scripts/build_app_bundle.sh --debug     # build debug + bundle
#   ./scripts/build_app_bundle.sh --install   # also copies to /Applications
#
# REQUIREMENTS
# ------------
# - Swift 6.0+ toolchain (Xcode 16+ on macOS 14+)
# - macOS 14+ (Sonoma) for SCStream audio capture
# - `codesign` (ships with Xcode Command Line Tools)

set -euo pipefail

# ---- Configuration ---------------------------------------------------------

BUNDLE_ID="com.sessioncopilot.app"
APP_NAME="SessionCopilot"
CONFIGURATION="release"
INSTALL=false

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug)   CONFIGURATION="debug"; shift ;;
        --install) INSTALL=true; shift ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# Resolve repo root (directory containing Package.swift).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

if [[ ! -f "$REPO_ROOT/Package.swift" ]]; then
    echo "ERROR: Package.swift not found at $REPO_ROOT" >&2
    exit 1
fi

cd "$REPO_ROOT"

echo ">> Building ($CONFIGURATION)..."
if [[ "$CONFIGURATION" == "release" ]]; then
    swift build -c release
    BUILD_DIR=".build/release"
else
    swift build
    BUILD_DIR=".build/debug"
fi

BINARY="$BUILD_DIR/$APP_NAME"
if [[ ! -x "$BINARY" ]]; then
    echo "ERROR: Built binary not found at $BINARY" >&2
    exit 1
fi

# ---- Assemble bundle -------------------------------------------------------

STAGE_DIR="$REPO_ROOT/.build/app-stage"
APP_ROOT="$STAGE_DIR/$APP_NAME.app"

echo ">> Assembling .app bundle..."
rm -rf "$APP_ROOT"
mkdir -p "$APP_ROOT/Contents/MacOS"
mkdir -p "$APP_ROOT/Contents/Resources"

# Copy binary
cp "$BINARY" "$APP_ROOT/Contents/MacOS/$APP_NAME"

# Copy Info.plist (must live at Contents/Info.plist)
cp "$REPO_ROOT/Resources/Info.plist" "$APP_ROOT/Contents/Info.plist"

# Copy entitlements into the bundle for reference (not strictly required
# by macOS, but useful for debugging and for codesign to discover).
cp "$REPO_ROOT/Resources/SessionCopilot.entitlements" \
   "$APP_ROOT/Contents/Resources/SessionCopilot.entitlements"

# ---- Codesign --------------------------------------------------------------

ENTITLEMENTS_PATH="$APP_ROOT/Contents/Resources/SessionCopilot.entitlements"

echo ">> Ad-hoc signing with identifier=$BUNDLE_ID..."
# Ad-hoc sign (--sign -) with a stable --identifier. The identifier
# becomes the bundle's TCC identity. Use the same identifier on every
# rebuild so TCC grants persist.
#
# --options runtime enables the Hardened Runtime, which is required
# for Speech Recognition (SFSpeechRecognizer) and is generally good
# practice. Some framework features (e.g., System Integrity Protection
# overrides) require it.
#
# --force re-signs even if already signed.
codesign \
    --force \
    --identifier "$BUNDLE_ID" \
    --sign - \
    --entitlements "$ENTITLEMENTS_PATH" \
    --options runtime \
    --timestamp=none \
    "$APP_ROOT"

# ---- Verify ----------------------------------------------------------------

echo ">> Verifying signature..."
codesign --verify --verbose=2 "$APP_ROOT" 2>&1 || {
    echo "ERROR: codesign verification failed" >&2
    exit 1
}

echo ">> Bundle contents:"
find "$APP_ROOT" -type f | sed "s|$APP_ROOT/||"

# ---- Install (optional) ----------------------------------------------------

if $INSTALL; then
    echo ">> Installing to /Applications/..."
    # Remove any prior copy. Use rm -rf since /Applications may have a
    # symlink or directory there.
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP_ROOT" "/Applications/$APP_NAME.app"
    echo ">> Installed: /Applications/$APP_NAME.app"
    echo
    echo "First-launch TCC setup:"
    echo "  1. Launch /Applications/SessionCopilot.app"
    echo "  2. macOS will prompt for Microphone, Speech Recognition, and Screen Recording."
    echo "  3. Open System Settings → Privacy & Security → Screen Recording and enable SessionCopilot."
    echo "  4. If permissions are stale, reset them:"
    echo "       tccutil reset ScreenCapture"
    echo "       tccutil reset Microphone"
    echo "       tccutil reset SpeechRecognition"
    echo "  5. Relaunch SessionCopilot."
else
    echo
    echo "Bundle assembled at: $APP_ROOT"
    echo "To install: cp -R \"$APP_ROOT\" /Applications/"
fi

# ---- Run hint --------------------------------------------------------------

echo
echo "To run from the staged bundle (no install):"
echo "  open \"$APP_ROOT\""
echo
echo "To stream debug logs while running:"
echo "  log stream --predicate 'subsystem == \"com.apple.ScreenCaptureKit\" OR subsystem == \"com.apple.TCC\"' --level debug"
