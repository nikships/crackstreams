#!/usr/bin/env bash
set -euo pipefail
umask 077

if [[ $# -lt 3 || $# -gt 4 ]]; then
    echo "Usage: $0 <Mac LAN IPv4> <TV LAN IPv4> <signing profile> [port]" >&2
    exit 2
fi

host="$1"
tv="$2"
profile="$3"
port="${4:-48633}"
private_ipv4() {
    local a b c d
    [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS=. read -r a b c d <<< "$1"
    [[ "$a.$b.$c.$d" == "$((10#$a)).$((10#$b)).$((10#$c)).$((10#$d))" ]] || return 1
    (( b <= 255 && c <= 255 && d <= 255 )) || return 1
    (( a == 10 || (a == 172 && b >= 16 && b <= 31) || (a == 192 && b == 168) ))
}
if ! private_ipv4 "$host" || ! private_ipv4 "$tv" || [[ "$host" == "$tv" ]] \
    || ! [[ "$port" =~ ^[1-9][0-9]{3,4}$ ]] || (( port <= 1024 || port > 65535 )); then
    echo "Use distinct private IPv4 addresses and a port between 1025 and 65535." >&2
    exit 2
fi
sdk="${TIZEN_SDK:-$HOME/tizen-studio}"
tizen="$sdk/tools/ide/bin/tizen"
if [[ ! -x "$tizen" ]]; then
    echo "Tizen CLI not found at $tizen. Set TIZEN_SDK to the Tizen Studio directory." >&2
    exit 2
fi

repo="$(cd "$(dirname "$0")/.." && pwd)"
out="$repo/dist/tv"
mkdir -p "$out"
stage="$(mktemp -d "$out/package.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
settings="$out/relay.json"
if [[ -f "$settings" ]]; then
    token="$(plutil -extract token raw -o - "$settings")"
    [[ "$token" =~ ^[0-9a-f]{64}$ ]] || { echo "Invalid existing relay token." >&2; exit 2; }
else
    token="$(openssl rand -hex 32)"
fi
origin="http://$host:$port"
printf '{"host":"%s","tv":"%s","port":%s,"token":"%s"}\n' "$host" "$tv" "$port" "$token" > "$stage/relay.json"
chmod 600 "$stage/relay.json"
mkdir "$stage/widget"
for name in config.xml index.html; do
    sed "s|__RELAY_ORIGIN__|$origin|g" "$repo/tv/app/$name" > "$stage/widget/$name"
done
cp "$repo/tv/app/"{app.js,styles.css} "$stage/widget/"
sips -Z 128 "$repo/Assets/AppIcon.png" --out "$stage/widget/icon.png" >/dev/null
printf 'window.crackstreamsTV = {origin:"%s",token:"%s"};\n' "$origin" "$token" > "$stage/widget/settings.js"

bash "$repo/Scripts/build-tv-relay.sh"
"$tizen" package -t wgt -s "$profile" -o "$stage" -- "$stage/widget"
mv "$stage"/Crackstreams.wgt "$out/Crackstreams.wgt"
mv "$stage/relay.json" "$settings"
printf '\nTV package: %s\nMac relay settings: %s\n' "$out/Crackstreams.wgt" "$settings"
