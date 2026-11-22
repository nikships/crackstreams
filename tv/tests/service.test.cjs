const assert = require("node:assert/strict");
const test = require("node:test");
const service = require("../app/service.js");

test("directory only returns same-site leagues and game cards", () => {
    assert.deepEqual(service.leagues(`
        <a href="/league/nba/">NBA</a>
        <a class="card" href="/league/nba/"><div class="card-title">NBA Streams</div></a>
        <a href="https://ads.example.org/league/partner">Partner</a>
        <!-- <a href="/league/gone/">Gone</a> -->
    `), [{ name: "NBA", url: "https://crackstreams.mx/league/nba/" }]);
    assert.deepEqual(service.games(`
        <h2>Wednesday, November 11, 2026</h2>
        <a class="card" href="/stream/team-a-team-b/">
          <div class="card-title">Team A &amp; Team B</div><div class="card-subtitle">Start Time: 7:00 PM ET</div>
        </a>
        <a href="/stream/not-a-card/">Not a card</a>
        <a class="card" href="https://ads.example.org/stream/outside">Outside</a>
    `), [{
        title: "Team A & Team B", url: "https://crackstreams.mx/stream/team-a-team-b/",
        detail: "7:00 PM ET", start: "2026-11-12T00:00:00.000Z", channel: false,
    }]);
    assert.equal(service.eventStart("Wednesday, July 15, 2026", "7:00 PM ET"), "2026-07-15T23:00:00.000Z");
});

test("resolver extracts ordered embeds and resolves relative playlist URLs", () => {
    assert.deepEqual(service.embeds(`
        const allStreams = [{"value":"https://embed.example/first"},{"value":"//embed.example/second"}];
        <iframe src="https://ads.example.org/fallback"></iframe>
    `, "https://crackstreams.mx/stream/game").map(url => url.href),
    ["https://embed.example/first", "https://embed.example/second"]);
    assert.equal(service.playlistIn('let DIRECT_STREAM_URL = "variant.m3u8?x=1&amp;y=2";', "https://embed.example/watch/").href,
        "https://embed.example/watch/variant.m3u8?x=1&y=2");
});

