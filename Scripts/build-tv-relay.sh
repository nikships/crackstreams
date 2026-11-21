#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$repo/dist"
swiftc -swift-version 5 -O \
    "$repo/Sources/Resolver.swift" "$repo/Sources/StreamDirectory.swift" \
    "$repo/Sources/HLSProxy.swift" "$repo/tv/relay/main.swift" \
    -o "$repo/dist/CrackstreamsTVRelay"
