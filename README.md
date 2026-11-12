# Crackstreams for macOS

A native, video-first macOS app for watching up to four HLS live streams side by side. Pick a game from the built-in browser, or paste a Crackstreams-style watch page or a direct `.m3u8` URL. No browser, chat, popup layer, streamlink, or mpv is involved.

## Download

Download the universal, notarized DMG from the latest GitHub release, open it, and drag **Crackstreams** to **Applications**. Apple silicon and Intel Macs running macOS 14 or later are supported. The app updates itself from then on.

## Use

- Click **Browse** (or press **⌘B**) to list the sports and games currently posted on crackstreams.mx, then double-click a game or click **Watch**. Use **Browse games** in an empty pane to play into that pane. Live, starting-soon, and 24/7 listings are marked, and times are shown in your time zone.
- Paste a URL and press **Return**, or click **Add stream**.
- Drop a URL directly onto a pane to play or replace its stream.
- Copy a URL and use **Paste from clipboard** in an empty pane.
- Hover over a pane for playback, mute, expand, and close controls. The same controls appear when the pane receives keyboard focus.
- The first active pane starts audible; additional panes start muted.
- Press **⌘L** or hover at the top edge to reveal the URL bar while watching. Press **Esc** to hide it.
- Expand a pane to fill the window; use the restore control to return to the four-pane grid.

Playback errors include an inline retry. Temporary stalls show a reconnecting indicator without discarding the player.

## Build

Requirements: macOS 14+ and a Swift 6 toolchain. The only package dependency is [Sparkle](https://sparkle-project.org), which SwiftPM fetches on the first build.

```bash
swift test
./build.sh --install
```

This creates `dist/Crackstreams.app`, ad-hoc signs it for local development, and optionally installs it in `~/Applications`.

## Releases and updates

Every push to `main` that changes the app (`Sources/`, `Package.swift`, `Package.resolved`, `Info.plist`, `Config/`, `Assets/`, `Scripts/build-app.sh`, or `Scripts/release.sh`) runs the **Release** workflow. It:

1. Picks the next version with `Scripts/next-version.sh`: one patch above the newest `vX.Y.Z` tag, or `CFBundleShortVersionString` in `Info.plist` when that is higher. Raise the `Info.plist` value to start a new minor or major series. The build number is the commit count.
2. Runs `Scripts/release.sh` with an isolated signing keychain: tests, universal build, Developer ID signing with the sandbox and hardened runtime, notarization and stapling of the app and DMG, and Gatekeeper checks.
3. Signs the release ZIP with Sparkle's EdDSA key and publishes the DMG, ZIP, and checksums as the latest GitHub release.
4. Downloads the published DMG and checks its notarization ticket, Gatekeeper assessment, and universal binary.
5. Adds the release to `appcast.xml` on `main`.

Run the workflow manually from the Actions tab to rebuild, or to pick a version explicitly.

The app checks `appcast.xml` daily through Sparkle and offers updates in place. **Crackstreams › Check for Updates…** checks immediately. Debug builds never start the updater.

The workflow needs these repository secrets:

- `APPLE_DEVELOPER_CERTIFICATE_P12_BASE64`: base64-encoded Developer ID Application `.p12`
- `APPLE_DEVELOPER_CERTIFICATE_PASSWORD`: `.p12` password
- `APPLE_DEVELOPER_ID_APPLICATION`: full signing identity
- `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`: notarization credentials
- `SPARKLE_PRIVATE_KEY`: Sparkle EdDSA private key, exported with `generate_keys -x`. Its public half is `SUPublicEDKey` in `Info.plist`.

To cut a release locally with the same steps, minus publishing:

```bash
VERSION="$(bash Scripts/next-version.sh)" \
BUILD_NUMBER="$(git rev-list --count HEAD)" \
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
APPLE_ID="you@example.com" \
APPLE_PASSWORD="app-specific-password" \
APPLE_TEAM_ID="TEAMID" \
bash Scripts/release.sh
```

Credentials are read only from the environment and are never written into the source tree. Release artifacts are ignored by Git.

## Architecture

- `StreamDirectory.swift`: league and game listings from the stream site, limited to same-site `/league/` and `/stream/` links, plus the browser's loading and caching state.
- `Resolver.swift`: watch-page parsing, embed resolution, and HLS validation.
- `HLSProxy.swift`: token-protected, loopback-only HLS relay with Referer handling, playlist/key/segment rewriting, byte-range support, and request cancellation.
- `StreamStore.swift`: four independent AVPlayer lifecycles, buffering state, failure recovery, and pane management.
- `ContentView.swift`: borderless video grid, hover/focus controls, drag and drop, and keyboard navigation.
- `BrowserView.swift`: the sports and games sheet.
- `Updater.swift`: Sparkle's updater and the **Check for Updates…** menu item.

Only loopback playback traffic passes through the relay. Its random per-launch token and Host checks prevent unrelated local processes or web pages from using it as an open proxy.

## Project

Crackstreams is an independent client and is not affiliated with any streaming site or broadcaster. Stream availability and site markup can change. Use it only with feeds you are authorized to access.

Released under the MIT License.
