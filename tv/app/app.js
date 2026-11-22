(() => {
    "use strict";

    const $ = id => document.getElementById(id);
    const settings = window.crackstreamsTV;
    const av = window.webapis && window.webapis.avplay;
    const directory = $("directory");
    const player = $("player");
    const controls = $("playerControls");
    const stop = $("stop");
    const retry = $("retry");
    const sports = $("sports");
    const events = $("events");
    const previewVideo = $("previewVideo");
    const status = $("directoryStatus");
    const playerStatus = $("playerStatus");
    const keys = { 13: "Enter", 37: "ArrowLeft", 38: "ArrowUp", 39: "ArrowRight", 40: "ArrowDown", 10009: "Back" };
    const stallAfter = 12000;
    const maxRefillAfter = 25000;
    const healthyAfter = 45000;
    const maxReconnects = 2;
    let league;
    let listings;
    let playback;
    let hideTimer;
    let startTimer;
    let serviceReady;
    let nativeService;

    function focus(element) {
        if (!element || !element.isConnected || element.closest("[hidden]")) return;
        element.focus({ preventScroll: true });
        element.scrollIntoView({ block: "nearest", inline: "nearest" });
    }

    function buttons(scope) {
        return [...scope.querySelectorAll("button:not([disabled])")].filter(el => !el.closest("[hidden]"));
    }

    async function request(path, signal, value, avoid = []) {
        if (!settings) throw new Error("The TV package is missing its stream service settings.");
        const url = new URL("/api/" + path, settings.origin);
        url.searchParams.set("t", settings.token);
        if (value) url.searchParams.set("url", value);
        for (const feed of avoid) url.searchParams.append("avoid", feed);
        const response = await fetch(url.href, { signal, credentials: "omit" }).catch(error => {
            if (signal.aborted) throw error;
            throw new Error("Can’t reach the TV stream service. Try refreshing the directory.");
        });
        const data = await response.json();
        if (!response.ok) throw new Error(data.error || "The TV stream service couldn’t complete this request.");
        return data;
    }

    function startService() {
        if (!window.tizen) return Promise.resolve();
        if (serviceReady) return serviceReady;
        serviceReady = (async () => {
            const ping = async () => {
                const signal = new AbortController();
                const timer = setTimeout(() => signal.abort(), 1000);
                try { return await request("ping", signal.signal); }
                finally { clearTimeout(timer); }
            };
            try { await ping(); return; } catch (_) {}
            try {
                const { Service } = await import("wrt:service");
                if (!nativeService) nativeService = new Service("CrackTV001.Media");
                // Tizen 10 acknowledges legacy launch calls without actually starting the service.
                Promise.resolve(nativeService.start()).catch(() => {});
            } catch (_) {
                throw new Error("This TV couldn’t launch the built-in stream service.");
            }
            for (let attempt = 0; attempt < 24; attempt += 1) {
                try { await ping(); return; } catch (_) {}
                await new Promise(resolve => setTimeout(resolve, 350));
            }
            throw new Error("The TV stream service didn’t start. Choose Refresh to try again.");
        })().finally(() => { serviceReady = undefined; });
        return serviceReady;
    }

    function loadingList() {
        if (listings) listings.abort();
        listings = new AbortController();
        return listings;
    }

    async function loadSports() {
        const job = loadingList();
        const selected = league && league.url;
        if (sports.contains(document.activeElement) || events.contains(document.activeElement)) focus($("refresh"));
        status.textContent = "Loading sports…";
        sports.replaceChildren();
        events.replaceChildren();
        try {
            await startService();
            if (job.signal.aborted) return;
            const list = await request("leagues", job.signal);
            if (job.signal.aborted) return;
            list.forEach(sport => {
                const button = document.createElement("button");
                button.textContent = sport.name;
                sport.button = button;
                button.addEventListener("click", () => loadGames(sport));
                sports.append(button);
            });
            if (!list.length) {
                league = undefined;
                status.textContent = "No sports are listed right now.";
                return;
            }
            const current = list.find(sport => sport.url === selected) || list[0];
            if (!directory.hidden && document.activeElement === $("refresh")) focus(current.button);
            loadGames(current);
        } catch (error) {
            if (!job.signal.aborted) status.textContent = error.message;
        }
    }

    async function loadGames(sport) {
        const job = loadingList();
        if (league && league.button) league.button.removeAttribute("aria-current");
        league = sport;
        sport.button.setAttribute("aria-current", "true");
        $("eventsTitle").textContent = sport.name;
        status.textContent = "Loading games…";
        if (events.contains(document.activeElement)) focus(sport.button);
        events.replaceChildren();
        try {
            const list = await request("games", job.signal, sport.url);
            if (job.signal.aborted) return;
            status.textContent = list.length ? "" : "No games are listed for this sport.";
            list.forEach(game => {
                const button = document.createElement("button");
                button.className = "event";
                const title = document.createElement("span");
                title.className = "title";
                title.textContent = game.title;
                const detail = document.createElement("span");
                detail.className = "detail";
                const start = game.start && new Date(game.start);
                const live = start && Date.now() >= +start && Date.now() - +start < 4 * 3600000;
                if (live || game.channel) detail.classList.add("live");
                detail.textContent = game.channel ? "24/7" : live ? "LIVE" : start
                    ? start.toLocaleString(undefined, { weekday: "short", hour: "numeric", minute: "2-digit" })
                    : game.detail || "";
                button.append(title, detail);
                button.addEventListener("click", () => watch(game.url, game.title, button));
                events.append(button);
            });
        } catch (error) {
            if (!job.signal.aborted) status.textContent = error.message;
        }
    }

    function showControls() {
        controls.hidden = false;
        clearTimeout(hideTimer);
        if (playback && playback.playing && !playerStatus.textContent) {
            hideTimer = setTimeout(() => { controls.hidden = true; }, 5000);
        }
    }

    function playbackStatus(message) {
        playerStatus.textContent = message;
        showControls();
    }

    function release() {
        clearTimeout(hideTimer);
        clearTimeout(startTimer);
        if (!playback) return;
        const previous = playback;
        playback = undefined;
        clearInterval(previous.clockTimer);
        clearTimeout(previous.reconnectTimer);
        previous.controller.abort();
        if (av) {
            try { if (["PLAYING", "PAUSED", "READY"].includes(av.getState())) av.stop(); } catch (_) {}
            try { if (av.getState() !== "NONE") av.close(); } catch (_) {}
        } else {
            previewVideo.pause();
            previewVideo.removeAttribute("src");
            previewVideo.load();
        }
    }

    function closePlayer() {
        const previous = playback;
        release();
        player.hidden = true;
        directory.hidden = false;
        if (previous) focus(previous.game.trigger);
    }

    function active(job) {
        return playback === job && !job.controller.signal.aborted;
    }

    function interrupted(job, message) {
        if (!active(job)) return;
        const { game } = job;
        release();
        playback = job;
        job.playing = false;
        if (game.started && game.reconnects < maxReconnects) {
            if (job.feed) game.avoid.add(job.feed);
            game.reconnects++;
            playbackStatus("Reconnecting…");
            focus(stop);
            job.reconnectTimer = setTimeout(() => {
                if (playback === job) startAttempt(game);
            }, game.reconnects === 1 ? 0 : 3000);
            return;
        }
        retry.hidden = false;
        playbackStatus(game.started ? "Couldn’t reconnect. Retry or choose another game." : message);
        focus(retry);
    }

    function buffering(job) {
        if (!active(job) || !job.playing) return;
        job.healthySince = undefined;
        job.bufferPercent = undefined;
        if (!playerStatus.textContent) playbackStatus("Buffering…");
    }

    function bufferProgress(job, percent) {
        if (!active(job) || !Number.isFinite(percent)) return;
        if (job.bufferPercent === undefined || percent > job.bufferPercent) {
            job.bufferPercent = percent;
            job.lastBufferAdvance = performance.now();
        }
    }

    function bufferComplete(job) {
        if (!active(job)) return;
        job.bufferPercent = undefined;
        job.lastBufferAdvance = undefined;
        if (!job.playing) return;
        job.lastProgress = performance.now();
        if (playerStatus.textContent === "Buffering…") playbackStatus("");
    }

    function progressed(job, time) {
        if (!active(job) || !Number.isFinite(time)) return;
        if (time <= job.highWater) {
            // Replaying a short loop is not forward progress, but a sustained monotonic run after a PTS reset is.
            if (job.rewindLast !== undefined && time === job.rewindLast) return;
            if (job.rewindLast !== undefined && time > job.rewindLast) {
                job.rewindLast = time;
                if (time - job.rewindBase < 8000) return;
            } else {
                if (time > 0) job.rewindBase = job.rewindLast = time;
                return;
            }
        }
        job.rewindBase = job.rewindLast = undefined;
        job.bufferPercent = job.lastBufferAdvance = undefined;
        job.highWater = time;
        const now = performance.now();
        if (job.healthySince === undefined || now - job.lastProgress >= 4000) job.healthySince = now;
        job.lastProgress = now;
        if (!job.playing) {
            clearTimeout(startTimer);
            job.playing = job.game.started = true;
        }
        if (now - job.healthySince >= healthyAfter) {
            job.game.reconnects = 0;
            job.game.avoid.clear();
        }
        if (playerStatus.textContent) playbackStatus("");
    }

    function watchClock(job, readTime) {
        job.clockTimer = setInterval(() => {
            if (!active(job)) return;
            try { progressed(job, readTime()); } catch (_) {}
            if (!job.playing) return;
            const now = performance.now();
            const idle = now - job.lastProgress;
            const refilling = job.lastBufferAdvance !== undefined
                && now - job.lastBufferAdvance < 6000
                && idle < maxRefillAfter;
            if (idle >= stallAfter && !refilling) interrupted(job, "The feed stopped playing.");
            else if (idle >= 4000) buffering(job);
        }, 1000);
    }

    function watch(url, title, trigger) {
        release();
        directory.hidden = true;
        player.hidden = false;
        $("playerTitle").textContent = title;
        startAttempt({ url, trigger, started: false, reconnects: 0, avoid: new Set() });
    }

    function configureAvPlay() {
        try { av.setBufferingParam("PLAYER_BUFFER_FOR_PLAY", "PLAYER_BUFFER_SIZE_IN_SECOND", 4); } catch (_) {}
        try { av.setBufferingParam("PLAYER_BUFFER_FOR_RESUME", "PLAYER_BUFFER_SIZE_IN_SECOND", 6); } catch (_) {}
        try { av.setTimeoutForBuffering(20); } catch (_) {}
        try { av.setStreamingProperty("ADAPTIVE_INFO", "STARTBITRATE=AVERAGE|FIXED_MAX_RESOLUTION=1920X1080"); } catch (_) {
            try { av.setStreamingProperty("ADAPTIVE_INFO", "STARTBITRATE=AVERAGE"); } catch (_) {}
        }
    }

    async function startAttempt(game) {
        const job = { game, controller: new AbortController(), playing: false, highWater: 0 };
        playback = job;
        retry.hidden = true;
        playbackStatus(game.started ? "Reconnecting…" : "Finding a playable feed…");
        focus(stop);
        startTimer = setTimeout(() => interrupted(job, "Playback took too long to start. Try again."), 45000);
        try {
            await startService();
            if (!active(job)) return;
            const source = await request("play", job.controller.signal, game.url, game.avoid);
            if (!active(job)) return;
            if (!new URL(source.url).href.startsWith(settings.origin + "/")) throw new Error("Invalid playlist URL from the relay.");
            job.feed = source.feed;
            if (!game.started) playbackStatus("Starting playback…");
            if (av) {
                av.open(source.url);
                configureAvPlay();
                av.setDisplayRect(0, 0, 1920, 1080);
                av.setDisplayMethod("PLAYER_DISPLAY_MODE_LETTER_BOX");
                av.setListener({
                    onbufferingstart: () => buffering(job),
                    onbufferingprogress: percent => bufferProgress(job, percent),
                    onbufferingcomplete: () => bufferComplete(job),
                    oncurrentplaytime: time => progressed(job, time),
                    onstreamcompleted: () => interrupted(job, "The stream ended."),
                    onerror: () => interrupted(job, "The TV couldn’t play this feed. Try again or choose another game.")
                });
                watchClock(job, () => av.getState() === "PLAYING" ? av.getCurrentTime() : 0);
                av.prepareAsync(() => {
                    if (!active(job)) return;
                    try { av.play(); } catch (_) { interrupted(job, "The TV couldn’t start this feed."); }
                }, () => interrupted(job, "The TV couldn’t open this feed."));
            } else {
                previewVideo.hidden = false;
                const readTime = () => previewVideo.currentTime * 1000;
                previewVideo.ontimeupdate = () => progressed(job, readTime());
                previewVideo.onerror = () => interrupted(job, "This browser can’t play the feed. Try on the Samsung TV.");
                previewVideo.onwaiting = () => buffering(job);
                previewVideo.onplaying = () => bufferComplete(job);
                previewVideo.onended = () => interrupted(job, "The stream ended.");
                watchClock(job, readTime);
                previewVideo.src = source.url;
                await previewVideo.play();
            }
        } catch (error) {
            interrupted(job, error.message || "Playback failed.");
        }
    }

    function move(key) {
        const active = document.activeElement;
        const scope = player.hidden ? directory : controls;
        const all = buttons(scope);
        if (!all.includes(active)) { focus(all[0]); return; }
        const row = active.closest(".actions");
        const list = active.closest(".list");
        const horizontal = key === "ArrowLeft" || key === "ArrowRight";
        const step = key === "ArrowLeft" || key === "ArrowUp" ? -1 : 1;
        if (row && horizontal) {
            const siblings = buttons(row);
            focus(siblings[siblings.indexOf(active) + step]);
        } else if (scope === directory) {
            if (list && horizontal) {
                if (list === sports && step === 1) focus(buttons(events)[0]);
                if (list === events && step === -1) focus(league && league.button);
            } else if (list) {
                const siblings = buttons(list);
                focus(siblings[siblings.indexOf(active) + step] || (step === -1 ? $("refresh") : null));
            } else if (step === 1) {
                focus((league && league.button) || buttons(sports)[0]);
            }
        }
    }

    $("refresh").addEventListener("click", loadSports);
    stop.addEventListener("click", closePlayer);
    retry.addEventListener("click", () => {
        const { game } = playback;
        watch(game.url, $("playerTitle").textContent, game.trigger);
    });
    document.addEventListener("keydown", event => {
        const key = keys[event.keyCode] || event.key || "";
        if (key === "Back" || key === "Escape" || key === "BrowserBack" || key === "GoBack") {
            event.preventDefault();
            if (!player.hidden) closePlayer();
            else if (window.tizen) window.tizen.application.getCurrentApplication().exit();
            return;
        }
        if (!player.hidden && controls.hidden && (key === "Enter" || key.startsWith("Arrow"))) {
            event.preventDefault();
            showControls();
            focus(stop);
        } else if (key.startsWith("Arrow")) {
            event.preventDefault();
            showControls();
            move(key);
        } else if (key === "Enter" && document.activeElement.tagName === "BUTTON") {
            event.preventDefault();
            if (!event.repeat) document.activeElement.click();
        }
    });
    document.addEventListener("visibilitychange", () => {
        if (document.hidden && playback) closePlayer();
    });
    window.addEventListener("pagehide", release);

    focus($("refresh"));
    loadSports();
})();