test("TV loopback URLs sign playlists, keys, maps, and nonstandard segments", () => {
    const result = service.rewrite([
        "#EXTM3U", "#EXT-X-STREAM-INF:BANDWIDTH=1000000", "variant",
        '#EXT-X-KEY:METHOD=AES-128,URI="key.bin"', '#EXT-X-MAP:URI="init.mp4"',
        "#EXTINF:4,", "part1.txt",
    ].join("\n"), new URL("https://cdn.example/live/master.m3u8"), "https://embed.example/");
    const urls = [...result.matchAll(/http:\/\/[^"\n]+/g)].map(match => new URL(match[0]));
    assert.deepEqual(urls.map(u => u.pathname), ["/stream.m3u8", "/key.bin", "/init.mp4", "/segment.ts"]);
    for (const url of urls) {
        const params = url.searchParams;
        assert.equal(url.origin, "http://127.0.0.1:48641");
        assert.equal(params.get("t"), service.sign(url.pathname, params.get("u"), params.get("r")));
        assert.notEqual(params.get("t"), service.sign("/changed", params.get("u"), params.get("r")));
    }
    assert.equal(urls[3].searchParams.get("u"), "https://cdn.example/live/part1.txt");
});

test("local media targets and invalid byte ranges are rejected", () => {
    for (const url of ["http://2130706433/demo.m3u8", "http://[::1]/a.m3u8", "http://device.local/a.m3u8",
        "http://user:secret@example.org/foo", "file:///etc/hosts", "http://example.org:8010/a.m3u8"]) {
        assert.equal(service.webURL(url), null);
    }
    for (const ip of ["10.0.0.1", "192.168.0.1", "169.254.169.254", "127.0.0.1", "172.29.1.1", "100.64.1.1"]) {
        assert.equal(service.publicAddress(ip), false);
    }
    assert.equal(service.publicAddress("8.8.8.8"), true);
    const data = Buffer.from("0123456789");
    assert.equal(service.slice(data, "bytes=3-4").data.toString(), "34");
    assert.equal(service.slice(data, "bytes=-3").data.toString(), "789");
    assert.equal(service.slice(data, "bytes=9-").data.toString(), "9");
    assert.equal(service.slice(data, "bytes=10-"), null);
    assert.equal(service.slice(data, "bytes=1-2,4-5"), null);
});

test("a web-only game resolves through a same-day alternate with nested players", async () => {
    const watch = "https://crackstreams.mx/stream/red-team-vs-blue-team";
    const outdated = "https://hdcrackstreams.live/custom-stream/ncaaf-red-team-at-blue-team";
    const verified = "https://hdcrackstreams.live/custom-stream/red-team-at-blue-team";
    const urls = ["https://first.example/player", "https://middle.example/event", "https://final.example/embed"];
    const playlist = "https://cdn.example/feed.m3u8";
    const pages = {
        [watch]: `<h1>Red Team vs Blue Team</h1><div class="event-info"><span>NCAA</span> November 21, 2026</div>
            <iframe src="https://js-only.example/player"></iframe>`,
        "https://js-only.example/player": `<script src="player.js"></script>`,
        [outdated]: `<h1>NCAAF: Red Team at Blue Team</h1><div class="custom-player-category">November 20, 2026</div>
            <iframe src="https://old.example/player"></iframe>`,
        [verified]: `<h1>Red Team at Blue Team</h1><div class="custom-player-category">November 21, 2026</div>
            <iframe src="${urls[0]}"></iframe>`,
        [urls[0]]: `<iframe src="${urls[1]}"></iframe>`,
        [urls[1]]: `<iframe src="${urls[2]}"></iframe>`,
        [urls[2]]: `const DIRECT_STREAM_URL = "${playlist}";`,
        [playlist]: "#EXTM3U\n",
    };
    const requested = [];
    const result = await service.resolve(new URL(watch), new AbortController().signal, async (url, _, referer) => {
        requested.push(url.href);
        if (url.href === playlist) assert.equal(referer, "https://final.example/");
        return { url, text: pages[url.href] || "" };
    });
    assert.equal(result.url.href, playlist);
    assert.ok(requested.includes(outdated));
    assert.ok(!requested.includes("https://old.example/player"));
});

test("PNG-wrapped transport packets are unpacked without changing normal media", () => {
    const png = Buffer.from("iVBORw0KGgoAAAANSUhEUgAAAAgAAAACCAIAAADq9gq6AAAAM0lEQVR4nGMI8fQO8fQOiGBgYJCR7+ZgYGBgYGD4X5zOILHrwNzCF0wM8TV85ysYGeAAACjqCttgwtNrAAAAAElFTkSuQmCC", "base64");
    const transport = Buffer.concat([Buffer.from([0x47]), Buffer.alloc(187), Buffer.from([0x47]), Buffer.alloc(187, 1)]);
    assert.deepEqual(service.unpackSegment(png), transport);
    assert.equal(service.unpackSegment(transport), transport);
    const truncated = png.subarray(0, 38);
    assert.equal(service.unpackSegment(truncated), truncated);
});

test("an unchanged live window expires, but new media or an ended playlist does not", () => {
    const url = new URL("https://cdn.example/window.m3u8");
    const original = "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:2538\n#EXTINF:4,\nsegment-2538.ts\n";
    assert.equal(service.staleLiveWindow(url, original, 1000), false);
    assert.equal(service.staleLiveWindow(url, original, 12999), false);
    assert.equal(service.staleLiveWindow(url, original + "#Metadata changed\n", 13000), true);
    assert.equal(service.staleLiveWindow(url, original.replaceAll("2538", "2539"), 13001), false);
    assert.equal(service.staleLiveWindow(url, original + "#EXT-X-ENDLIST\n", 50000), false);
});

test("recovery switches feeds, rejects the same stale window, and accepts it once it advances", async () => {
    const watch = new URL("https://crackstreams.mx/stream/red-vs-blue");
    const primary = "https://cdn.example/recovery.m3u8";
    const backup = "https://backup.example/recovery.m3u8";
    let hasBackup = true;
    let manifest = "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:2538\n#EXTINF:4,\nsegment-2538.ts\n";
    const load = async url => {
        const body = {
            [watch.href]: '<iframe src="https://player.example/primary"></iframe>'
                + (hasBackup ? '<iframe src="https://player.example/backup"></iframe>' : ""),
            "https://player.example/primary": `DIRECT_STREAM_URL = '${primary}';`,
            "https://player.example/backup": `DIRECT_STREAM_URL = '${backup}';`,
            [primary]: manifest, [backup]: manifest,
        };
        return { url, text: body[url.href] };
    };
    const { signal } = new AbortController();
    const resolve = avoid => service.resolve(watch, signal, load, avoid);
    service.staleLiveWindow(new URL(primary), manifest, Date.now() - 15000);
    const first = await resolve();
    assert.equal(first.url.href, primary);
    const avoid = new Set([first.feed]);
    const next = await resolve(avoid);
    assert.equal(next.url.href, backup);
    assert.notEqual(first.feed, next.feed);
    hasBackup = false;
    await assert.rejects(resolve(avoid), /live feed stopped updating/);
    manifest = manifest.replaceAll("2538", "2539");
    assert.equal((await resolve(avoid)).url.href, primary);
});
test("unpackSegment and unpackSegmentAsync unwrap WebP EXIF, TIKTIKPX, TIKTIKRAW, TIKTIKTSGZ, and prefixed TS", async () => {
    const zlib = require("node:zlib");
    const ts = Buffer.concat([Buffer.from([0x47]), Buffer.alloc(187, 0x11), Buffer.from([0x47]), Buffer.alloc(187, 0x22)]);

    // 1. WebP EXIF wrapper
    const exifChunk = Buffer.alloc(8 + ts.length);
    exifChunk.write("EXIF", 0, "ascii");
    exifChunk.writeUInt32LE(ts.length, 4);
    ts.copy(exifChunk, 8);
    const webp = Buffer.alloc(12 + exifChunk.length);
    webp.write("RIFF", 0, "ascii");
    webp.writeUInt32LE(4 + exifChunk.length, 4);
    webp.write("WEBP", 8, "ascii");
    exifChunk.copy(webp, 12);
    assert.deepEqual(service.unpackSegment(webp), ts);
    assert.deepEqual(await service.unpackSegmentAsync(webp), ts);

    // 2. TIKTIKPX RGB PNG wrapper with bottom padding rows and Sub/Paeth filters
    const gz = zlib.gzipSync(ts);
    const width = 32, height = 16;
    const pixels = Buffer.alloc(width * height * 3, 0xaa);
    Buffer.from("TIKTIKPX").copy(pixels, 0);
    pixels.writeUInt32BE(gz.length, 8);
    gz.copy(pixels, 12);
    const stride = width * 3;
    const raw = Buffer.alloc((stride + 1) * height);
    for (let y = 0; y < height; y++) {
        const rowOff = y * (stride + 1);
        raw[rowOff] = y % 2 === 0 ? 0 : 1; // alternate None and Sub filter
        for (let x = 0; x < stride; x++) {
            const cur = pixels[y * stride + x];
            const left = raw[rowOff] === 1 && x >= 3 ? pixels[y * stride + x - 3] : 0;
            raw[rowOff + 1 + x] = (cur - left) & 255;
        }
    }
    function pngChunk(type, data) {
        const out = Buffer.alloc(12 + data.length);
        out.writeUInt32BE(data.length, 0);
        out.write(type, 4, "ascii");
        data.copy(out, 8);
        return out;
    }
    const ihdr = Buffer.alloc(13);
    ihdr.writeUInt32BE(width, 0);
    ihdr.writeUInt32BE(height, 4);
    ihdr[8] = 8;
    ihdr[9] = 2;
    const tiktikPng = Buffer.concat([
        Buffer.from("89504e470d0a1a0a", "hex"),
        pngChunk("IHDR", ihdr),
        pngChunk("IDAT", zlib.deflateSync(raw)),
        pngChunk("IEND", Buffer.alloc(0)),
    ]);
    assert.deepEqual(service.unpackSegment(tiktikPng), ts);
    assert.deepEqual(await service.unpackSegmentAsync(tiktikPng), ts);

    // 3. TIKTIKRAW and TIKTIKTSGZ markers + arbitrary header prefix
    const rawWrapped = Buffer.concat([Buffer.from("JUNK_HEADER_TIKTIKRAW"), ts]);
    assert.deepEqual(await service.unpackSegmentAsync(rawWrapped), ts);
    const gzWrapped = Buffer.concat([Buffer.from("PREFIX_TIKTIKTSGZ"), gz]);
    assert.deepEqual(await service.unpackSegmentAsync(gzWrapped), ts);
    const syncPrefixed = Buffer.concat([Buffer.alloc(64, 0x55), ts]);
    assert.deepEqual(await service.unpackSegmentAsync(syncPrefixed), ts);
});

test("live playlist normalization strips transient ENDLIST and marks sequence jumps with DISCONTINUITY", () => {
    const url = new URL("https://cdn.example/live-continuity.m3u8");
    const poll1 = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:100\n#EXTINF:2,\nseg100.ts\n";
    assert.equal(service.normalizeLivePlaylist(url, poll1), poll1);

    // Transient ENDLIST on an already-live stream is stripped
    const poll2WithEndlist = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:101\n#EXTINF:2,\nseg101.ts\n#EXT-X-ENDLIST\n";
    const normalized2 = service.normalizeLivePlaylist(url, poll2WithEndlist);
    assert.ok(!normalized2.includes("#EXT-X-ENDLIST"));

    // Sequence reset on encoder restart injects #EXT-X-DISCONTINUITY
    const poll3Reset = "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXT-X-MEDIA-SEQUENCE:1\n#EXTINF:2,\nseg1.ts\n";
    const normalized3 = service.normalizeLivePlaylist(url, poll3Reset);
    assert.match(normalized3, /#EXT-X-DISCONTINUITY\n#EXTINF:2,/);

    // Genuine VOD playlist starting with ENDLIST on first poll keeps ENDLIST
    const vodUrl = new URL("https://cdn.example/vod.m3u8");
    const vod = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXT-X-MEDIA-SEQUENCE:0\n#EXTINF:6,\nvod0.ts\n#EXT-X-ENDLIST\n";
    assert.equal(service.normalizeLivePlaylist(vodUrl, vod), vod);
});

test("resolver skips empty EXTM3U stubs for active feeds and does not retry unreachable hosts twice", async () => {
    const watch = new URL("https://crackstreams.mx/stream/bears-vs-saints");
    const calls = [];
    const load = async (url) => {
        calls.push(url.href);
        if (url.href === watch.href) {
            return {
                url,
                text: '<iframe src="https://dead.example/embed"></iframe>'
                    + '<iframe src="https://stub.example/embed"></iframe>'
                    + '<iframe src="https://live.example/embed"></iframe>',
            };
        }
        if (url.href === "https://dead.example/embed") {
            throw Object.assign(new Error("Connect timeout"), { network: true });
        }
        if (url.href === "https://stub.example/embed") {
            return { url, text: 'DIRECT_STREAM_URL = "https://cdn.example/empty.m3u8";' };
        }
        if (url.href === "https://cdn.example/empty.m3u8") {
            return { url, text: "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-INDEPENDENT-SEGMENTS\n" };
        }
        if (url.href === "https://live.example/embed") {
            return { url, text: 'DIRECT_STREAM_URL = "https://cdn.example/active.m3u8";' };
        }
        if (url.href === "https://cdn.example/active.m3u8") {
            return { url, text: "#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\nseg1.ts\n" };
        }
        throw new Error("Unexpected URL " + url.href);
    };
    const resolved = await service.resolve(watch, new AbortController().signal, load);
    assert.equal(resolved.url.href, "https://cdn.example/active.m3u8");
    assert.equal(calls.filter(u => u === "https://dead.example/embed").length, 1);
});
test("loopback relay streams raw MPEG-TS chunks before upstream finishes sending the segment", async () => {
    const http = require("node:http");
    const { readFileSync } = require("node:fs");
    const { runInNewContext } = require("node:vm");

    let releaseTail;
    const tailGate = new Promise(resolve => { releaseTail = resolve; });
    let tailReleased = false;
    const chunk1 = Buffer.concat([Buffer.from([0x47]), Buffer.alloc(187, 0xaa), Buffer.from([0x47]), Buffer.alloc(187, 0xbb)]);
    const chunk2 = Buffer.concat([Buffer.from([0x47]), Buffer.alloc(187, 0xcc)]);

    const upstreamServer = http.createServer((req, res) => {
        if (req.url === "/stream/demo") {
            return res.end(`<iframe src="http://stream.example:${upstreamPort}/embed"></iframe>`);
        }
        if (req.url === "/embed") {
            return res.end(`DIRECT_STREAM_URL = "http://stream.example:${upstreamPort}/live.m3u8";`);
        }
        if (req.url === "/live.m3u8") {
            return res.end(`#EXTM3U\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\nhttp://stream.example:${upstreamPort}/part.txt\n`);
        }
        if (req.url === "/part.txt") {
            res.writeHead(200, { "Content-Type": "text/plain", "Content-Length": String(chunk1.length + chunk2.length) });
            res.write(chunk1);
            tailGate.then(() => {
                tailReleased = true;
                res.end(chunk2);
            });
        }
    });
    await new Promise(resolve => upstreamServer.listen(0, "127.0.0.1", resolve));
    const upstreamPort = upstreamServer.address().port;
    const testPort = upstreamPort + 1000 < 65000 ? upstreamPort + 1000 : upstreamPort - 1000;
    const testToken = "b".repeat(64);

    const src = readFileSync(require.resolve("../app/service.js"), "utf8")
        .replace("const port = 48641;", `const port = ${testPort};`)
        .replace('const token = "__TV_TOKEN__";', `const token = "${testToken}";`)
        .replace("|| url.port", "&& false")
        .replace('/^(?:www\\.)?crackstreams\\.mx$/i', '/^(?:stream\\.example)$/i')
        .replace("dns.lookup(name, { family: 4, all: true }, (failure, addresses) => {",
            '((cb) => cb(null, [{ address: "127.0.0.1", family: 4 }]))((failure, addresses) => {')
        .replace("const allowed = addresses.filter(item => publicAddress(item.address));", "const allowed = addresses;");

    const mod = { exports: {} };
    runInNewContext(src, { require: name => require(name), module: mod, Buffer, process, setTimeout, clearTimeout, AbortController });
    await new Promise(resolve => setTimeout(resolve, 40));

    try {
        const playRes = await fetch(`http://127.0.0.1:${testPort}/api/play?t=${testToken}&url=${encodeURIComponent(`http://stream.example:${upstreamPort}/stream/demo`)}`);
        assert.equal(playRes.status, 200);
        const { url: playlistUrl } = await playRes.json();
        const manifest = await (await fetch(playlistUrl)).text();
        const segmentUrl = manifest.split("\n").find(line => line.startsWith("http://"));
        assert.ok(segmentUrl);

        let sawFirstChunkWhileUpstreamOpen = false;
        const received = await new Promise((resolve, reject) => {
            http.get(segmentUrl, res => {
                assert.equal(res.statusCode, 200);
                assert.equal(res.headers["content-type"], "video/mp2t");
                assert.equal(res.headers["content-length"], String(chunk1.length + chunk2.length));
                const parts = [];
                res.on("data", chunk => {
                    if (!parts.length) {
                        sawFirstChunkWhileUpstreamOpen = !tailReleased;
                        releaseTail();
                    }
                    parts.push(chunk);
                });
                res.on("end", () => resolve(Buffer.concat(parts)));
                res.on("error", reject);
            }).on("error", reject);
        });
        assert.equal(sawFirstChunkWhileUpstreamOpen, true);
        assert.deepEqual(received, Buffer.concat([chunk1, chunk2]));
    } finally {
        releaseTail();
        mod.exports.onStop();
        await new Promise(resolve => upstreamServer.close(resolve));
    }
});
