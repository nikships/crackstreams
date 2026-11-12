#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:?Set VERSION, for example 1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
SIGN_IDENTITY="${SIGN_IDENTITY:?Set SIGN_IDENTITY to your Developer ID Application identity}"
APPLE_ID="${APPLE_ID:?Set APPLE_ID for notarization}"
APPLE_PASSWORD="${APPLE_PASSWORD:?Set APPLE_PASSWORD to an app-specific password}"
APPLE_TEAM_ID="${APPLE_TEAM_ID:?Set APPLE_TEAM_ID}"
CODESIGN_KEYCHAIN="${CODESIGN_KEYCHAIN:-}"
NAME="Crackstreams-$VERSION-universal"
APP="$ROOT/dist/Crackstreams.app"
DMG="$ROOT/dist/$NAME.dmg"
ZIP="$ROOT/dist/$NAME.zip"
STAGE="$ROOT/.build/dmg-stage"

notarize() {
  local result status
  result="$(xcrun notarytool submit "$1" --apple-id "$APPLE_ID" --password "$APPLE_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" --wait --output-format json)"
  echo "$result"
  status="$(echo "$result" | plutil -extract status raw -o - - 2>/dev/null || true)"
  if [[ "$status" != "Accepted" ]]; then
    echo "Notarization of $1 finished with status: ${status:-unknown}" >&2
    xcrun notarytool log "$(echo "$result" | plutil -extract id raw -o - -)" --apple-id "$APPLE_ID" \
      --password "$APPLE_PASSWORD" --team-id "$APPLE_TEAM_ID" >&2 || true
    exit 1
  fi
}

cd "$ROOT"
swift test
CONFIGURATION=release UNIVERSAL=1 VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" \
  SIGN_IDENTITY="$SIGN_IDENTITY" CODESIGN_KEYCHAIN="$CODESIGN_KEYCHAIN" bash "$ROOT/Scripts/build-app.sh"
lipo -info "$APP/Contents/MacOS/Crackstreams"
codesign -dvvv --entitlements :- "$APP" 2>&1 | grep -E 'Developer ID Application|flags=.*runtime|com.apple.security.app-sandbox'

rm -rf "$STAGE" "$DMG" "$ZIP"
mkdir -p "$STAGE"
ln -s /Applications "$STAGE/Applications"
ditto -c -k --keepParent "$APP" "$ZIP"

# Notarize and staple the app before placing it in the DMG. This preserves the
# ticket in the app bundle as well as on the disk image.
notarize "$ZIP"
xcrun stapler staple "$APP"
ditto "$APP" "$STAGE/Crackstreams.app"
hdiutil create -volname "Crackstreams $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
DMG_SIGN=(codesign --force --sign "$SIGN_IDENTITY" --timestamp)
if [[ -n "$CODESIGN_KEYCHAIN" ]]; then DMG_SIGN+=(--keychain "$CODESIGN_KEYCHAIN"); fi
"${DMG_SIGN[@]}" "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"
# Recreate the zip after stapling so both downloadable artifacts agree. Sparkle
# installs updates from this zip.
rm "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

codesign --verify --deep --strict --verbose=2 "$APP"
spctl --assess --verbose=4 --type execute "$APP"
spctl --assess --verbose=4 --type open --context context:primary-signature "$DMG"
xcrun stapler validate "$DMG"
shasum -a 256 "$DMG" "$ZIP" > "$ROOT/dist/$NAME-SHA256SUMS.txt"
printf '\nRelease artifacts:\n%s\n%s\n' "$DMG" "$ZIP"
