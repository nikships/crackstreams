#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-debug}"
UNIVERSAL="${UNIVERSAL:-0}"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
CODESIGN_KEYCHAIN="${CODESIGN_KEYCHAIN:-}"
APP="$ROOT/dist/Crackstreams.app"

cd "$ROOT"
if [[ "$UNIVERSAL" == "1" ]]; then
  swift build -c "$CONFIGURATION" --arch arm64 --arch x86_64
  BIN_DIR="$(swift build -c "$CONFIGURATION" --arch arm64 --arch x86_64 --show-bin-path)"
else
  swift build -c "$CONFIGURATION"
  BIN_DIR="$(swift build -c "$CONFIGURATION" --show-bin-path)"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Crackstreams" "$APP/Contents/MacOS/Crackstreams"
# ditto keeps the framework's symlinks, which its code signature depends on.
ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Assets/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
plutil -lint "$APP/Contents/Info.plist" >/dev/null

if [[ "$SIGN_IDENTITY" == "" ]]; then
  # Sparkle ships ad-hoc signed, which is enough for an unsandboxed development build.
  codesign --force --sign - --timestamp=none "$APP"
else
  SIGN=(codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp)
  if [[ -n "$CODESIGN_KEYCHAIN" ]]; then SIGN+=(--keychain "$CODESIGN_KEYCHAIN"); fi
  # Sign Sparkle's helpers innermost first and never with --deep; see
  # https://sparkle-project.org/documentation/sandboxing/#code-signing
  SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
  "${SIGN[@]}" "$SPARKLE/Versions/B/XPCServices/Installer.xpc"
  "${SIGN[@]}" --preserve-metadata=entitlements "$SPARKLE/Versions/B/XPCServices/Downloader.xpc"
  "${SIGN[@]}" "$SPARKLE/Versions/B/Autoupdate"
  "${SIGN[@]}" "$SPARKLE/Versions/B/Updater.app"
  "${SIGN[@]}" "$SPARKLE"
  "${SIGN[@]}" --entitlements "$ROOT/Config/Entitlements.plist" "$APP"
fi
codesign --verify --deep --strict --verbose=2 "$APP"
printf 'Built %s\n' "$APP"
