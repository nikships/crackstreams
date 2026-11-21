# Crackstreams for Samsung Smart TV

Use the remote’s arrows and **OK** to pick a sport and game. **Back** returns from video to the same game, or exits the directory. The TV app plays one feed at a time using Samsung AVPlay; four-pane multiview remains a macOS feature.

Everything runs on the TV. The widget starts its bundled Tizen service, which reads the listings, resolves stream links, and supplies any upstream headers the feeds need. The service only listens on the TV’s loopback address, authenticates app requests, and signs each HLS URL. No other device has to stay on after installation. This client targets Samsung TVs running Tizen 10.

## Build and sideload

1. Enable [Developer Mode](https://developer.samsung.com/smarttv/develop/getting-started/using-sdk/tv-device.html) on the TV and set the developer host to your computer’s LAN IPv4 address. In Tizen Studio, [create a Samsung TV Partner profile](https://developer.samsung.com/smarttv/develop/getting-started/setting-up-sdk/creating-certificates.html) with the TV’s device ID in its distributor certificate. The widget includes a Tizen service and needs Partner signing.
2. On the Mac, from the repository root, set `TV_IP` and `PROFILE` to those values, then run:

   ```bash
   sdk="${TIZEN_SDK:-$HOME/tizen-studio}"
   "$sdk/tools/sdb" connect "$TV_IP"
   bash Scripts/build-tv.sh "$PROFILE"
   "$sdk/tools/ide/bin/tizen" install -s "$TV_IP:26101" -n Crackstreams.wgt -- "$PWD/dist/tv"
   "$sdk/tools/ide/bin/tizen" run -s "$TV_IP:26101" -p CrackTV001.Player
   ```

`bash Scripts/build-tv.sh` without a profile produces an unsigned widget for a separate signing tool. Install updates with the same author certificate. If switching from the original Mac-assisted build signed by a different author, remove that copy once before installing.

## Development

- `app/`: Tizen manifest, remote navigation, AVPlay UI, and bundled Node service.
- `tests/service.test.cjs`: Run `node --test tv/tests/service.test.cjs` to validate directory and embed parsing, signed HLS URLs, and media ranges.
- `tests/preview.mjs`: Local browser preview with sample listings and a fake AVPlay implementation. Run `node tv/tests/preview.mjs` and open `http://127.0.0.1:48634/`. Test decoder behavior and actual video on the TV, not in this preview.
