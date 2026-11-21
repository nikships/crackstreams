# Crackstreams for Samsung Smart TV

Use the remote’s arrows and **OK** to pick a sport and game. **Back** returns from video to the same game, or exits the directory. **Enter a link** accepts a Crackstreams watch page or a public `.m3u8` link. The TV app plays one feed at a time using Samsung AVPlay; four-pane multiview remains a macOS feature.

The widget does not load third-party watch pages or send its own headers to media servers. A companion process on your Mac uses the shared Swift directory, resolver and HLS relay and forwards video to your TV. The Mac must be awake and connected to the same trusted local network. The relay binds to one LAN IP, only accepts connections from the configured TV IP, and signs each HLS URL. Do not port-forward the relay or share the generated widget, which contains the pairing token. The macOS app itself still uses its loopback-only listener.

## Build and sideload

1. Enable [Developer Mode](https://developer.samsung.com/smarttv/develop/getting-started/using-sdk/tv-device.html) on the TV and set the developer host to your Mac’s LAN IPv4 address. Install Tizen Studio with the TV and Samsung Certificate extensions. In Certificate Manager, [create a Samsung TV profile](https://developer.samsung.com/smarttv/develop/getting-started/setting-up-sdk/creating-certificates.html) with the TV’s device ID in its distributor certificate. A generic Tizen profile may build a package that a Samsung TV refuses to install.
2. On the Mac, from the repository root, set `MAC_IP`, `TV_IP`, and `PROFILE` to those values, then run:

   ```bash
   sdk="${TIZEN_SDK:-$HOME/tizen-studio}"
   "$sdk/tools/sdb" connect "$TV_IP"
   bash Scripts/build-tv.sh "$MAC_IP" "$TV_IP" "$PROFILE"
   "$sdk/tools/ide/bin/tizen" install -s "$TV_IP:26101" -n Crackstreams.wgt -- "$PWD/dist/tv"
   "$sdk/tools/ide/bin/tizen" run -s "$TV_IP:26101" -p CrackTV001.Player
   ```

3. Start the relay and leave it running during playback:

   ```bash
   ./dist/CrackstreamsTVRelay ./dist/tv/relay.json
   ```

If the TV refuses installation, verify the certificate profile and use **Permit to install applications** in Tizen Studio’s Device Manager if required. If the Mac or TV IP changes, rebuild with the new addresses, reinstall the widget, and restart the relay. The build reuses the pairing token in `dist/tv/relay.json` until that file is replaced.

## Development

- `app/`: Tizen manifest, remote navigation, directory, and AVPlay UI.
- `relay/`: Mac companion entry point. `Scripts/build-tv-relay.sh` builds it without Tizen Studio.
- `tests/preview.mjs`: Local browser preview with sample listings and a fake AVPlay implementation. Run `node tv/tests/preview.mjs` and open `http://127.0.0.1:48634/`. Test decoder behavior and actual video on the TV, not in this preview.
