(function (nodeRequire, hostModule) {
    "use strict";
    const http = nodeRequire("http");
    const https = nodeRequire("https");
    const dns = nodeRequire("dns");
    const net = nodeRequire("net");
    const crypto = nodeRequire("crypto");
    const zlib = nodeRequire("zlib");
    const { URL, URLSearchParams } = nodeRequire("url");
    const port = 48636;
    const host = "127.0.0.1:" + port;
    const origin = "http://" + host;
    const home = "https://crackstreams.mx/";
    const token = "__TV_TOKEN__";
    const userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36";
    const signingKey = crypto.randomBytes(32);
    const textLimit = 4 * 1024 * 1024;
    const mediaLimit = 64 * 1024 * 1024;
    let server;

    function error(status, message) {
        return Object.assign(new Error(message), { status });
    }

    function decode(text) {
        const named = { amp: "&", quot: '"', apos: "'", lt: "<", gt: ">", nbsp: " " };
        return text.replace(/&(#x[0-9a-f]+|#[0-9]+|amp|quot|apos|lt|gt|nbsp);/gi, (match, key) => {
            if (key[0] !== "#") return named[key.toLowerCase()];
            const number = /^#x/i.test(key) ? parseInt(key.slice(2), 16) : Number(key.slice(1));
            return number <= 0x10ffff ? String.fromCodePoint(number) : match;
        });
    }

    function webURL(value, base) {
        try {
            if (!value || value.length > 4096) return null;
            const url = new URL(decode(value.replace(/\\\//g, "/")).trim(), base);
            if (!["http:", "https:"].includes(url.protocol) || url.username || url.password || url.port
                || !url.hostname.includes(".") || net.isIP(url.hostname) || /\.(?:local|localhost|internal)\.?$/i.test(url.hostname)) return null;
            url.hash = "";
            return url;
        } catch (_) { return null; }
    }

    function siteURL(value, path, base = home) {
        const url = webURL(value, base);
        return url && /^(?:www\.)?crackstreams\.mx$/i.test(url.hostname)
            && url.pathname.toLowerCase().startsWith(path) ? url : null;
    }

    function publicAddress(address) {
        if (!net.isIPv4(address)) return false;
        const [a, b, c] = address.split(".").map(Number);
        return !(a === 0 || a === 10 || a === 127 || a >= 224 || (a === 100 && b >= 64 && b <= 127)
            || (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31)
            || (a === 192 && (b === 0 || b === 168 || (b === 88 && c === 99)))
            || (a === 198 && (b === 18 || b === 19)));
    }

    // Filter the addresses used by the connection itself, not a separate preflight DNS lookup.
    function lookup(name, options, callback) {
        dns.lookup(name, { family: 4, all: true }, (failure, addresses) => {
            if (failure) return callback(failure);
            const allowed = addresses.filter(item => publicAddress(item.address));
            if (!allowed.length) return callback(error(400, "This stream points to a local network address."));
            if (options.all) return callback(null, allowed);
            callback(null, allowed[0].address, 4);
        });
    }

    function upstream(url, { signal, referer, range }, hops = 4) {
        return new Promise((resolve, reject) => {
            const headers = { "User-Agent": userAgent, "Accept-Encoding": "identity" };
            if (referer) headers.Referer = referer;
            if (range) headers.Range = range;
            const client = url.protocol === "https:" ? https : http;
            const req = client.get(url, { headers, signal, lookup, family: 4 }, res => {
                if ([301, 302, 303, 307, 308].includes(res.statusCode)) {
                    const next = webURL(res.headers.location, url);
                    res.resume();
                    if (!hops || !next) return reject(error(502, "The stream redirected to an unsupported address."));
                    return resolve(upstream(next, { signal, referer, range }, hops - 1));
                }
                resolve({ response: res, url });
            });
            req.setTimeout(12000, () => req.destroy(error(504, "The stream server took too long to respond.")));
            req.on("error", reject);
        });
    }

    async function readBody(response, limit) {
        const encoding = response.headers["content-encoding"];
        let source = response;
        if (encoding === "gzip" || encoding === "deflate" || encoding === "br") {
            source = encoding === "gzip" ? zlib.createGunzip()
                : encoding === "deflate" ? zlib.createInflate() : zlib.createBrotliDecompress();
            response.on("error", failure => source.destroy(failure));
            response.pipe(source);
        } else if (Number(response.headers["content-length"]) > limit) {
            response.destroy();
            throw error(502, "The stream server returned too much data.");
        }
        const chunks = [];
        let size = 0;
        for await (const chunk of source) {
            size += chunk.length;
            if (size > limit) {
                response.destroy();
                throw error(502, "The stream server returned too much data.");
            }
            chunks.push(chunk);
        }
        return Buffer.concat(chunks, size);
    }

    async function text(url, signal, referer) {
        const { response, url: finalURL } = await upstream(url, { signal, referer });
        if (response.statusCode !== 200) {
            response.destroy();
            throw error(502, "The stream server returned HTTP " + response.statusCode + ".");
        }
        return { text: (await readBody(response, textLimit)).toString("utf8"), url: finalURL };
    }

    function plain(html) {
        return decode(html.replace(/<[^>]+>/g, " ")).replace(/\s+/g, " ").trim();
    }

    function anchor(attributes, inner) {
        const href = /\bhref\s*=\s*["']([^"']+)["']/i.exec(attributes);
        if (!href) return null;
        const classes = /\bclass\s*=\s*["']([^"']*)["']/i.exec(attributes);
        const title = /class\s*=\s*["']card-title["'][^>]*>([\s\S]*?)<\/div>/i.exec(inner);
        const subtitle = /class\s*=\s*["']card-subtitle["'][^>]*>([\s\S]*?)<\/div>/i.exec(inner);
        return { href: href[1], card: Boolean(classes && classes[1].split(/\s+/).includes("card")),
            title: (title && plain(title[1])) || plain(inner), subtitle: subtitle ? plain(subtitle[1]) : "" };
    }

    function leagues(html) {
        const links = [], cards = [];
        for (const match of html.replace(/<!--[\s\S]*?-->/g, "").matchAll(/<a\b([^>]*)>([\s\S]*?)<\/a>/gi)) {
            const entry = anchor(match[1], match[2]);
            const url = entry && siteURL(entry.href, "/league/");
            const name = entry && entry.title.replace(/\s+streams?$/i, "").trim();
            if (url && name) (entry.card ? cards : links).push({ name, url: url.href });
        }
        const names = new Set(), urls = new Set();
        return [...cards, ...links].filter(item => {
            const name = item.name.toLowerCase();
            if (names.has(name) || urls.has(item.url)) return false;
            names.add(name); urls.add(item.url);
            return true;
        });
    }

    function eventStart(day, time) {
        const clock = /^(\d{1,2}):(\d{2})\s*(AM|PM)(?:\s+([ECMP][SD]?T|UTC|GMT))?$/i.exec(time);
        const midnight = Date.parse(day + " 00:00 UTC");
        if (!clock || !Number.isFinite(midnight)) return null;
        const [, h, m, period, zone = "ET"] = clock;
        if (+h < 1 || +h > 12 || +m > 59) return null;
        const zones = { E: "America/New_York", C: "America/Chicago", M: "America/Denver", P: "America/Los_Angeles" };
        const local = midnight + ((Number(h) % 12 + (period.toUpperCase() === "PM" ? 12 : 0)) * 60 + Number(m)) * 60000;
        try {
            const format = new Intl.DateTimeFormat("en-US", { timeZone: zones[zone[0].toUpperCase()] || "UTC",
                year: "numeric", month: "numeric", day: "numeric", hour: "numeric",
                minute: "numeric", hourCycle: "h23" });
            let instant = local;
            for (let step = 0; step < 2; step++) {
                const p = Object.fromEntries(format.formatToParts(instant).map(x => [x.type, Number(x.value)]));
                instant += local - Date.UTC(p.year, p.month - 1, p.day, p.hour, p.minute);
            }
            return new Date(instant).toISOString();
        } catch (_) { return null; }
    }

    function games(html) {
        let day = "";
        const seen = new Set(), results = [];
        for (const [, heading, attributes, inner] of html.replace(/<!--[\s\S]*?-->/g, "")
            .matchAll(/<h2\b[^>]*>([\s\S]*?)<\/h2>|<a\b([^>]*)>([\s\S]*?)<\/a>/gi)) {
            if (heading !== undefined) { day = plain(heading); continue; }
            const entry = anchor(attributes, inner);
            const url = entry && entry.card && siteURL(entry.href, "/stream/");
            if (!url || !entry.title || seen.has(url.href)) continue;
            seen.add(url.href);
            const time = entry.subtitle.replace(/^\s*start\s*time\s*:\s*/i, "");
            results.push({ title: entry.title, url: url.href, detail: time || day,
                start: eventStart(day, time), channel: /24\/7| network$/i.test(entry.title) });
        }
        return results;
    }

    function embeds(html, base) {
        const streams = /(?:const|let|var)\s+allStreams\s*=\s*(\[[\s\S]*?\])\s*;/.exec(html);
        const urls = [];
        if (streams) {
            try {
                for (const item of JSON.parse(streams[1])) {
                    const url = item && webURL(item.value, base);
                    if (url) urls.push(url);
                    if (urls.length === 8) return urls;
                }
            } catch (_) {}
        }
        if (urls.length) return urls;
        for (const [, src] of html.matchAll(/<iframe\b[^>]*\ssrc=["']([^"']+)["']/gi)) {
            const url = webURL(src, base);
            if (url && !/chatango|histats|dtscout|google|doubleclick|cloudflare/i.test(url.hostname)) urls.push(url);
            if (urls.length === 8) break;
        }
        return urls;
    }

    function playlistIn(html, base) {
        const match = /DIRECT_STREAM_URL\s*=\s*["']([^"']+)["']/i.exec(html)
            || /(https?:\/\/[^"'\\\s]+\.m3u8[^"'\\\s]*)/i.exec(html);
        return match && webURL(match[1], base);
    }

    async function resolve(url, signal) {
        const title = decodeURIComponent(url.pathname.split("/").filter(Boolean).pop() || "Stream")
            .replace(/\.m3u8$/i, "").replace(/[-_]+/g, " ");
        const originRef = value => value.origin + "/";
        const check = async (value, referer) => {
            const result = await text(value, signal, referer);
            return /^#EXTM3U\b/.test(result.text) ? { url: result.url, referer, title } : null;
        };
        if (/\.m3u8$/i.test(url.pathname)) {
            const direct = await check(url, originRef(url));
            if (direct) return direct;
            throw error(502, "That link didn’t return an HLS playlist.");
        }
        const watch = await text(url, signal);
        const candidates = embeds(watch.text, watch.url);
        if (!candidates.length) throw error(502, "No stream player was found on that page.");
        for (const embed of candidates) {
            for (const referer of new Set([originRef(embed), originRef(watch.url)])) {
                if (signal.aborted) throw signal.reason;
                try {
                    const page = await text(embed, signal, referer);
                    const playlist = playlistIn(page.text, page.url);
                    const playable = playlist && await check(playlist, originRef(page.url));
                    if (playable) return playable;
                } catch (failure) { if (signal.aborted) throw failure; }
            }
        }
        throw error(502, "The stream isn’t live yet, or all of its feeds are unavailable.");
    }

    function sign(path, url, referer) {
        return crypto.createHmac("sha256", signingKey).update(JSON.stringify([path, url, referer])).digest("hex");
    }

    function equal(left, right) {
        if (typeof left !== "string" || !/^[a-f0-9]{64}$/.test(left)) return false;
        return crypto.timingSafeEqual(Buffer.from(left, "hex"), Buffer.from(right, "hex"));
    }

    function relayURL(path, url, referer) {
        const query = new URLSearchParams({ u: url.href, r: referer, t: sign(path, url.href, referer) });
        return origin + path + "?" + query.toString();
    }

    function mediaPath(url) {
        const ext = url.pathname.split(".").pop().toLowerCase();
        return "/segment." + (["m4s", "mp4", "aac", "m4a", "cmfv", "cmfa", "vtt"].includes(ext) ? ext : "ts");
    }

    function rewrite(playlist, base, referer) {
        let variant = false;
        const link = (raw, kind) => {
            const url = webURL(raw, base);
            return url ? relayURL(kind || mediaPath(url), url, referer) : origin + "/unavailable";
        };
        return playlist.split(/\r?\n/).map(line => {
            const trimmed = line.trim();
            if (!trimmed) return line;
            if (trimmed[0] !== "#") {
                const path = variant || /\.m3u8(?:\?|$)/i.test(trimmed) ? "/stream.m3u8" : "";
                variant = false;
                return link(trimmed, path);
            }
            if (trimmed.startsWith("#EXT-X-STREAM-INF:")) variant = true;
            const path = /^#EXT-X-(?:MEDIA|I-FRAME-STREAM-INF|RENDITION-REPORT):/.test(trimmed) ? "/stream.m3u8"
                : /^#EXT-X-(?:KEY|SESSION-KEY):/.test(trimmed) ? "/key.bin"
                    : /^#EXT-X-MAP:/.test(trimmed) ? "/init.mp4" : "";
            return line.replace(/\bURI="([^"]+)"/g, (_, value) => 'URI="' + link(value, path) + '"');
        }).join("\n");
    }

    function slice(data, range) {
        const match = /^bytes=(\d*)-(\d*)$/.exec(range);
        if (!match || !data.length || (!match[1] && !match[2])) return null;
        const start = match[1] ? Number(match[1]) : Math.max(0, data.length - Number(match[2]));
        const end = match[1] && match[2] ? Math.min(Number(match[2]), data.length - 1) : data.length - 1;
        return start <= end && Number.isSafeInteger(start) ? { start, end, data: data.subarray(start, end + 1) } : null;
    }

    function send(res, code, body, type, head = false, extra = {}) {
        res.writeHead(code, { "Content-Type": type, "Content-Length": Buffer.byteLength(body),
            "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff",
            "Access-Control-Allow-Origin": "*", ...extra });
        res.end(head ? undefined : body);
    }

    function json(res, code, body) {
        send(res, code, JSON.stringify(body), "application/json; charset=utf-8");
    }

    async function handle(req, res) {
        if (req.headers.host !== host || !req.url.startsWith("/") || req.url.length > 16000) {
            return json(res, 403, { error: "Forbidden" });
        }
        if (req.method === "OPTIONS") {
            res.writeHead(204, { "Access-Control-Allow-Origin": "*", "Access-Control-Allow-Methods": "GET, HEAD",
                "Access-Control-Allow-Private-Network": "true" });
            return res.end();
        }
        const route = new URL(req.url, origin);
        const deadline = new AbortController();
        const timer = setTimeout(() => deadline.abort(), 38000);
        const signal = deadline.signal;
        res.on("close", () => { clearTimeout(timer); deadline.abort(); });
        try {
            if (route.pathname.startsWith("/api/")) {
                if (req.method !== "GET") return json(res, 405, { error: "Method not allowed" });
                if (!equal(route.searchParams.get("t"), token)) return json(res, 403, { error: "Forbidden" });
                const source = route.searchParams.get("url");
                switch (route.pathname) {
                case "/api/ping":
                    return json(res, 200, { ok: true });
                case "/api/leagues": {
                    const list = leagues((await text(new URL(home), signal)).text);
                    if (!list.length) throw error(502, "No sports are listed on the stream site right now.");
                    return json(res, 200, list);
                }
                case "/api/games": {
                    const league = siteURL(source, "/league/");
                    if (!league) throw error(400, "Choose a sport from the directory.");
                    return json(res, 200, games((await text(league, signal)).text));
                }
                case "/api/play": {
                    const watch = webURL(source);
                    if (!watch || (!/\.m3u8$/i.test(watch.pathname) && !siteURL(source, "/stream/"))) {
                        throw error(400, "Enter a Crackstreams watch link or a public .m3u8 URL.");
                    }
                    const stream = await resolve(watch, signal);
                    return json(res, 200, { title: stream.title, url: relayURL("/stream.m3u8", stream.url, stream.referer) });
                }
                default:
                    return json(res, 404, { error: "Not found" });
                }
            }

            if (!["GET", "HEAD"].includes(req.method)) return json(res, 405, { error: "Method not allowed" });
            const source = route.searchParams.get("u"), referer = route.searchParams.get("r");
            if (!equal(route.searchParams.get("t"), sign(route.pathname, source, referer))) {
                return json(res, 403, { error: "Forbidden" });
            }
            const url = webURL(source);
            if (!url) return json(res, 400, { error: "Invalid media address" });
            const range = req.headers.range, head = req.method === "HEAD";
            const { response, url: base } = await upstream(url, { signal, referer, range });
            const code = response.statusCode;
            if (code < 200 || code >= 300) {
                response.destroy();
                return send(res, code, "", "text/plain", head);
            }
            const playlist = route.pathname.endsWith(".m3u8");
            const bytes = await readBody(response, playlist ? textLimit : mediaLimit);
            if (bytes.toString("utf8", 0, 7) === "#EXTM3U") {
                const body = rewrite(bytes.toString("utf8"), base, referer);
                return send(res, 200, body, "application/vnd.apple.mpegurl", head);
            }
            const type = route.pathname.endsWith(".ts") ? "video/mp2t" : response.headers["content-type"] || "application/octet-stream";
            if (code === 206 && response.headers["content-range"]) {
                return send(res, 206, bytes, type, head, { "Content-Range": response.headers["content-range"], "Accept-Ranges": "bytes" });
            }
            if (range) {
                const part = slice(bytes, range);
                if (!part) return send(res, 416, "", type, head, { "Content-Range": "bytes */" + bytes.length });
                return send(res, 206, part.data, type, head, { "Content-Range": `bytes ${part.start}-${part.end}/${bytes.length}`, "Accept-Ranges": "bytes" });
            }
            return send(res, 200, bytes, type, head, { "Accept-Ranges": "bytes" });
        } catch (failure) {
            if (!res.destroyed && !res.headersSent) {
                const message = signal.aborted ? "The stream server took too long to respond."
                    : failure.status ? failure.message : "Couldn’t reach the stream server.";
                json(res, signal.aborted ? 504 : failure.status || 502, { error: message });
            }
        }
    }

    function start() {
        if (server) return;
        server = http.createServer((req, res) => {
            handle(req, res).catch(() => { if (!res.destroyed) res.destroy(); });
        });
        server.headersTimeout = 5000;
        server.once("error", () => { server = undefined; });
        server.listen(port, "127.0.0.1");
    }

    const packaged = /^[a-f0-9]{64}$/.test(token);
    if (packaged) start();
    if (hostModule && hostModule.exports) {
        if (packaged) {
            hostModule.exports.onStart = start;
            hostModule.exports.onRequest = start;
            hostModule.exports.onStop = () => { if (server) server.close(); server = undefined; };
        } else {
            hostModule.exports = { leagues, games, embeds, playlistIn, webURL, publicAddress, rewrite, sign, slice, eventStart };
        }
    }
})(typeof require === "function" ? require : null, typeof module === "object" ? module : null);
