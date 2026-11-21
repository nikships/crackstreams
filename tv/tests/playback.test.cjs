const assert = require("node:assert/strict");
const { readFileSync } = require("node:fs");
const test = require("node:test");
const { runInNewContext } = require("node:vm");

const app = readFileSync(require.resolve("../app/app.js"), "utf8");

async function launch(t, options = {}) {
    t.mock.timers.enable({ apis: ["setTimeout", "setInterval", "Date"], now: 0 });
    const handlers = {};
    const elements = {};
    const document = { getElementById: id => (elements[id] ||= makeElement()), createElement: makeElement,
        addEventListener: (type, fn) => { handlers[type] = fn; } };
    function makeElement() {
        const children = [], events = {};
        return {
            children, isConnected: true, textContent: "", hidden: false, tagName: "BUTTON",
            classList: { add() {} },
            focus() { document.activeElement = this; },
            closest() { return null; }, scrollIntoView() {},
            contains(element) { return children.includes(element); },
            replaceChildren() { children.length = 0; },
            append(...items) { children.push(...items); },
            addEventListener(type, fn) { events[type] = fn; },
            click() { events.click?.(); },
            removeAttribute() {}, setAttribute() {},
        };
    }
    const origin = "http://127.0.0.1:48638";
    const plays = [], listeners = [];
    let tick = 100, state = "NONE";
    const av = {
        open() { state = "IDLE"; }, getState: () => state, getCurrentTime: () => tick,
        setDisplayRect() {}, setDisplayMethod() {},
        setListener(value) { listeners.push(value); },
        prepareAsync(ok) { ok(); },
        play() { state = "PLAYING"; listeners.at(-1).oncurrentplaytime(tick); },
        stop() { state = "IDLE"; },
        close() { state = "NONE"; },
    };
    const fetch = async (address, { signal }) => {
        const url = new URL(address);
        let body;
        if (url.pathname === "/api/leagues") body = [{ name: "NCAA", url: "https://example.org/league/ncaa" }];
        if (url.pathname === "/api/games") body = ["Game one", "Game two"].map(title => ({
            title, url: "https://example.org/stream/" + title.toLowerCase().replace(" ", "-"),
        }));
        if (url.pathname === "/api/play") {
            plays.push({ url, signal });
            if (plays.length > 1 && options.rejectReconnect) return { ok: false, json: async () => ({ error: "Fixture feed unavailable" }) };
            if (plays.length > 1 && options.holdReconnect) return new Promise((_, reject) => {
                signal.addEventListener("abort", () => reject(signal.reason), { once: true });
            });
            body = { url: origin + "/live.m3u8", feed: String(plays.length).padStart(64, "0") };
        }
        return { ok: true, json: async () => body };
    };
    runInNewContext(app, {
        window: { webapis: { avplay: av }, crackstreamsTV: { origin, token: "fixture" }, addEventListener() {} },
        document, fetch, URL, AbortController, setTimeout, clearTimeout, setInterval, clearInterval, Date,
        performance: { now: () => Date.now() },
    });
    const flush = () => new Promise(resolve => setImmediate(resolve));
    await flush();
    elements.events.children[0].click();
    await flush();
    return {
        elements, document, plays, listeners, av,
        message: () => elements.playerStatus.textContent,
        emitTime(value) { tick = value; listeners.at(-1).oncurrentplaytime(value); },
        async advance(ms) { t.mock.timers.tick(ms); await flush(); },
        async back() { handlers.keydown({ keyCode: 10009, preventDefault() {} }); await flush(); },
        async flush() { await flush(); },
    };
}

test("a TV stuck on Buffering re-resolves the same game and plays again", async t => {
    const tv = await launch(t);
    tv.emitTime(32600);
    tv.listeners[0].onbufferingstart();
    assert.equal(tv.message(), "Buffering…");
    await tv.advance(13000);
    assert.equal(tv.plays.length, 2);
    assert.equal(tv.plays[1].url.searchParams.get("url"), tv.plays[0].url.searchParams.get("url"));
    assert.equal(tv.plays[1].url.searchParams.get("avoid"), "1".padStart(64, "0"));
    assert.equal(tv.av.getState(), "PLAYING");
    assert.equal(tv.message(), "");
    tv.listeners[0].onbufferingstart();
    assert.equal(tv.message(), "");
});

test("clock progress clears a short buffer even without a completion callback", async t => {
    const tv = await launch(t);
    tv.emitTime(4000);
    tv.listeners[0].onbufferingstart();
    await tv.advance(6000);
    tv.emitTime(5000);
    assert.equal(tv.message(), "");
    for (let i = 6; i <= 22; i++) {
        tv.emitTime(i * 1000);
        await tv.advance(1000);
    }
    assert.equal(tv.plays.length, 1);
});

test("a repeatedly rewinding clock cannot keep a dead feed alive", async t => {
    const tv = await launch(t);
    tv.emitTime(32600);
    for (let i = 0; i < 13; i++) {
        tv.emitTime(27600 + (i % 5) * 1000);
        await tv.advance(1000);
    }
    assert.equal(tv.plays.length, 2);
});

test("a stable recovery restores the retry budget for a later outage", async t => {
    const tv = await launch(t);
    await tv.advance(13000);
    assert.equal(tv.plays.length, 2);
    for (let i = 1; i <= 46; i++) {
        tv.emitTime(i * 1000);
        await tv.advance(1000);
    }
    await tv.advance(13000);
    assert.equal(tv.plays.length, 3);
    assert.deepEqual(tv.plays[2].url.searchParams.getAll("avoid"), ["2".padStart(64, "0")]);
});

test("recovery stops after two failed attempts and manual Retry starts fresh", async t => {
    const tv = await launch(t, { rejectReconnect: true });
    await tv.advance(13000);
    assert.equal(tv.message(), "Reconnecting…");
    await tv.advance(3100);
    assert.equal(tv.plays.length, 3);
    assert.match(tv.message(), /couldn’t reconnect/i);
    assert.equal(tv.elements.retry.hidden, false);
    assert.equal(tv.document.activeElement, tv.elements.retry);
    await tv.advance(60000);
    assert.equal(tv.plays.length, 3);
    tv.elements.retry.click();
    await tv.flush();
    assert.equal(tv.plays.length, 4);
    assert.equal(tv.plays[3].url.searchParams.has("avoid"), false);
});

test("Back aborts an in-flight reconnect and restores focus to the same game", async t => {
    const tv = await launch(t, { holdReconnect: true });
    await tv.advance(13000);
    assert.equal(tv.plays.length, 2);
    await tv.back();
    assert.equal(tv.plays[1].signal.aborted, true);
    assert.equal(tv.av.getState(), "NONE");
    assert.equal(tv.elements.directory.hidden, false);
    assert.equal(tv.document.activeElement, tv.elements.events.children[0]);
    await tv.advance(70000);
    assert.equal(tv.plays.length, 2);
});
