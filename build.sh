#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
bash "$ROOT/Scripts/build-app.sh"
if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  ditto "$ROOT/dist/Crackstreams.app" "$HOME/Applications/Crackstreams.app"
  printf 'Installed %s\n' "$HOME/Applications/Crackstreams.app"
fi
