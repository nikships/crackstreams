#!/bin/bash
# Prints the next release version: one patch above the newest vX.Y.Z tag, or the
# CFBundleShortVersionString in Info.plist when that is higher. Raise the
# Info.plist value to start a new minor or major series.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FLOOR="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")"
LATEST="$(git -C "$ROOT" tag --list 'v[0-9]*.[0-9]*.[0-9]*' --sort=-v:refname | head -n1)"
LATEST="${LATEST#v}"

if [[ -z "$LATEST" ]]; then
  NEXT="$FLOOR"
else
  IFS=. read -r MAJOR MINOR PATCH <<< "$LATEST"
  NEXT="$MAJOR.$MINOR.$((PATCH + 1))"
fi
printf '%s\n%s\n' "$NEXT" "$FLOOR" | sort -t. -k1,1n -k2,2n -k3,3n | tail -n1
