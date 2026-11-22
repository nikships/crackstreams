(function (nodeRequire, hostModule) {
    "use strict";
    const http = nodeRequire("http");
    const https = nodeRequire("https");
    const dns = nodeRequire("dns");
    const net = nodeRequire("net");
    const crypto = nodeRequire("crypto");
    const zlib = nodeRequire("zlib");
    const { URL, URLSearchParams } = nodeRequire("url");
    const port = 48641;
    const host = "127.0.0.1:" + port;
    const origin = "http://" + host;
    const home = "https://crackstreams.mx/";
    const token = "__TV_TOKEN__";
    const userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36";
    const signingKey = crypto.randomBytes(32);
    const textLimit = 4 * 1024 * 1024;
    const mediaLimit = 64 * 1024 * 1024;
    const liveWindows = new Map();
    const playlistStates = new Map();
    const dnsCache = new Map();
    const httpAgent = new http.Agent({ keepAlive: true, keepAliveMsecs: 15000, maxSockets: 16, maxFreeSockets: 8 });
    const httpsAgent = new https.Agent({ keepAlive: true, keepAliveMsecs: 15000, maxSockets: 16, maxFreeSockets: 8 });
    let server;

    function error(status, message, network = false) {
        return Object.assign(new Error(message), { status, network });
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

    // Filter and cache only validated public IPv4 addresses used by the connection itself.
    function lookup(name, options, callback) {
        const cached = dnsCache.get(name);
        if (cached && cached.expires > Date.now()) {
            return process.nextTick(() => {
                if (options.all) callback(null, cached.allowed);
                else callback(null, cached.allowed[0].address, 4);
            });
        }
        dns.lookup(name, { family: 4, all: true }, (failure, addresses) => {
            if (failure) return callback(failure);
            const allowed = addresses.filter(item => publicAddress(item.address));
            if (!allowed.length) return callback(error(400, "This stream points to a local network address."));
            dnsCache.delete(name);
            dnsCache.set(name, { allowed, expires: Date.now() + 60000 });
            if (dnsCache.size > 64) dnsCache.delete(dnsCache.keys().next().value);
            if (options.all) return callback(null, allowed);
            callback(null, allowed[0].address, 4);
        });
    }

    function upstream(url, { signal, referer, range, timeout = 12000 }, hops = 4) {
        return new Promise((resolve, reject) => {
            const headers = { "User-Agent": userAgent, "Accept-Encoding": "identity" };
            if (referer) headers.Referer = referer;
            if (range) headers.Range = range;
            const secure = url.protocol === "https:";
            const client = secure ? https : http;
            const agent = secure ? httpsAgent : httpAgent;
            const req = client.get(url, { headers, signal, lookup, family: 4, agent }, res => {
                if ([301, 302, 303, 307, 308].includes(res.statusCode)) {
                    const next = webURL(res.headers.location, url);
                    res.resume();
                    if (!hops || !next) return reject(error(502, "The stream redirected to an unsupported address."));
                    return resolve(upstream(next, { signal, referer, range, timeout }, hops - 1));
                }
                resolve({ response: res, url });
            });
            req.setTimeout(timeout, () => req.destroy(error(504, "The stream server took too long to respond.", true)));
            req.on("error", failure => {
                if (!failure.status) failure.network = true;
                reject(failure);
            });
        });
    }

    async function readBody(response, limit, prefix = null, ended = false) {
        const encoding = response.headers["content-encoding"];
        if (!prefix && (encoding === "gzip" || encoding === "deflate" || encoding === "br")) {
            const source = encoding === "gzip" ? zlib.createGunzip()
                : encoding === "deflate" ? zlib.createInflate() : zlib.createBrotliDecompress();
            response.on("error", failure => source.destroy(failure));
            response.pipe(source);
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
        if (Number(response.headers["content-length"]) > limit || (prefix && prefix.length > limit)) {
            response.destroy();
            throw error(502, "The stream server returned too much data.");
        }
        if (ended) return prefix || Buffer.alloc(0);
        const chunks = prefix && prefix.length ? [prefix] : [];
        let size = prefix ? prefix.length : 0;
        if (prefix) response.resume();
        for await (const chunk of response) {
            size += chunk.length;
            if (size > limit) {
                response.destroy();
                throw error(502, "The stream server returned too much data.");
            }
            chunks.push(chunk);
        }
        return chunks.length === 1 ? chunks[0] : Buffer.concat(chunks, size);
    }

    function peekPrefix(response, needed) {
        return new Promise((resolve, reject) => {
            const chunks = [];
            let length = 0;
            function cleanup() {
                response.removeListener("data", onData);
                response.removeListener("end", onEnd);
                response.removeListener("error", onError);
            }
            function onData(chunk) {
                chunks.push(chunk);
                length += chunk.length;
                if (length >= needed) {
                    response.pause();
                    cleanup();
                    resolve({ prefix: chunks.length === 1 ? chunks[0] : Buffer.concat(chunks, length), ended: false });
                }
            }
            function onEnd() {
                cleanup();
                resolve({ prefix: chunks.length === 1 ? chunks[0] : Buffer.concat(chunks, length), ended: true });
            }
            function onError(failure) {
                cleanup();
                reject(failure);
            }
            response.on("data", onData);
            response.on("end", onEnd);
            response.on("error", onError);
        });
    }

    function streamRemainder(response, res, prefix, limit) {
        return new Promise((resolve, reject) => {
            let total = prefix.length;
            let settled = false;
            function finish(failure) {
                if (settled) return;
                settled = true;
                response.removeListener("data", onData);
                response.removeListener("end", onEnd);
                response.removeListener("error", onError);
                res.removeListener("close", onClose);
                res.removeListener("error", onError);
                if (failure) {
                    response.destroy();
                    if (!res.destroyed) res.destroy();
                    reject(failure);
                } else {
                    resolve();
                }
            }
            function onData(chunk) {
                total += chunk.length;
                if (total > limit) return finish(error(502, "The stream server returned too much data."));
                if (!res.write(chunk)) {
                    response.pause();
                    res.once("drain", () => { if (!settled) response.resume(); });
                }
            }
            function onEnd() {
                res.end();
                finish();
            }
            function onError(failure) {
                finish(failure);
            }
            function onClose() {
                if (!res.writableEnded) {
                    response.destroy();
                    finish();
                }
            }
            response.on("data", onData);
            response.on("end", onEnd);
            response.on("error", onError);
            res.on("close", onClose);
            res.on("error", onError);
            if (prefix.length && !res.write(prefix)) {
                res.once("drain", () => { if (!settled) response.resume(); });
            } else {
                response.resume();
            }
        });
    }

    async function text(url, signal, referer, timeout = 12000) {
        const { response, url: finalURL } = await upstream(url, { signal, referer, timeout });
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

    function event(html, className) {
        const heading = /<h1\b[^>]*>([\s\S]*?)<\/h1>/i.exec(html);
        const info = new RegExp(`<div\\b[^>]*class=["']${className}["'][^>]*>([\\s\\S]*?)<\\/div>`, "i").exec(html);
        if (!heading || !info) return null;
        const teams = plain(heading[1]).toLowerCase().replace(/^ncaaf\s*:\s*/, "")
            .replace(/\s+(?:vs\.?|at)\s+/, " vs ").replace(/[^a-z0-9]+/g, " ").trim();
        const detail = plain(info[1]);
        const date = /\b(?:January|February|March|April|May|June|July|August|September|October|November|December) \d{1,2}, \d{4}\b/i.exec(detail);
        return date && { teams, date: date[0].toLowerCase(), college: /^\s*NCAA\b/i.test(detail) };
    }

    function alternatePages(url, match) {
        const slug = /^\/stream\/([a-z0-9-]+)\/?$/i.exec(url.pathname);
        if (!match || !slug || !siteURL(url.href, "/stream/") || !slug[1].includes("-vs-")) return [];
        const name = slug[1].replace("-vs-", "-at-");
        return (match.college ? ["ncaaf-" + name, name] : [name])
            .map(path => new URL("https://hdcrackstreams.live/custom-stream/" + path));
    }

    function staleLiveWindow(url, playlist, now = Date.now()) {
        if (!/^#EXTINF:/m.test(playlist) || /^#EXT-X-ENDLIST\b/m.test(playlist)) return false;
        const target = /^#EXT-X-TARGETDURATION:(\d+)/m.exec(playlist);
        if (!target) return false;
        // Ignore metadata edits; track the actual live edge and the window's sequence.
        const edge = playlist.split(/\r?\n/).map(line => line.trim()).filter(line =>
            line && (line[0] !== "#" || /^#EXT-X-(?:PART:|BYTERANGE:|MEDIA-SEQUENCE:)/.test(line)));
        const sequence = edge.find(line => line.startsWith("#EXT-X-MEDIA-SEQUENCE:"));
        const fingerprint = crypto.createHash("sha256").update(JSON.stringify([sequence, edge.slice(-3)])).digest("hex");
        const key = url.href;
        const previous = liveWindows.get(key);
        const entry = previous?.fingerprint === fingerprint ? previous : { fingerprint, since: now };
        liveWindows.delete(key);
        liveWindows.set(key, entry);
        if (liveWindows.size > 32) liveWindows.delete(liveWindows.keys().next().value);
        return now - entry.since >= Math.max(12000, Number(target[1]) * 3000);
    }

    function normalizeLivePlaylist(url, manifest) {
        if (!/^#EXTINF:/m.test(manifest)) return manifest;
        const key = url.href;
        const previous = playlistStates.get(key);
        const hasEndlist = /^#EXT-X-ENDLIST\b/m.test(manifest);
        let result = manifest;
        // Upstream relays occasionally emit a transient ENDLIST or jump sequence numbers when restarting.
        if (hasEndlist && previous?.live) {
            result = result.replace(/^#EXT-X-ENDLIST\b[^\r\n]*(?:\r?\n|$)/gm, "");
        }
        const seqMatch = /^#EXT-X-MEDIA-SEQUENCE:\s*(\d+)/m.exec(result);
        const seq = seqMatch ? Number(seqMatch[1]) : null;
        if (seq !== null && previous?.seq !== null && previous?.seq !== undefined
            && (seq < previous.seq || seq - previous.seq > 10)
            && !/^#EXT-X-DISCONTINUITY\b/m.test(result)) {
            result = result.replace(/^#EXTINF:/m, "#EXT-X-DISCONTINUITY\n#EXTINF:");
        }
        playlistStates.delete(key);
        playlistStates.set(key, { live: !hasEndlist || Boolean(previous?.live), seq: seq ?? previous?.seq ?? null });
        if (playlistStates.size > 32) playlistStates.delete(playlistStates.keys().next().value);
        return result;
    }

    async function resolve(url, signal, load = text, avoid = new Set()) {
        const originRef = value => value.origin + "/";
        const probe = load === text ? (target, sig, ref) => text(target, sig, ref, 6500) : load;
        let fallback;
        let stalled = false;
        const check = async (value, referer) => {
            const result = await probe(value, signal, referer);
            if (!/^#EXTM3U\b/.test(result.text)) return null;
            const feed = sign("feed", result.url.href, "");
            const stream = { url: result.url, referer, feed };
            const stale = staleLiveWindow(result.url, result.text);
            const hasMedia = /^#EXT(?:-X-STREAM-INF|INF):/m.test(result.text);
            if (!avoid.has(feed) && hasMedia) return stream;
            if (stale) stalled = true;
            else fallback ||= stream;
            return null;
        };
        async function fromEmbeds(page, maxDepth, maxPages) {
            const visited = new Set([page.url.href]);
            const queue = embeds(page.text, page.url).map(url => ({ url, parent: page.url, depth: 1 }));
            while (queue.length && maxPages > 0) {
                const { url, parent, depth } = queue.shift();
                if (visited.has(url.href)) continue;
                visited.add(url.href);
                maxPages--;
                for (const referer of new Set([originRef(url), originRef(parent)])) {
                    if (signal.aborted) throw signal.reason;
                    try {
                        const child = await probe(url, signal, referer);
                        const playlist = playlistIn(child.text, child.url);
                        const playable = playlist && await check(playlist, originRef(child.url));
                        if (playable) return playable;
                        if (depth < maxDepth) {
                            const next = embeds(child.text, child.url);
                            if (next.length) {
                                queue.push(...next.map(url => ({ url, parent: child.url, depth: depth + 1 })));
                                break;
                            }
                        }
                    } catch (failure) {
                        if (signal.aborted) throw failure;
                        if (failure && failure.network) break;
                    }
                }
            }
            return null;
        }

        const watch = await probe(url, signal);
        const primary = await fromEmbeds(watch, 1, 8);
        if (primary) return primary;
        const match = event(watch.text, "event-info");
        for (const alternative of alternatePages(watch.url, match)) {
            if (signal.aborted) throw signal.reason;
            try {
                const page = await probe(alternative, signal);
                if (page.url.origin !== alternative.origin) continue;
                const candidate = event(page.text, "custom-player-category");
                if (!candidate || candidate.teams !== match.teams || candidate.date !== match.date) continue;
                const playable = await fromEmbeds(page, 3, 5);
                if (playable) return playable;
            } catch (failure) { if (signal.aborted) throw failure; }
        }
        if (fallback) return fallback;
        if (stalled) throw error(502, "The live feed stopped updating.");
        throw error(502, "No compatible direct feed was found. Try another link or try again later.");
    }

    const pngSignature = Buffer.from("89504e470d0a1a0a", "hex");
    const riffSignature = Buffer.from("RIFF");
    const webpSignature = Buffer.from("WEBP");
    const pixelMarker = Buffer.from("TIKTIKPX");
    const rawMarker = Buffer.from("TIKTIKRAW");
    const gzipMarker = Buffer.from("TIKTIKTSGZ");
    const unpackLimit = 32 * 1024 * 1024;

    function transportStream(data) {
        return data.length > 188 && data[0] === 0x47 && data[188] === 0x47;
    }

    function mp4Box(data) {
        if (data.length < 8) return false;
        const box = data.toString("ascii", 4, 8);
        return box === "ftyp" || box === "styp" || box === "moof" || box === "mdat";
    }

    function rawMediaPrefix(pathname, prefix) {
        if (pathname === "/key.bin") return true;
        if (transportStream(prefix) || mp4Box(prefix)) return true;
        if (prefix.length >= 3 && (prefix.toString("ascii", 0, 3) === "ID3" || (prefix[0] === 0xff && (prefix[1] & 0xf0) === 0xf0))) return true;
        return prefix.length >= 6 && prefix.toString("utf8", 0, 6) === "WEBVTT";
    }

    function playlistPrefix(prefix) {
        if (!prefix.length) return false;
        const head = prefix.toString("utf8", 0, Math.min(prefix.length, 32)).replace(/^\ufeff/, "").trimStart();
        return head.startsWith("#EXTM3U");
    }

    function webpExifSegment(data) {
        if (data.length < 16 || !data.subarray(0, 4).equals(riffSignature) || !data.subarray(8, 12).equals(webpSignature)) return null;
        for (let offset = 12; offset + 8 <= data.length;) {
            const tag = data.toString("ascii", offset, offset + 4);
            const size = data.readUInt32LE(offset + 4);
            offset += 8;
            if (size > data.length - offset) return null;
            if (tag === "EXIF") {
                const part = data.subarray(offset, offset + size);
                return transportStream(part) ? part : null;
            }
            offset += size + (size & 1);
        }
        return null;
    }

    function parsePng(data) {
        if (!data.subarray(0, 8).equals(pngSignature)) return null;
        const chunks = [];
        let width = 0, height = 0, channels = 0, trailer = null;
        for (let offset = 8; offset + 12 <= data.length;) {
            const length = data.readUInt32BE(offset);
            if (length > data.length - offset - 12) break;
            const type = data.toString("ascii", offset + 4, offset + 8);
            const part = data.subarray(offset + 8, offset + 8 + length);
            offset += length + 12;
            if (type === "IHDR" && length === 13) {
                width = part.readUInt32BE(0);
                height = part.readUInt32BE(4);
                const color = part[9];
                if (part[8] === 8 && !part[10] && !part[11] && !part[12]) channels = color === 2 ? 3 : color === 6 ? 4 : 0;
            } else if (type === "IDAT") {
                chunks.push(part);
            } else if (type === "IEND" && length === 0) {
                trailer = data.subarray(offset);
                break;
            }
        }
        return trailer ? { width, height, channels, chunks, trailer } : null;
    }

    function extractPixelGzip(raw, width, height, channels) {
        const stride = width * channels;
        const expected = (stride + 1) * height;
        if (raw.length !== expected) return null;
        const rowRgb = width * 3;
        const pixels = Buffer.allocUnsafe(rowRgb * height);
        let maxRows = height;
        for (let y = 0; y < maxRows; y++) {
            const row = y * (stride + 1) + 1;
            const filter = raw[row - 1];
            const prev = row - stride - 1;
            if (filter === 1) {
                for (let x = channels; x < stride; x++) raw[row + x] = (raw[row + x] + raw[row + x - channels]) & 255;
            } else if (filter === 2) {
                if (y > 0) for (let x = 0; x < stride; x++) raw[row + x] = (raw[row + x] + raw[prev + x]) & 255;
            } else if (filter === 3) {
                for (let x = 0; x < stride; x++) {
                    const left = x >= channels ? raw[row + x - channels] : 0;
                    const up = y > 0 ? raw[prev + x] : 0;
                    raw[row + x] = (raw[row + x] + ((left + up) >> 1)) & 255;
                }
            } else if (filter === 4) {
                for (let x = 0; x < stride; x++) {
                    const left = x >= channels ? raw[row + x - channels] : 0;
                    const up = y > 0 ? raw[prev + x] : 0;
                    const corner = y > 0 && x >= channels ? raw[prev + x - channels] : 0;
                    const p = left + up - corner, a = Math.abs(p - left), b = Math.abs(p - up), c = Math.abs(p - corner);
                    const predictor = a <= b && a <= c ? left : b <= c ? up : corner;
                    raw[row + x] = (raw[row + x] + predictor) & 255;
                }
            } else if (filter !== 0) {
                return null;
            }
            const dst = y * rowRgb;
            if (channels === 3) {
                raw.copy(pixels, dst, row, row + stride);
            } else {
                for (let x = 0, out = dst; x < stride; x += 4) {
                    pixels[out++] = raw[row + x];
                    pixels[out++] = raw[row + x + 1];
                    pixels[out++] = raw[row + x + 2];
                }
            }
            if (dst + rowRgb >= 12 && maxRows === height) {
                if (!pixels.subarray(0, 8).equals(pixelMarker)) return null;
                const length = pixels.readUInt32BE(8);
                if (length < 2 || length > pixels.length - 12) return null;
                maxRows = Math.min(height, Math.ceil((12 + length) / rowRgb));
            } else if (y === 0 && rowRgb >= 8 && !pixels.subarray(0, 8).equals(pixelMarker)) {
                return null;
            }
        }
        if (pixels.length < 12 || !pixels.subarray(0, 8).equals(pixelMarker)) return null;
        const length = pixels.readUInt32BE(8);
        return length >= 2 && length <= pixels.length - 12 ? pixels.subarray(12, 12 + length) : null;
    }

    function scanFallbackSegment(data) {
        const rawIdx = data.indexOf(rawMarker);
        if (rawIdx !== -1) {
            const part = data.subarray(rawIdx + rawMarker.length);
            if (transportStream(part)) return { kind: "raw", data: part };
        }
        const gzIdx = data.indexOf(gzipMarker);
        if (gzIdx !== -1) return { kind: "gzip", data: data.subarray(gzIdx + gzipMarker.length) };
        const scanEnd = Math.min(data.length - 188, 4096);
        for (let i = 1; i < scanEnd; i++) {
            if (data[i] === 0x47 && data[i + 188] === 0x47) return { kind: "raw", data: data.subarray(i) };
        }
        return null;
    }

    function unpackSegment(data) {
        if (!data || !data.length || transportStream(data) || mp4Box(data)) return data;
        const webp = webpExifSegment(data);
        if (webp) return webp;
        const png = parsePng(data);
        if (png) {
            if (transportStream(png.trailer)) return png.trailer;
            if (png.channels && png.width && png.height && png.width * png.height <= 4 * 1024 * 1024) {
                try {
                    const expected = (png.width * png.channels + 1) * png.height;
                    const raw = zlib.inflateSync(Buffer.concat(png.chunks), { maxOutputLength: expected });
                    const gz = extractPixelGzip(raw, png.width, png.height, png.channels);
                    if (gz) {
                        const body = zlib.gunzipSync(gz, { maxOutputLength: unpackLimit });
                        if (transportStream(body)) return body;
                    }
                } catch (_) {}
            }
            return data;
        }
        const found = scanFallbackSegment(data);
        if (!found) return data;
        if (found.kind === "raw") return found.data;
        try {
            const body = zlib.gunzipSync(found.data, { maxOutputLength: unpackLimit });
            return transportStream(body) ? body : data;
        } catch (_) { return data; }
    }

    function inflateBuffer(buf, maxOutputLength) {
        return new Promise((resolve, reject) => zlib.inflate(buf, { maxOutputLength }, (err, out) => err ? reject(err) : resolve(out)));
    }

    function gunzipBuffer(buf, maxOutputLength) {
        return new Promise((resolve, reject) => zlib.gunzip(buf, { maxOutputLength }, (err, out) => err ? reject(err) : resolve(out)));
    }

    async function unpackSegmentAsync(data) {
        if (!data || !data.length || transportStream(data) || mp4Box(data)) return data;
        const webp = webpExifSegment(data);
        if (webp) return webp;
        const png = parsePng(data);
        if (png) {
            if (transportStream(png.trailer)) return png.trailer;
            if (png.channels && png.width && png.height && png.width * png.height <= 4 * 1024 * 1024) {
                try {
                    const expected = (png.width * png.channels + 1) * png.height;
                    const raw = await inflateBuffer(Buffer.concat(png.chunks), expected);
                    const gz = extractPixelGzip(raw, png.width, png.height, png.channels);
                    if (gz) {
                        const body = await gunzipBuffer(gz, unpackLimit);
                        if (transportStream(body)) return body;
                    }
                } catch (_) {}
            }
            return data;
        }
        const found = scanFallbackSegment(data);
        if (!found) return data;
        if (found.kind === "raw") return found.data;
        try {
            const body = await gunzipBuffer(found.data, unpackLimit);
            return transportStream(body) ? body : data;
        } catch (_) { return data; }
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

    function sendPlaylist(res, base, referer, rawText, head) {
        const manifest = rawText.replace(/^\ufeff/, "");
        staleLiveWindow(base, manifest);
        const normalized = normalizeLivePlaylist(base, manifest);
        const body = rewrite(normalized, base, referer);
        return send(res, 200, body, "application/vnd.apple.mpegurl", head);
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
        res.on("close", () => { clearTimeout(timer); if (!res.writableEnded) deadline.abort(); });
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
                    const watch = siteURL(source, "/stream/");
                    if (!watch) throw error(400, "Choose a game from the directory.");
                    const avoid = new Set(route.searchParams.getAll("avoid").slice(0, 2).filter(id => /^[a-f0-9]{64}$/.test(id)));
                    const stream = await resolve(watch, signal, text, avoid);
                    return json(res, 200, { url: relayURL("/stream.m3u8", stream.url, stream.referer), feed: stream.feed });
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
            const tsSegment = route.pathname.endsWith(".ts");
            const { response, url: base } = await upstream(url, { signal, referer, range: tsSegment ? undefined : range });
            const code = response.statusCode;
            if (code < 200 || code >= 300) {
                response.destroy();
                return send(res, code, "", "text/plain", head);
            }
            const playlist = route.pathname.endsWith(".m3u8");
            if (playlist) {
                const bytes = await readBody(response, textLimit);
                if (playlistPrefix(bytes)) return sendPlaylist(res, base, referer, bytes.toString("utf8"), head);
            }

            const type = tsSegment ? "video/mp2t" : (response.headers["content-type"] || "application/octet-stream").replace(/[\r\n]/g, "");
            const encoding = response.headers["content-encoding"];
            const compressed = encoding === "gzip" || encoding === "deflate" || encoding === "br";

            if (head && !tsSegment) {
                const upstreamLen = response.headers["content-length"];
                response.destroy();
                const extra = { "Accept-Ranges": "bytes" };
                if (code === 206 && response.headers["content-range"]) extra["Content-Range"] = response.headers["content-range"];
                if (upstreamLen && /^\d+$/.test(upstreamLen) && Number(upstreamLen) <= mediaLimit) {
                    res.writeHead(code, { "Content-Type": type, "Content-Length": upstreamLen,
                        "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff",
                        "Access-Control-Allow-Origin": "*", ...extra });
                    return res.end();
                }
                return send(res, code, "", type, true, extra);
            }

            // Stream standard media directly so AVPlay starts decoding immediately and measures real network bandwidth.
            if (!compressed && !head) {
                const { prefix, ended } = await peekPrefix(response, 189);
                if (playlistPrefix(prefix)) {
                    const bytes = await readBody(response, textLimit, prefix, ended);
                    return sendPlaylist(res, base, referer, bytes.toString("utf8"), false);
                }
                if (rawMediaPrefix(route.pathname, prefix) && (!range || code === 206)) {
                    const upstreamLen = response.headers["content-length"];
                    if (upstreamLen && Number(upstreamLen) > mediaLimit) {
                        response.destroy();
                        throw error(502, "The stream server returned too much data.");
                    }
                    const extra = { "Accept-Ranges": "bytes" };
                    if (code === 206 && response.headers["content-range"]) extra["Content-Range"] = response.headers["content-range"];
                    if (ended) return send(res, code, prefix, type, false, extra);
                    const headers = {
                        "Content-Type": type,
                        "Cache-Control": "no-store",
                        "X-Content-Type-Options": "nosniff",
                        "Access-Control-Allow-Origin": "*",
                        ...extra,
                    };
                    if (upstreamLen && /^\d+$/.test(upstreamLen)) headers["Content-Length"] = upstreamLen;
                    res.writeHead(code, headers);
                    return await streamRemainder(response, res, prefix, mediaLimit);
                }
                let bytes = await readBody(response, mediaLimit, prefix, ended);
                if (tsSegment) bytes = await unpackSegmentAsync(bytes);
                if (playlistPrefix(bytes)) return sendPlaylist(res, base, referer, bytes.toString("utf8"), false);
                if (code === 206 && response.headers["content-range"]) {
                    return send(res, 206, bytes, type, false, { "Content-Range": response.headers["content-range"], "Accept-Ranges": "bytes" });
                }
                if (range) {
                    const part = slice(bytes, range);
                    if (!part) return send(res, 416, "", type, false, { "Content-Range": "bytes */" + bytes.length });
                    return send(res, 206, part.data, type, false, { "Content-Range": `bytes ${part.start}-${part.end}/${bytes.length}`, "Accept-Ranges": "bytes" });
                }
                return send(res, 200, bytes, type, false, { "Accept-Ranges": "bytes" });
            }

            let bytes = await readBody(response, mediaLimit);
            if (tsSegment) bytes = await unpackSegmentAsync(bytes);
            if (playlistPrefix(bytes)) return sendPlaylist(res, base, referer, bytes.toString("utf8"), head);
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
            } else if (!res.destroyed) {
                res.destroy();
            }
        } finally {
            clearTimeout(timer);
        }
    }

    function start() {
        if (server) return;
        server = http.createServer((req, res) => {
            handle(req, res).catch(() => { if (!res.destroyed) res.destroy(); });
        });
        server.headersTimeout = 5000;
        server.keepAliveTimeout = 30000;
        server.once("error", () => { server = undefined; });
        server.listen(port, "127.0.0.1");
    }

    const packaged = /^[a-f0-9]{64}$/.test(token);
    if (packaged) start();
    if (hostModule && hostModule.exports) {
        if (packaged) {
            hostModule.exports.onStart = start;
            hostModule.exports.onRequest = start;
            hostModule.exports.onStop = () => {
                if (server) {
                    server.close();
                    if (server.closeAllConnections) server.closeAllConnections();
                }
                server = undefined;
                httpAgent.destroy();
                httpsAgent.destroy();
                dnsCache.clear();
            };
        } else {
            hostModule.exports = { leagues, games, embeds, playlistIn, webURL, publicAddress, rewrite, sign, slice, eventStart,
                resolve, unpackSegment, unpackSegmentAsync, staleLiveWindow, normalizeLivePlaylist };
        }
    }
})(typeof require === "function" ? require : null, typeof module === "object" ? module : null);
