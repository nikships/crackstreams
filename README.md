# Crackstreams for macOS

A native, video-first macOS app for watching up to four HLS live streams side by side. Paste a Crackstreams-style watch page or a direct `.m3u8` URL. No browser, chat, popup layer, streamlink, or mpv is involved.

## Download

Download the universal, notarized DMG from the latest GitHub release, open it, and drag **Crackstreams** to **Applications**. Apple silicon and Intel Macs running macOS 14 or later are supported.

## Use

- Paste a URL and press **Return**, or click **Add stream**.
- Drop a URL directly onto a pane to play or replace its stream.
- Copy a URL and use **Paste from clipboard** in an empty pane.
- Hover over a pane for playback, mute, expand, and close controls. The same controls appear when the pane receives keyboard focus.
- The first active pane starts audible; additional panes start muted.
- Press **⌘L** or hover at the top edge to reveal the URL bar while watching. Press **Esc** to hide it.
- Expand a pane to fill the window; use the restore control to return to the four-pane grid.

Playback errors include an inline retry. Temporary stalls show a reconnecting indicator without discarding the player.

## Build

Requirements: macOS 14+, a Swift 6 toolchain, and no third-party dependencies.

```bash
swift test
./build.sh --install
```

This creates `dist/Crackstreams.app`, ad-hoc signs it for local development, and optionally installs it in `~/Applications`.

## Signed release

`Scripts/release.sh` runs tests, builds a universal binary, enables the app sandbox and hardened runtime, signs with Developer ID, notarizes the app and DMG, staples both tickets, verifies Gatekeeper assessment, and emits SHA-256 checksums.

```bash
VERSION=1.0.0 \
BUILD_NUMBER=1 \
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
APPLE_ID="you@example.com" \
APPLE_PASSWORD="app-specific-password" \
APPLE_TEAM_ID="TEAMID" \
bash Scripts/release.sh
```

Credentials are read only from the environment and are never written into the source tree. Release artifacts are ignored by Git.

The manual **Release** GitHub Actions workflow performs the same steps and publishes a GitHub release. Configure these repository secrets first:

- `MAC_CERTS`: base64-encoded Developer ID `.p12`
- `CERT_PASSWORD`: `.p12` password
- `APPLE_DEVELOPER_ID_APPLICATION`: full signing identity
- `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`

## Architecture

- `Resolver.swift`: watch-page parsing, embed resolution, and HLS validation.
- `HLSProxy.swift`: token-protected, loopback-only HLS relay with Referer handling, playlist/key/segment rewriting, byte-range support, and request cancellation.
- `StreamStore.swift`: four independent AVPlayer lifecycles, buffering state, failure recovery, and pane management.
- `ContentView.swift`: borderless video grid, hover/focus controls, drag and drop, and keyboard navigation.

Only loopback playback traffic passes through the relay. Its random per-launch token and Host checks prevent unrelated local processes or web pages from using it as an open proxy.

## Project

Crackstreams is an independent client and is not affiliated with any streaming site or broadcaster. Stream availability and site markup can change. Use it only with feeds you are authorized to access.

Released under the MIT License.
