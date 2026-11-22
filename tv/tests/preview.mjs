// Local browser test server. AVPlay is a test double, not a media decoder.
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";

const origin = "http://127.0.0.1:48634";
const sport = name => ({ name, url: "https://example.org/league/" + name });
const game = title => ({ title, url: "https://example.org/stream/" + title, channel: true });
const app = new URL("../app/", import.meta.url);
const icon = await readFile(new URL("../../Assets/AppIcon.png", import.meta.url));
const testAvPlay = `
window.webapis = {avplay: {
    state: "NONE",
    open(url) { this.fail = url.includes("broken"); this.state = "IDLE"; },
    setDisplayRect() {},
    setDisplayMethod() {},
    setListener(listener) { this.listener = listener; },
    prepareAsync(ok, fail) { this.fail ? fail() : ok(); },
    play() { this.state = "PLAYING"; this.listener.oncurrentplaytime(100); },
    getState() { return this.state; },
    stop() { this.state = "IDLE"; },
    close() { this.state = "NONE"; }
}};
`;

createServer(async (req, res) => {
    const url = new URL(req.url, origin);
    try {
        if (url.pathname === "/") {
            res.setHeader("Content-Type", "text/html");
            const html = await readFile(new URL("index.html", app), "utf8");
            return res.end(html.replaceAll("__RELAY_ORIGIN__", origin));
        }
        if (url.pathname === "/$WEBAPIS/webapis/webapis.js" || url.pathname === "/settings.js") {
            res.setHeader("Content-Type", "application/javascript");
            return res.end(url.pathname === "/settings.js"
                ? `window.crackstreamsTV = {origin: "${origin}", token: "fixture"};` : testAvPlay);
        }
        if (url.pathname === "/icon.png") {
            res.setHeader("Content-Type", "image/png");
            return res.end(icon);
        }
        if (url.pathname === "/styles.css" || url.pathname === "/app.js") {
            res.setHeader("Content-Type", url.pathname.endsWith(".css") ? "text/css" : "application/javascript");
            return res.end(await readFile(new URL(url.pathname.slice(1), app)));
        }
        res.setHeader("Content-Type", "application/json");
        const source = url.searchParams.get("url") || "";
        if (url.pathname === "/api/leagues") return res.end(JSON.stringify([sport("Basketball"), sport("Hockey"), sport("Racing")]));
        if (url.pathname === "/api/games") {
            if (source.endsWith("Hockey")) return res.end(JSON.stringify([game("Rangers vs Bruins")]));
            if (source.endsWith("Racing")) return res.end("[]");
            return res.end(JSON.stringify([game("Lakers vs Celtics"), game("Feed unavailable")]));
        }
        if (url.pathname === "/api/play") {
            const path = source.includes("unavailable") ? "/broken.m3u8" : "/ok.m3u8";
            return res.end(JSON.stringify({ url: origin + path }));
        }
        res.statusCode = 404;
        return res.end();
    } catch (error) {
        res.statusCode = 500;
        res.end(String(error));
    }
}).listen(48634, "127.0.0.1", () => console.log("Browser preview: " + origin));
