#!/usr/bin/env bash
set -euo pipefail
umask 077

if [[ $# -gt 1 ]]; then
    echo "Usage: $0 [Samsung signing profile]" >&2
    exit 2
fi

repo="$(cd "$(dirname "$0")/.." && pwd)"
out="$repo/dist/tv"
mkdir -p "$out"
stage="$(mktemp -d "$out/package.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
token="$(openssl rand -hex 32)"
origin="http://127.0.0.1:48641"
mkdir -p "$stage/widget/service"
sed "s|__RELAY_ORIGIN__|$origin|g" "$repo/tv/app/index.html" > "$stage/widget/index.html"
sed "s|__TV_TOKEN__|$token|g" "$repo/tv/app/service.js" > "$stage/widget/service/index.js"
if [[ -n "${VERSION:-}" ]]; then
    sed "s|version=\"[^\"]*\" viewmodes=|version=\"$VERSION\" viewmodes=|" "$repo/tv/app/config.xml" > "$stage/widget/config.xml"
else
    cp "$repo/tv/app/config.xml" "$stage/widget/config.xml"
fi
cp "$repo/tv/app/"{app.js,styles.css} "$stage/widget/"
sips -Z 128 "$repo/Assets/AppIcon.png" --out "$stage/widget/icon.png" >/dev/null
printf 'window.crackstreamsTV = {origin:"%s",token:"%s"};\n' "$origin" "$token" > "$stage/widget/settings.js"

if [[ $# -eq 1 ]]; then
    tizen="${TIZEN_SDK:-$HOME/tizen-studio}/tools/ide/bin/tizen"
    "$tizen" package -t wgt -s "$1" -o "$stage" -- "$stage/widget"
else
    (cd "$stage/widget" && zip -q -X -r "$stage/Crackstreams.wgt" ./*)
fi
mv "$stage"/Crackstreams.wgt "$out/Crackstreams.wgt"
printf '\nTV package: %s\n' "$out/Crackstreams.wgt"
