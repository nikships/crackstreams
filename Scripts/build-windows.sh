#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WIN_DIR="$ROOT/windows"
DIST_DIR="$ROOT/dist"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist" 2>/dev/null || echo "1.0.0")}"

mkdir -p "$DIST_DIR"

cd "$WIN_DIR"

# Regenerate Windows COFF resource (.syso) if missing.
if [[ ! -f cmd/crackstreams/rsrc_windows_amd64.syso || ! -f cmd/crackstreams/rsrc_windows_arm64.syso ]]; then
  go run github.com/tc-hib/go-winres@v0.3.1 make --in winres/winres.json --out cmd/crackstreams/rsrc --arch amd64,arm64
fi

build_arch() {
  local goarch="$1"
  local label="$2"
  local stage="$DIST_DIR/windows-$label"
  local zip_path="$DIST_DIR/Crackstreams-Windows-$label.zip"

  rm -rf "$stage" "$zip_path"
  mkdir -p "$stage"

  GOOS=windows GOARCH="$goarch" CGO_ENABLED=0 \
    go build -trimpath -ldflags="-s -w -H=windowsgui" \
    -o "$stage/Crackstreams.exe" ./cmd/crackstreams

  cat > "$stage/HOW TO OPEN.txt" <<'EOF'
CRACKSTREAMS FOR WINDOWS
========================

1. Double-click "Crackstreams.exe" to open the app.
   (If you opened this inside a .zip folder, click "Extract all" first or drag Crackstreams.exe to your Desktop.)

2. First-time Windows prompt:
   If a blue "Windows protected your PC" window appears:
   - Click "More info"
   - Click "Run anyway"
   (Windows only asks this the first time.)

3. Optional Desktop & Start Menu shortcut:
   Once Crackstreams opens, click "Add Desktop Shortcut" in the top-right corner
   to pin Crackstreams to your Desktop and Windows Start Menu.

Quick Controls:
- Click "Browse Live Games" (or press Ctrl+B) to pick any live game or 24/7 sports channel.
- Watch up to 4 games at once!
- Click the speaker icon on any game (or press Alt+1 to Alt+4) to switch audio to that game.
- Double-click any video (or press F11) for full screen; press Esc to go back.
EOF

  (
    cd "$stage"
    zip -q -9 "$zip_path" "Crackstreams.exe" "HOW TO OPEN.txt"
  )

  if [[ "$label" == "x64" ]]; then
    cp "$stage/Crackstreams.exe" "$DIST_DIR/Crackstreams.exe"
  fi

  rm -rf "$stage"
  printf 'Built %s\n' "$zip_path"
}

build_arch amd64 x64
build_arch arm64 arm64
printf 'Standalone executable: %s/Crackstreams.exe (v%s)\n' "$DIST_DIR" "$VERSION"
