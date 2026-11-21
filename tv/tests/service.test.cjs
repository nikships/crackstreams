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
        assert.equal(url.origin, "http://127.0.0.1:48636");
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
