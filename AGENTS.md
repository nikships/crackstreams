# Agent guide

## Scope

Multi-platform monorepo for Crackstreams clients:

- **macOS (`Sources/`, `Tests/`)**: Native SwiftUI app that resolves watch pages into HLS feeds and plays up to four streams with AVPlayer. SwiftPM builds the executable; `Scripts/build-app.sh` assembles the `.app` and embeds Sparkle.framework.
- **Windows 10/11 (`windows/`)**: Standalone single-executable client built in pure Go + WebView2 (`CGO_ENABLED=0`). `Scripts/build-windows.sh` cross-compiles `dist/Crackstreams-Windows-x64.zip` and `dist/Crackstreams-Windows-arm64.zip`.
- **Samsung Smart TV (`tv/`)**: Standalone Tizen 10 widget + bundled TV-local Node HLS relay service using Samsung AVPlay. `Scripts/build-tv.sh` packages `dist/tv/Crackstreams.wgt` (see `tv/README.md` for signing and sideloading).

The README covers installation and release credentials. Read it before publishing. Keep every platform's local HLS relay strictly loopback-only (`127.0.0.1`).

## Development loop

Run commands from the repository root with macOS 14+ and a Swift 6 toolchain.

```bash
swift test
swift test --filter HLSProxyTests
bash Scripts/build-app.sh
open dist/Crackstreams.app
```

`./build.sh --install` also copies the debug app to `~/Applications/Crackstreams.app`. Launch a rebuilt app after quitting the previous instance. Generated artifacts belong in `.build/` or `dist/`, never commits.

Before a pull request, reproduce CI across all three platforms:

```bash
swift test
bash Scripts/build-app.sh
(cd windows && go test -race ./...)
bash Scripts/build-windows.sh
node --check tv/app/app.js
node --check tv/app/service.js
node --check tv/tests/preview.mjs
node --test tv/tests/*.test.cjs
xmllint --noout tv/app/config.xml
bash Scripts/build-tv.sh
for script in build.sh Scripts/*.sh; do bash -n "$script" || exit; done
```

Add or update XCTest cases under `Tests/`, Go tests under `windows/internal/`, or Node tests under `tv/tests/` for behavior changes. Name Swift suites `*Tests`, import `@testable import Crackstreams`, and run actor-isolated store tests with `@MainActor`.

## Playback invariants

- `StreamDirectory.swift` (and `windows/internal/directory`, `tv/app/service.js`) owns site listings. Return only same-site `/league/` and `/stream/` links so ads and partner sites never reach the player, and drop responses for a league that is no longer selected. Listings hand watch-page URLs to the resolver; they never resolve playlists themselves.
- `Resolver.swift` (and `windows/internal/resolver`, `tv/app/service.js`) owns page/embed parsing and playlist validation. Accept only HTTP(S), cap resolution work, and propagate cancellation.
- `HLSProxy.swift` (and `windows/internal/proxy`, `tv/app/service.js`) owns upstream headers and rewrites every playlist, key, initialization segment, and media segment to a loopback URL. Preserve token validation, Host validation, byte ranges, response limits, and connection cancellation. Native players require local playlist URLs and conventional media extensions; upstream `.txt` and image-wrapped segments are intentional.
- `StreamStore.swift` owns four independent player lifecycles. Guard asynchronous callbacks with the slot generation so close, replace, and retry cannot affect a newer player. Preserve audio defaults, failure recovery, and input on rejected submissions.
- `ContentView.swift` and `PlayerView.swift` keep video borderless. Reveal controls on hover or keyboard focus without changing the grid layout. Pane controls (Browse games, Paste from clipboard, drag and drop) are the only way to add streams once playback starts; there is no top-edge URL bar.

## Validation

Unit tests alone do not cover playback. For changes to resolution, proxying, player lifecycle, or controls, launch the built app (or sideload onto the Samsung TV for `tv/` changes) and exercise the real UI with a live watch page:

1. Start four concurrent players on desktop (or single-stream AVPlay on TV) and confirm actual video frames and sustained real-time playback without rebuffering.
2. Close and reuse a pane; expand and restore it; toggle mute.
3. Check invalid input and a fifth submission while four streams play. The existing players and entered URL must remain intact.
4. Check empty, resolving, playing, buffering, and failed states at the default and minimum window sizes.

Do not hardcode a resolved CDN playlist or Referer in tests; both rotate. Keep live tests out of default CI because third-party availability is unstable.

## Signing and releases

Local development builds are ad-hoc signed and never start Sparkle's updater. Releases are automatic: a push to `main` that changes client inputs runs `.github/workflows/release.yml`, which versions with `Scripts/next-version.sh`, builds and notarizes macOS with `Scripts/release.sh`, cross-compiles Windows ZIPs with `Scripts/build-windows.sh`, packages `Crackstreams.wgt` with `Scripts/build-tv.sh`, signs the macOS ZIP for Sparkle, publishes all platform artifacts to the GitHub release, and commits `appcast.xml` through `Scripts/update-appcast.sh`. Keep `appcast.xml`, docs, and tests out of the workflow's trigger paths so the bot's appcast commit cannot start another release. Raise `CFBundleShortVersionString` in `Info.plist` to start a new minor or major series; never reuse a build number, because Sparkle orders updates by `CFBundleVersion`. Keep Apple identities, certificates, notarization passwords, and the Sparkle private key in the environment or GitHub Secrets, with no secret files or literal credentials in the repository.

The macOS app is sandboxed, so Sparkle depends on `SUEnableInstallerLauncherService` in `Info.plist` and the `<bundle id>-spks`/`-spki` mach-lookup exception in `Config/Entitlements.plist`; `ReleaseConfigurationTests` keeps them in step. Sign Sparkle's XPC services, `Autoupdate`, `Updater.app`, and the framework individually before the app, and never with `--deep`.

A macOS release is complete only when it is universal (`lipo -info`), Developer ID signed with the sandbox and hardened runtime, notarized and stapled, accepted by `spctl`, and tested from the downloaded artifact. The app ZIP and DMG are notarized separately; the ZIP is also the Sparkle update archive. Staple the app before creating the DMG so the bundled app carries its ticket.

Use `swift build ... --show-bin-path` to locate SwiftPM binaries; the universal output path varies by toolchain. CI and the release workflow are under `.github/workflows/`.

## Change discipline

Keep Swift 5 language mode, four-space indentation, existing type boundaries, and small synchronous UI mutations on the main actor. Use Apple frameworks already imported by the target; adding a dependency requires justification. Match the project's short, purposeful comments.

Commit messages use an imperative subject. Required checks are the CI commands above, plus the relevant live playback validation. Update this guide and the README when workflows or operational constraints change.
