(() => {
  'use strict';

  const BOOT = window.__CS_BOOT__ || { token: '', homeHost: 'crackstreams.mx', os: 'windows', hasShortcuts: false };

  // Strip launch token from URL bar while preserving session auth.
  if (window.location.search.includes('t=')) {
    window.history.replaceState(null, '', '/');
  }

  const MAX_STREAMS = 4;
  const IDLE_HIDE_MS = 2400;

  // Store state mirroring StreamStore.swift invariants
  const state = {
    slots: Array.from({ length: MAX_STREAMS }, (_, index) => ({
      index,
      state: 'idle', // 'idle' | 'resolving' | 'playing' | 'failed'
      title: 'Empty slot',
      preferredTitle: null,
      sourceUrl: null,
      playlistUrl: null,
      embedIndex: 0,
      embedCount: 1,
      isBuffering: false,
      isMuted: index > 0,
      volume: 1.0,
      error: '',
      generation: 0,
      abortCtrl: null,
      hls: null,
      hovered: false,
      dropTarget: false,
    })),
    input: '',
    message: null,
    messageKind: 'warn', // 'warn' | 'ok'
    focusedIndex: null,
    isWindowFullscreen: false,
    didEnterFullscreenForPane: false,
    isPaletteOpen: false,
    isPointerIdle: false,
    isPointerOverChrome: false,

    // Directory state
    dirOpen: false,
    dirTargetSlot: null, // null = next empty pane, or 0..3
    leagues: [],
    loadingLeagues: false,
    leaguesError: null,
    selectedLeagueId: null,
    events: [],
    loadingEvents: false,
    eventsError: null,
    eventsWarning: '',
    dirFilter: '',
    selectedEventId: null,
    eventsRequestSeq: 0,
  };

  let idleTimer = null;
  let bannerTimer = null;

  // DOM Elements
  const el = {
    app: document.getElementById('app'),
    launchHeader: document.getElementById('launchHeader'),
    launchFooter: document.getElementById('launchFooter'),
    pinShortcutBtn: document.getElementById('pinShortcutBtn'),
    launchBrowseBtn: document.getElementById('launchBrowseBtn'),
    launchUrlForm: document.getElementById('launchUrlForm'),
    launchUrlInput: document.getElementById('launchUrlInput'),
    launchClearBtn: document.getElementById('launchClearBtn'),
    launchPasteBtn: document.getElementById('launchPasteBtn'),
    launchPlayBtn: document.getElementById('launchPlayBtn'),
    launchHints: document.getElementById('launchHints'),
    launchWarning: document.getElementById('launchWarning'),
    launchWarningText: document.getElementById('launchWarningText'),
    launchWarningDismiss: document.getElementById('launchWarningDismiss'),
    gridStage: document.getElementById('gridStage'),
    immersiveBanner: document.getElementById('immersiveBanner'),
    immersiveBannerIcon: document.getElementById('immersiveBannerIcon'),
    immersiveBannerText: document.getElementById('immersiveBannerText'),
    immersiveBannerDismiss: document.getElementById('immersiveBannerDismiss'),
    multiviewDock: document.getElementById('multiviewDock'),
    dockGridBtn: document.getElementById('dockGridBtn'),
    dockChips: document.getElementById('dockChips'),
    dockAddBtn: document.getElementById('dockAddBtn'),
    dockBrowseBtn: document.getElementById('dockBrowseBtn'),
    paletteBackdrop: document.getElementById('paletteBackdrop'),
    paletteUrlForm: document.getElementById('paletteUrlForm'),
    paletteUrlInput: document.getElementById('paletteUrlInput'),
    paletteClearBtn: document.getElementById('paletteClearBtn'),
    palettePlayBtn: document.getElementById('palettePlayBtn'),
    paletteDestDot: document.getElementById('paletteDestDot'),
    paletteDestText: document.getElementById('paletteDestText'),
    palettePasteBtn: document.getElementById('palettePasteBtn'),
    paletteBrowseBtn: document.getElementById('paletteBrowseBtn'),
    paletteError: document.getElementById('paletteError'),
    directoryBackdrop: document.getElementById('directoryBackdrop'),
    dirLiveCount: document.getElementById('dirLiveCount'),
    dirHostLabel: document.getElementById('dirHostLabel'),
    dirDestBadge: document.getElementById('dirDestBadge'),
    dirFilterInput: document.getElementById('dirFilterInput'),
    dirFilterClear: document.getElementById('dirFilterClear'),
    dirRefreshBtn: document.getElementById('dirRefreshBtn'),
    dirCloseBtn: document.getElementById('dirCloseBtn'),
    dirSidebar: document.getElementById('dirSidebar'),
    dirEventsPane: document.getElementById('dirEventsPane'),
    dirFooterStatus: document.getElementById('dirFooterStatus'),
  };

  // Persistent Tile DOM nodes so <video> elements are never recreated on UI state updates!
  const tileDom = [];

  function apiFetch(path, options = {}) {
    const headers = Object.assign(
      { 'X-Crackstreams-Token': BOOT.token },
      options.headers || {}
    );
    return fetch(path, Object.assign({}, options, { headers }));
  }

  function validStreamUrl(raw) {
    if (!raw || typeof raw !== 'string') return null;
    const text = raw.trim();
    if (!text) return null;
    try {
      const u = new URL(text);
      const scheme = u.protocol.toLowerCase();
      if ((scheme !== 'http:' && scheme !== 'https:') || !u.hostname || u.username || u.password) {
        return null;
      }
      return u.toString();
    } catch {
      return null;
    }
  }

  function prettyTitleFromUrl(urlStr) {
    try {
      const u = new URL(urlStr);
      const parts = u.pathname.replace(/\/+$/, '').split('/').filter(Boolean);
      let slug = parts.length ? parts[parts.length - 1] : '';
      slug = slug.replace(/\.[a-z0-9]+$/i, '');
      const words = slug.split(/[-_]+/).filter(Boolean).map((w) => {
        if (w.toLowerCase() === 'vs') return 'vs';
        return w.charAt(0).toUpperCase() + w.slice(1);
      });
      return words.length ? words.join(' ') : (u.hostname || 'Stream');
    } catch {
      return 'Stream';
    }
  }

  function isImmersive() {
    return state.slots.some((s) => s.state !== 'idle');
  }

  function activeCount() {
    return state.slots.filter((s) => s.state !== 'idle').length;
  }

  function nextEmptyIndex() {
    const idx = state.slots.findIndex((s) => s.state === 'idle');
    return idx === -1 ? null : idx;
  }

  function setMessage(msg, kind = 'warn') {
    state.message = msg;
    state.messageKind = kind;
    clearTimeout(bannerTimer);
    if (msg) {
      bannerTimer = setTimeout(() => {
        if (state.message === msg) {
          state.message = null;
          renderShell();
        }
      }, 6000);
    }
    renderShell();
  }

  // Build persistent tile DOM elements once
  function initGridDom() {
    el.gridStage.innerHTML = '';
    for (let i = 0; i < MAX_STREAMS; i++) {
      const root = document.createElement('section');
      root.className = 'stream-tile state-idle';
      root.tabIndex = 0;
      root.dataset.index = String(i);

      root.innerHTML = `
        <video class="tile-video hidden" playsinline></video>

        <div class="tile-slot-badge">
          <span class="slot-num">${i + 1}</span>
          <span class="slot-next hidden">NEXT</span>
        </div>

        <div class="tile-idle">
          <div class="idle-plus-ring">+</div>
          <div>
            <div class="idle-title">Empty pane</div>
            <div class="idle-sub">Pick a live game, paste a link, or drop one here</div>
          </div>
          <div class="tile-pill-row">
            <button type="button" class="pill-btn accent js-tile-browse">
              <span class="live-dot small"></span>
              <span>Live games</span>
            </button>
            <button type="button" class="pill-btn js-tile-paste">Paste link</button>
          </div>
        </div>

        <div class="tile-state-box js-resolving hidden">
          <div class="spinner-ring"></div>
          <div>
            <div class="state-title js-resolving-title"></div>
            <div class="state-detail">Finding the live feed…</div>
          </div>
          <button type="button" class="pill-btn js-cancel">Cancel</button>
        </div>

        <div class="tile-state-box js-failed hidden">
          <div class="warn-circle">⚠</div>
          <div>
            <div class="state-title">Couldn’t play this stream</div>
            <div class="state-detail js-failed-msg"></div>
          </div>
          <div class="tile-pill-row">
            <button type="button" class="pill-btn accent js-retry">Try again</button>
            <button type="button" class="pill-btn js-fail-browse">Live games</button>
            <button type="button" class="pill-btn js-fail-close">Close</button>
          </div>
        </div>

        <div class="tile-topbar">
          <div class="tile-title-pill">
            <span class="status-dot js-status-dot"></span>
            <span class="tile-title-text js-bar-title"></span>
            <span class="feed-count-tag js-feed-tag hidden"></span>
          </div>
          <div class="tile-actions-pill">
            <button type="button" class="pane-icon-btn js-audio-btn" title="Toggle audio"></button>
            <input type="range" class="volume-slider js-vol-slider" min="0" max="1" step="0.02" value="1" aria-label="Volume" />
            <div class="pane-sep"></div>
            <button type="button" class="pane-icon-btn js-switch-feed hidden" title="Try next backup feed">
              <svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">
                <path d="M2.5 5.5h10l-2.2-2.2M13.5 10.5h-10l2.2 2.2"/>
              </svg>
            </button>
            <button type="button" class="pane-icon-btn js-replace-btn" title="Replace with another live game">
              <svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round">
                <path d="M2.5 4h11M2.5 8h11M2.5 12h7"/>
              </svg>
            </button>
            <button type="button" class="pane-icon-btn js-focus-btn" title="Expand pane"></button>
            <button type="button" class="pane-icon-btn js-fs-btn" title="Full screen"></button>
            <button type="button" class="pane-icon-btn js-close-btn" title="Close stream">
              <svg viewBox="0 0 16 16" width="12" height="12" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round">
                <path d="M4 4l8 8M12 4l-8 8"/>
              </svg>
            </button>
          </div>
        </div>

        <div class="tile-buffering-pill js-buffering hidden">
          <span class="mini-spinner"></span>
          <span>Buffering…</span>
        </div>

        <div class="tile-drop-overlay js-drop-overlay hidden">
          <div class="drop-card js-drop-label">Drop stream link here</div>
        </div>
      `;

      const dom = {
        root,
        video: root.querySelector('.tile-video'),
        slotBadge: root.querySelector('.tile-slot-badge'),
        slotNext: root.querySelector('.slot-next'),
        idleBox: root.querySelector('.tile-idle'),
        idleTitle: root.querySelector('.idle-title'),
        resolvingBox: root.querySelector('.js-resolving'),
        resolvingTitle: root.querySelector('.js-resolving-title'),
        failedBox: root.querySelector('.js-failed'),
        failedMsg: root.querySelector('.js-failed-msg'),
        topbar: root.querySelector('.tile-topbar'),
        statusDot: root.querySelector('.js-status-dot'),
        barTitle: root.querySelector('.js-bar-title'),
        feedTag: root.querySelector('.js-feed-tag'),
        audioBtn: root.querySelector('.js-audio-btn'),
        volSlider: root.querySelector('.js-vol-slider'),
        switchFeedBtn: root.querySelector('.js-switch-feed'),
        replaceBtn: root.querySelector('.js-replace-btn'),
        focusBtn: root.querySelector('.js-focus-btn'),
        fsBtn: root.querySelector('.js-fs-btn'),
        closeBtn: root.querySelector('.js-close-btn'),
        bufferingPill: root.querySelector('.js-buffering'),
        dropOverlay: root.querySelector('.js-drop-overlay'),
        dropLabel: root.querySelector('.js-drop-label'),
      };

      // Wire events
      root.addEventListener('mouseenter', () => {
        state.slots[i].hovered = true;
        wakePointer();
        renderTile(i);
      });
      root.addEventListener('mousemove', () => {
        if (!state.slots[i].hovered) {
          state.slots[i].hovered = true;
          renderTile(i);
        }
        wakePointer();
      });
      root.addEventListener('mouseleave', () => {
        state.slots[i].hovered = false;
        renderTile(i);
      });

      dom.topbar.addEventListener('mouseenter', () => { state.isPointerOverChrome = true; });
      dom.topbar.addEventListener('mouseleave', () => { state.isPointerOverChrome = false; });

      dom.video.addEventListener('dblclick', (e) => {
        e.preventDefault();
        togglePaneFullscreen(i);
      });

      root.querySelector('.js-tile-browse').addEventListener('click', () => openDirectory(i));
      root.querySelector('.js-tile-paste').addEventListener('click', () => pasteIntoSlot(i));
      root.querySelector('.js-cancel').addEventListener('click', () => closeSlot(i));
      root.querySelector('.js-retry').addEventListener('click', () => retrySlot(i));
      root.querySelector('.js-fail-browse').addEventListener('click', () => openDirectory(i));
      root.querySelector('.js-fail-close').addEventListener('click', () => closeSlot(i));

      dom.audioBtn.addEventListener('click', (e) => {
        toggleAudio(i, e.altKey || e.shiftKey);
      });
      dom.volSlider.addEventListener('input', (e) => {
        setSlotVolume(i, parseFloat(e.target.value));
      });
      dom.switchFeedBtn.addEventListener('click', () => switchBackupFeed(i));
      dom.replaceBtn.addEventListener('click', () => openDirectory(i));
      dom.focusBtn.addEventListener('click', () => toggleFocus(i));
      dom.fsBtn.addEventListener('click', () => togglePaneFullscreen(i));
      dom.closeBtn.addEventListener('click', () => closeSlot(i));

      // Drag and drop per pane
      root.addEventListener('dragover', (e) => {
        e.preventDefault();
        e.stopPropagation();
        if (!state.slots[i].dropTarget) {
          state.slots[i].dropTarget = true;
          renderTile(i);
        }
      });
      root.addEventListener('dragleave', (e) => {
        if (!root.contains(e.relatedTarget)) {
          state.slots[i].dropTarget = false;
          renderTile(i);
        }
      });
      root.addEventListener('drop', (e) => {
        e.preventDefault();
        e.stopPropagation();
        state.slots[i].dropTarget = false;
        const dropped = extractDroppedText(e.dataTransfer);
        handleDroppedUrl(dropped, i);
      });

      el.gridStage.appendChild(root);
      tileDom.push(dom);
    }
  }

  function extractDroppedText(dt) {
    if (!dt) return '';
    return dt.getData('text/uri-list') || dt.getData('text/plain') || '';
  }

  function handleDroppedUrl(raw, targetIndex = null) {
    const firstLine = (raw || '').split(/\r?\n/).find((l) => l && !l.startsWith('#')) || raw;
    const valid = validStreamUrl(firstLine);
    if (!valid) {
      setMessage('The dropped text is not a valid http:// or https:// stream URL.');
      return;
    }
    addStream(valid, null, targetIndex);
  }

  // Stream Lifecycle & Generation Guards (matching StreamStore.swift)
  function addFromInput() {
    const trimmed = state.input.trim();
    if (!trimmed) return false;
    const valid = validStreamUrl(trimmed);
    if (!valid) {
      setMessage('Enter a valid http:// or https:// stream URL.');
      return false;
    }
    if (!addStream(valid, null, null)) {
      return false;
    }
    state.input = '';
    syncInputs();
    return true;
  }

  function addStream(urlStr, preferredTitle = null, targetIndex = null) {
    const valid = validStreamUrl(urlStr);
    if (!valid) {
      setMessage('Only http:// and https:// stream URLs are supported.');
      return false;
    }
    state.message = null;

    let idx = targetIndex;
    if (idx !== null && idx !== undefined) {
      const slot = state.slots[idx];
      if (slot.state === 'idle') {
        slot.isMuted = state.slots.some((s, j) => j !== idx && s.state !== 'idle');
      }
      loadSlot(idx, valid, preferredTitle, 0);
      return true;
    }

    const emptyIdx = nextEmptyIndex();
    if (emptyIdx === null) {
      setMessage('All four panes are in use. Close one or drop the link onto a pane to replace it.');
      return false;
    }
    state.slots[emptyIdx].isMuted = state.slots.some((s) => s.state !== 'idle');
    loadSlot(emptyIdx, valid, preferredTitle, 0);
    return true;
  }

  async function loadSlot(index, urlStr, preferredTitle = null, embedOffset = 0) {
    const slot = state.slots[index];
    teardownPlayer(index);

    slot.generation += 1;
    const gen = slot.generation;
    const abortCtrl = new AbortController();
    slot.abortCtrl = abortCtrl;
    slot.sourceUrl = urlStr;
    slot.preferredTitle = preferredTitle;
    slot.title = preferredTitle || prettyTitleFromUrl(urlStr);
    slot.state = 'resolving';
    slot.error = '';
    slot.isBuffering = false;

    renderAll();

    try {
      const resp = await apiFetch('/api/resolve', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ url: urlStr, offset: embedOffset }),
        signal: abortCtrl.signal,
      });

      if (slot.generation !== gen) return;
      const data = await resp.json().catch(() => ({}));
      if (slot.generation !== gen) return;

      if (!resp.ok || !data.playlistUrl) {
        failSlot(index, gen, data.error || 'The stream could not be resolved.');
        return;
      }

      slot.abortCtrl = null;
      slot.playlistUrl = data.playlistUrl;
      slot.embedIndex = data.embedIndex || 0;
      slot.embedCount = data.embedCount || 1;
      slot.title = slot.preferredTitle || data.title || slot.title;
      slot.isBuffering = true;
      slot.state = 'playing';

      attachVideoPlayer(index, gen, data.playlistUrl);
      renderAll();
    } catch (err) {
      if (err && err.name === 'AbortError') return;
      if (slot.generation !== gen) return;
      failSlot(index, gen, 'Could not connect to resolve the stream.');
    }
  }

  function attachVideoPlayer(index, gen, playlistUrl) {
    const slot = state.slots[index];
    const dom = tileDom[index];
    const video = dom.video;

    video.muted = slot.isMuted;
    video.volume = slot.volume;

    const onPlaying = () => {
      if (slot.generation !== gen) return;
      slot.isBuffering = false;
      renderTile(index);
    };
    const onWaiting = () => {
      if (slot.generation !== gen) return;
      slot.isBuffering = true;
      renderTile(index);
    };
    const onEnded = () => {
      if (slot.generation !== gen) return;
      failSlot(index, gen, 'This live stream ended.');
    };

    video._csCleanup = () => {
      video.removeEventListener('playing', onPlaying);
      video.removeEventListener('timeupdate', onPlaying);
      video.removeEventListener('waiting', onWaiting);
      video.removeEventListener('stalled', onWaiting);
      video.removeEventListener('ended', onEnded);
    };

    video.addEventListener('playing', onPlaying);
    video.addEventListener('timeupdate', onPlaying);
    video.addEventListener('waiting', onWaiting);
    video.addEventListener('stalled', onWaiting);
    video.addEventListener('ended', onEnded);

    const startPlayback = () => {
      if (slot.generation !== gen) return;
      const p = video.play();
      if (p && typeof p.catch === 'function') {
        p.catch(() => {
          if (slot.generation !== gen) return;
          // If browser policy blocked unmuted autoplay (e.g. external browser fallback), play muted rather than stalling.
          if (!slot.isMuted) {
            slot.isMuted = true;
            video.muted = true;
            video.play().catch(() => {});
            setMessage('Started muted by browser policy — click speaker to unmute.');
            renderAll();
          }
        });
      }
    };

    if (window.Hls && window.Hls.isSupported()) {
      const hls = new window.Hls({
        enableWorker: true,
        lowLatencyMode: false,
        backBufferLength: 30,
        maxBufferLength: 22,
        maxMaxBufferLength: 45,
        manifestLoadingMaxRetry: 4,
        levelLoadingMaxRetry: 4,
        fragLoadingMaxRetry: 5,
      });
      slot.hls = hls;

      let mediaRecoveryAttempts = 0;

      hls.on(window.Hls.Events.MANIFEST_PARSED, () => {
        if (slot.generation !== gen) return;
        startPlayback();
      });

      hls.on(window.Hls.Events.ERROR, (_event, data) => {
        if (slot.generation !== gen || !data.fatal) return;
        if (data.type === window.Hls.ErrorTypes.NETWORK_ERROR) {
          slot.isBuffering = true;
          renderTile(index);
          hls.startLoad();
        } else if (data.type === window.Hls.ErrorTypes.MEDIA_ERROR && mediaRecoveryAttempts < 2) {
          mediaRecoveryAttempts += 1;
          hls.recoverMediaError();
        } else {
          failSlot(index, gen, 'The live video feed was interrupted or is offline.');
        }
      });

      hls.loadSource(playlistUrl);
      hls.attachMedia(video);
    } else if (video.canPlayType('application/vnd.apple.mpegurl')) {
      video.src = playlistUrl;
      video.addEventListener('loadedmetadata', startPlayback, { once: true });
      video.addEventListener('error', () => {
        failSlot(index, gen, 'The live feed could not be opened.');
      }, { once: true });
    } else {
      failSlot(index, gen, 'HLS playback is not supported in this runtime.');
    }
  }

  function failSlot(index, gen, message) {
    const slot = state.slots[index];
    if (slot.generation !== gen) return;
    teardownPlayer(index);
    slot.state = 'failed';
    slot.error = message;
    renderAll();
  }

  function teardownPlayer(index) {
    const slot = state.slots[index];
    if (slot.abortCtrl) {
      slot.abortCtrl.abort();
      slot.abortCtrl = null;
    }
    const video = tileDom[index].video;
    if (video._csCleanup) {
      video._csCleanup();
      video._csCleanup = null;
    }
    if (slot.hls) {
      try { slot.hls.destroy(); } catch {}
      slot.hls = null;
    }
    try {
      video.pause();
      video.removeAttribute('src');
      video.load();
    } catch {}
    slot.isBuffering = false;
    slot.playlistUrl = null;
  }

  function retrySlot(index) {
    const slot = state.slots[index];
    if (!slot.sourceUrl) return;
    loadSlot(index, slot.sourceUrl, slot.preferredTitle, slot.embedIndex || 0);
  }

  function switchBackupFeed(index) {
    const slot = state.slots[index];
    if (!slot.sourceUrl || slot.embedCount <= 1) return;
    const nextOffset = ((slot.embedIndex || 0) + 1) % slot.embedCount;
    loadSlot(index, slot.sourceUrl, slot.preferredTitle, nextOffset);
  }

  function closeSlot(index) {
    const slot = state.slots[index];
    slot.generation += 1;
    teardownPlayer(index);
    slot.state = 'idle';
    slot.title = 'Empty slot';
    slot.preferredTitle = null;
    slot.sourceUrl = null;
    slot.embedIndex = 0;
    slot.embedCount = 1;
    slot.error = '';

    if (state.focusedIndex === index) {
      state.focusedIndex = null;
      exitPaneFullscreenIfNeeded();
    }
    renderAll();
  }

  function toggleFocus(index) {
    if (state.focusedIndex === index) {
      state.focusedIndex = null;
      exitPaneFullscreenIfNeeded();
    } else {
      state.focusedIndex = index;
    }
    renderAll();
  }

  function soloAudio(targetIndex) {
    state.slots.forEach((slot, i) => {
      if (slot.state !== 'idle') {
        slot.isMuted = i !== targetIndex;
        tileDom[i].video.muted = slot.isMuted;
      }
    });
    renderAll();
  }

  function toggleAudio(targetIndex, mixing = false) {
    const target = state.slots[targetIndex];
    if (!target.isMuted) {
      target.isMuted = true;
      tileDom[targetIndex].video.muted = true;
      renderAll();
    } else if (mixing) {
      target.isMuted = false;
      tileDom[targetIndex].video.muted = false;
      renderAll();
    } else {
      soloAudio(targetIndex);
    }
  }

  function setSlotVolume(index, vol) {
    const clamped = Math.max(0, Math.min(1, vol));
    state.slots[index].volume = clamped;
    tileDom[index].video.volume = clamped;
  }

  async function requestWindowFullscreen(mode) {
    try {
      const resp = await apiFetch('/api/window/fullscreen', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ mode }),
      });
      if (resp.ok) {
        const data = await resp.json();
        if (data.native && typeof data.fullscreen === 'boolean') {
          state.isWindowFullscreen = data.fullscreen;
          if (!state.isWindowFullscreen && document.fullscreenElement) {
            document.exitFullscreen().catch(() => {});
          }
          renderAll();
          return;
        }
      }
    } catch {}

    // Standard browser fullscreen fallback (for macOS dev browser or Edge --app fallback)
    if (mode === 'exit') {
      if (document.fullscreenElement) await document.exitFullscreen().catch(() => {});
      state.isWindowFullscreen = false;
    } else if (mode === 'enter') {
      if (!document.fullscreenElement) await document.documentElement.requestFullscreen().catch(() => {});
      state.isWindowFullscreen = Boolean(document.fullscreenElement);
    } else {
      if (document.fullscreenElement) {
        await document.exitFullscreen().catch(() => {});
      } else {
        await document.documentElement.requestFullscreen().catch(() => {});
      }
      state.isWindowFullscreen = Boolean(document.fullscreenElement);
    }
    renderAll();
  }

  function togglePaneFullscreen(index) {
    const isPaneFull = state.focusedIndex === index && state.isWindowFullscreen;
    if (isPaneFull) {
      state.didEnterFullscreenForPane = true;
      state.focusedIndex = null;
      exitPaneFullscreenIfNeeded();
      renderAll();
      return;
    }
    state.focusedIndex = index;
    state.didEnterFullscreenForPane = true;
    renderAll();
    if (!state.isWindowFullscreen) {
      requestWindowFullscreen('enter');
    }
  }

  function exitPaneFullscreenIfNeeded() {
    if (state.didEnterFullscreenForPane && state.isWindowFullscreen) {
      requestWindowFullscreen('exit');
    }
    state.didEnterFullscreenForPane = false;
  }

  // Clipboard helpers
  async function readClipboardText() {
    try {
      const text = await navigator.clipboard.readText();
      return (text || '').trim();
    } catch {
      return '';
    }
  }

  async function pasteIntoField(targetInput) {
    const text = await readClipboardText();
    if (!text) {
      setMessage('The clipboard is empty.');
      return;
    }
    state.input = text;
    syncInputs();
    targetInput.focus();
  }

  async function pasteIntoSlot(index) {
    const text = await readClipboardText();
    const valid = validStreamUrl(text);
    if (!valid) {
      setMessage('The clipboard does not contain a valid stream URL.');
      return;
    }
    addStream(valid, null, index);
  }

  // Palette controls
  function showPalette() {
    if (!isImmersive()) {
      el.launchUrlInput.focus();
      el.launchUrlInput.select();
      return;
    }
    state.isPaletteOpen = true;
    wakePointer();
    renderShell();
    requestAnimationFrame(() => {
      el.paletteUrlInput.focus();
      el.paletteUrlInput.select();
    });
  }

  function hidePalette() {
    state.isPaletteOpen = false;
    renderShell();
  }

  // Directory Modal Logic
  function openDirectory(targetSlot = null) {
    hidePalette();
    state.dirTargetSlot = targetSlot;
    state.dirOpen = true;
    wakePointer();
    renderDirectory();

    if (state.leagues.length === 0) {
      loadLeagues(false);
    } else if (state.selectedLeagueId) {
      loadEvents(state.selectedLeagueId, false);
    }
    requestAnimationFrame(() => el.dirFilterInput.focus());
  }

  function closeDirectory() {
    state.dirOpen = false;
    renderShell();
  }

  async function loadLeagues(force = false) {
    state.loadingLeagues = true;
    state.leaguesError = null;
    renderDirectory();

    try {
      const resp = await apiFetch(`/api/leagues?force=${force ? '1' : '0'}`);
      const data = await resp.json().catch(() => ({}));
      if (!resp.ok) {
        state.loadingLeagues = false;
        state.leaguesError = data.error || 'Could not load sports.';
        renderDirectory();
        return;
      }
      state.leagues = data.leagues || [];
      if (data.homeHost) BOOT.homeHost = data.homeHost;
      state.loadingLeagues = false;

      if (state.selectedLeagueId && state.leagues.some((l) => l.id === state.selectedLeagueId)) {
        loadEvents(state.selectedLeagueId, force);
      } else if (state.leagues.length > 0) {
        selectLeague(state.leagues[0].id);
      } else {
        renderDirectory();
      }
    } catch {
      state.loadingLeagues = false;
      state.leaguesError = 'Could not reach local directory service.';
      renderDirectory();
    }
  }

  function selectLeague(leagueId) {
    if (state.selectedLeagueId === leagueId && state.events.length > 0) return;
    state.selectedLeagueId = leagueId;
    state.selectedEventId = null;
    state.events = [];
    state.eventsError = null;
    state.eventsWarning = '';
    loadEvents(leagueId, false);
  }

  async function loadEvents(leagueId, force = false) {
    const seq = ++state.eventsRequestSeq;
    state.loadingEvents = true;
    state.eventsError = null;
    if (!force) state.eventsWarning = '';
    renderDirectory();

    try {
      const resp = await apiFetch(`/api/events?league=${encodeURIComponent(leagueId)}&force=${force ? '1' : '0'}`);
      const data = await resp.json().catch(() => ({}));
      // Drop stale responses if user already switched to another sport
      if (seq !== state.eventsRequestSeq || state.selectedLeagueId !== leagueId) return;

      state.loadingEvents = false;
      if (!resp.ok) {
        state.eventsError = data.error || 'Could not load games.';
        renderDirectory();
        return;
      }
      state.events = data.events || [];
      state.eventsWarning = data.warning || '';
      renderDirectory();
    } catch {
      if (seq !== state.eventsRequestSeq || state.selectedLeagueId !== leagueId) return;
      state.loadingEvents = false;
      state.eventsError = 'Network error while loading games.';
      renderDirectory();
    }
  }

  function watchEvent(ev) {
    const ok = addStream(ev.url, ev.title, state.dirTargetSlot);
    if (ok) {
      closeDirectory();
    } else {
      renderDirectory();
    }
  }

  // Rendering
  function syncInputs() {
    if (el.launchUrlInput.value !== state.input) el.launchUrlInput.value = state.input;
    if (el.paletteUrlInput.value !== state.input) el.paletteUrlInput.value = state.input;
    const hasText = state.input.trim().length > 0;
    el.launchClearBtn.classList.toggle('hidden', !hasText);
    el.paletteClearBtn.classList.toggle('hidden', !hasText);
    el.launchPlayBtn.disabled = !hasText;
    el.palettePlayBtn.disabled = !hasText;
  }

  function svgIcon(name) {
    switch (name) {
      case 'speaker-on':
        return `<svg viewBox="0 0 16 16" width="13" height="13" fill="currentColor"><path d="M7.6 3.2L4.3 5.8H2.2a.7.7 0 0 0-.7.7v3c0 .4.3.7.7.7h2.1l3.3 2.6c.45.35 1.1.03 1.1-.55V3.75c0-.58-.65-.9-1.1-.55zm3.2 2.1a.65.65 0 0 1 .92 0 3.9 3.9 0 0 1 0 5.4.65.65 0 1 1-.92-.92 2.6 2.6 0 0 0 0-3.56.65.65 0 0 1 0-.92zm1.9-1.8a.65.65 0 0 1 .92 0 6.4 6.4 0 0 1 0 9 .65.65 0 0 1-.92-.92 5.1 5.1 0 0 0 0-7.16.65.65 0 0 1 0-.92z"/></svg>`;
      case 'speaker-off':
        return `<svg viewBox="0 0 16 16" width="13" height="13" fill="currentColor"><path d="M7.6 3.2L4.3 5.8H2.2a.7.7 0 0 0-.7.7v3c0 .4.3.7.7.7h2.1l3.3 2.6c.45.35 1.1.03 1.1-.55V3.75c0-.58-.65-.9-1.1-.55zm3.35 3.15l1.3 1.3 1.3-1.3a.65.65 0 1 1 .92.92L13.17 8.6l1.3 1.3a.65.65 0 1 1-.92.92l-1.3-1.3-1.3 1.3a.65.65 0 0 1-.92-.92l1.3-1.3-1.3-1.3a.65.65 0 0 1 .92-.92z"/></svg>`;
      case 'expand':
        return `<svg viewBox="0 0 16 16" width="12" height="12" fill="none" stroke="currentColor" stroke-width="1.6"><rect x="2.2" y="2.8" width="11.6" height="10.4" rx="1.8"/><rect x="4.5" y="5" width="7" height="6" rx="0.8" fill="currentColor" stroke="none"/></svg>`;
      case 'grid':
        return `<svg viewBox="0 0 16 16" width="12" height="12" fill="currentColor"><rect x="2" y="2" width="5" height="5" rx="1"/><rect x="9" y="2" width="5" height="5" rx="1"/><rect x="2" y="9" width="5" height="5" rx="1"/><rect x="9" y="9" width="5" height="5" rx="1"/></svg>`;
      case 'fs-enter':
        return `<svg viewBox="0 0 16 16" width="12" height="12" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M2.5 6V2.5H6M10 2.5h3.5V6M13.5 10v3.5H10M6 13.5H2.5V10"/></svg>`;
      case 'fs-exit':
        return `<svg viewBox="0 0 16 16" width="12" height="12" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"><path d="M6 2.5V6H2.5M10 2.5V6h3.5M10 13.5V10h3.5M6 13.5V10H2.5"/></svg>`;
      default:
        return '';
    }
  }

  function renderTile(i) {
    const slot = state.slots[i];
    const dom = tileDom[i];
    const immersive = isImmersive();
    const isFocused = state.focusedIndex === i;
    const visible = state.focusedIndex === null || isFocused;
    const nextIdx = nextEmptyIndex();
    const isNext = nextIdx === i;

    dom.root.classList.toggle('hidden', !visible);
    dom.root.classList.toggle('state-idle', slot.state === 'idle');
    dom.root.classList.toggle('state-resolving', slot.state === 'resolving');
    dom.root.classList.toggle('state-playing', slot.state === 'playing');
    dom.root.classList.toggle('state-failed', slot.state === 'failed');
    dom.root.classList.toggle('is-next-target', isNext && !immersive);
    dom.root.classList.toggle('drop-active', slot.dropTarget);

    const chromeSuppressed = state.isPaletteOpen || state.dirOpen;
    const showControls = slot.state !== 'idle' && !chromeSuppressed && slot.hovered && !state.isPointerIdle;
    dom.root.classList.toggle('show-controls', showControls);

    dom.video.classList.toggle('hidden', slot.state !== 'playing');
    dom.slotBadge.classList.toggle('hidden', immersive || slot.state !== 'idle');
    dom.slotNext.classList.toggle('hidden', !isNext);

    dom.idleBox.classList.toggle('hidden', slot.state !== 'idle');
    dom.idleTitle.textContent = isNext ? 'Add a stream' : 'Empty pane';

    dom.resolvingBox.classList.toggle('hidden', slot.state !== 'resolving');
    dom.resolvingTitle.textContent = slot.title;

    dom.failedBox.classList.toggle('hidden', slot.state !== 'failed');
    dom.failedMsg.textContent = slot.error;

    // Top bar
    dom.barTitle.textContent = slot.title;
    dom.barTitle.title = slot.title;
    dom.statusDot.classList.toggle('buffering', slot.state === 'playing' && slot.isBuffering);
    dom.statusDot.classList.toggle('failed', slot.state === 'failed');
    dom.statusDot.classList.toggle('resolving', slot.state === 'resolving');

    if (slot.embedCount > 1 && slot.state === 'playing') {
      dom.feedTag.textContent = `${slot.embedIndex + 1}/${slot.embedCount}`;
      dom.feedTag.classList.remove('hidden');
      dom.switchFeedBtn.classList.remove('hidden');
      dom.switchFeedBtn.title = `Switch server (${slot.embedIndex + 1} of ${slot.embedCount})`;
    } else {
      dom.feedTag.classList.add('hidden');
      dom.switchFeedBtn.classList.add('hidden');
    }

    dom.audioBtn.innerHTML = svgIcon(slot.isMuted ? 'speaker-off' : 'speaker-on');
    dom.audioBtn.classList.toggle('muted', slot.isMuted);
    dom.audioBtn.title = slot.isMuted
      ? (activeCount() > 1 ? `Listen to ${slot.title} (Alt+Click to mix)` : `Unmute ${slot.title}`)
      : `Mute ${slot.title}`;

    dom.volSlider.classList.toggle('hidden', slot.isMuted);
    if (document.activeElement !== dom.volSlider) {
      dom.volSlider.value = String(slot.volume);
    }

    dom.focusBtn.innerHTML = svgIcon(isFocused ? 'grid' : 'expand');
    dom.focusBtn.title = isFocused ? 'Show all 4 panes (Ctrl+0)' : `Expand Pane ${i + 1} (Ctrl+${i + 1})`;

    const isPaneFull = isFocused && state.isWindowFullscreen;
    dom.fsBtn.innerHTML = svgIcon(isPaneFull ? 'fs-exit' : 'fs-enter');
    dom.fsBtn.title = isPaneFull ? 'Exit full screen (Esc)' : 'Full screen (Double-click / F11)';

    dom.bufferingPill.classList.toggle('hidden', !(slot.state === 'playing' && slot.isBuffering));

    dom.dropOverlay.classList.toggle('hidden', !slot.dropTarget);
    dom.dropLabel.textContent = slot.state === 'idle'
      ? `Drop to play in Pane ${i + 1}`
      : `Drop to replace ${slot.title}`;
  }

  function renderDock() {
    const immersive = isImmersive();
    el.multiviewDock.classList.toggle('hidden', !immersive);
    if (!immersive) return;

    const hideDock = (state.isPointerIdle && !state.isPointerOverChrome) || state.isPaletteOpen || state.dirOpen;
    el.multiviewDock.classList.toggle('dock-hidden', hideDock);
    el.dockGridBtn.classList.toggle('active', state.focusedIndex === null);

    el.dockChips.innerHTML = '';
    state.slots.forEach((slot, i) => {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'dock-chip' +
        (state.focusedIndex === i ? ' focused' : '') +
        (slot.state === 'idle' ? ' empty' : '');
      btn.title = slot.state === 'idle' ? `Pane ${i + 1} (Empty)` : `${slot.title} (Ctrl+${i + 1})`;

      const dotClass = slot.state === 'failed'
        ? ' failed'
        : (slot.isBuffering ? ' buffering' : (slot.state === 'resolving' ? ' resolving' : ''));
      const dotHtml = slot.state !== 'idle'
        ? `<span class="status-dot${dotClass}" style="width:6px;height:6px;"></span>`
        : '';
      const shortTitle = slot.state === 'idle' ? '' : `<span class="dock-chip-label">${escapeHtml(slot.title)}</span>`;
      const soundHtml = slot.state !== 'idle' && !slot.isMuted ? `<span style="opacity:0.85;display:inline-flex;">${svgIcon('speaker-on')}</span>` : '';

      btn.innerHTML = `${dotHtml}<span class="dock-chip-num">${i + 1}</span>${shortTitle}${soundHtml}`;
      btn.addEventListener('click', () => toggleFocus(i));
      el.dockChips.appendChild(btn);
    });
  }

  function renderShell() {
    const immersive = isImmersive();
    el.app.classList.toggle('mode-launch', !immersive);
    el.app.classList.toggle('mode-immersive', immersive);
    el.app.classList.toggle(
      'cursor-idle',
      immersive && state.isPointerIdle && !state.isPaletteOpen && !state.dirOpen && !state.isPointerOverChrome
    );

    el.launchHeader.classList.toggle('hidden', immersive);
    el.launchFooter.classList.toggle('hidden', immersive);
    el.pinShortcutBtn.classList.toggle('hidden', !BOOT.hasShortcuts);

    el.gridStage.classList.toggle('focused-single', state.focusedIndex !== null);

    // Launch warning vs hints
    if (!immersive && state.message) {
      el.launchHints.classList.add('hidden');
      el.launchWarning.classList.remove('hidden');
      el.launchWarningText.textContent = state.message;
    } else {
      el.launchHints.classList.remove('hidden');
      el.launchWarning.classList.add('hidden');
    }

    // Immersive banner
    if (immersive && state.message && !state.isPaletteOpen) {
      el.immersiveBanner.classList.remove('hidden');
      el.immersiveBannerIcon.textContent = state.messageKind === 'ok' ? '✓' : '⚠';
      el.immersiveBannerIcon.classList.toggle('ok', state.messageKind === 'ok');
      el.immersiveBannerText.textContent = state.message;
    } else {
      el.immersiveBanner.classList.add('hidden');
    }

    // Palette
    el.paletteBackdrop.classList.toggle('hidden', !state.isPaletteOpen);
    if (state.isPaletteOpen) {
      const nextIdx = nextEmptyIndex();
      if (nextIdx === null) {
        el.paletteDestDot.classList.add('full');
        el.paletteDestText.textContent = 'All 4 panes are playing. Drop a link onto a pane to replace it.';
      } else {
        el.paletteDestDot.classList.remove('full');
        el.paletteDestText.textContent = activeCount() === 0
          ? `Plays in Pane ${nextIdx + 1} with sound`
          : `Plays in Pane ${nextIdx + 1}, muted`;
      }
      if (state.message) {
        el.paletteError.textContent = state.message;
        el.paletteError.classList.remove('hidden');
      } else {
        el.paletteError.classList.add('hidden');
      }
    }

    // Directory visibility
    el.directoryBackdrop.classList.toggle('hidden', !state.dirOpen);

    syncInputs();
    renderDock();
  }

  function renderAll() {
    renderShell();
    for (let i = 0; i < MAX_STREAMS; i++) {
      renderTile(i);
    }
  }

  function formatLocalStart(ev) {
    if (typeof ev.startUnix === 'number') {
      try {
        const dt = new Date(ev.startUnix * 1000);
        return new Intl.DateTimeFormat(undefined, {
          hour: 'numeric',
          minute: '2-digit',
          timeZoneName: 'short',
        }).format(dt);
      } catch {}
    }
    return ev.startText || 'Time TBA';
  }

  function statusBadgeHtml(status) {
    switch (status) {
      case 'live':
        return `<span class="status-badge live"><span class="live-dot small"></span>LIVE</span>`;
      case 'channel':
        return `<span class="status-badge channel">24/7</span>`;
      case 'startingSoon':
        return `<span class="status-badge startingSoon">SOON</span>`;
      default:
        return '';
    }
  }

  function renderDirectory() {
    el.directoryBackdrop.classList.toggle('hidden', !state.dirOpen);
    if (!state.dirOpen) return;

    el.dirHostLabel.textContent = BOOT.homeHost || 'crackstreams.mx';
    if (state.dirTargetSlot !== null && state.dirTargetSlot !== undefined) {
      const targetSlot = state.slots[state.dirTargetSlot];
      el.dirDestBadge.textContent = targetSlot.state === 'idle'
        ? `Plays in Pane ${state.dirTargetSlot + 1}`
        : `Replaces Pane ${state.dirTargetSlot + 1}`;
    } else {
      el.dirDestBadge.textContent = 'Plays in next free pane';
    }

    const liveTotal = state.events.filter((e) => e.status === 'live' || e.status === 'channel').length;
    if (liveTotal > 0) {
      el.dirLiveCount.innerHTML = `<span class="live-dot small"></span>${liveTotal} LIVE`;
      el.dirLiveCount.classList.remove('hidden');
    } else {
      el.dirLiveCount.classList.add('hidden');
    }

    el.dirFilterClear.classList.toggle('hidden', !state.dirFilter);
    el.dirRefreshBtn.disabled = state.loadingLeagues || state.loadingEvents;

    // Sidebar
    el.dirSidebar.innerHTML = '';
    if (state.leagues.length === 0) {
      if (state.leaguesError) {
        el.dirSidebar.innerHTML = `
          <div class="dir-placeholder">
            <div>⚠</div>
            <div>${escapeHtml(state.leaguesError)}</div>
            <button type="button" class="pill-btn accent" id="retryLeaguesBtn">Try again</button>
          </div>`;
        el.dirSidebar.querySelector('#retryLeaguesBtn')?.addEventListener('click', () => loadLeagues(true));
      } else {
        el.dirSidebar.innerHTML = `<div class="dir-placeholder"><div class="mini-spinner"></div><div>Loading sports…</div></div>`;
      }
    } else {
      state.leagues.forEach((lg) => {
        const btn = document.createElement('button');
        btn.type = 'button';
        btn.className = 'league-row' + (state.selectedLeagueId === lg.id ? ' selected' : '');
        const monogram = escapeHtml(lg.name.slice(0, 2).toUpperCase());
        if (lg.logo) {
          btn.innerHTML = `<img class="league-logo" src="${escapeAttr(lg.logo)}" alt="" /><span style="overflow:hidden;text-overflow:ellipsis;white-space:nowrap;">${escapeHtml(lg.name)}</span>`;
          const img = btn.querySelector('img');
          img.addEventListener('error', () => {
            const fallback = document.createElement('span');
            fallback.className = 'league-monogram';
            fallback.textContent = lg.name.slice(0, 2).toUpperCase();
            img.replaceWith(fallback);
          }, { once: true });
        } else {
          btn.innerHTML = `<span class="league-monogram">${monogram}</span><span>${escapeHtml(lg.name)}</span>`;
        }
        btn.addEventListener('click', () => selectLeague(lg.id));
        el.dirSidebar.appendChild(btn);
      });
    }

    // Events pane
    el.dirEventsPane.innerHTML = '';
    const query = state.dirFilter.trim().toLowerCase();
    const filtered = query
      ? state.events.filter((e) => e.title.toLowerCase().includes(query))
      : state.events;

    if (state.leagues.length === 0) {
      // Wait for sidebar
    } else if (filtered.length === 0) {
      if (state.loadingEvents) {
        el.dirEventsPane.innerHTML = `<div class="dir-placeholder"><div class="mini-spinner"></div><div>Loading games…</div></div>`;
      } else if (state.eventsError) {
        el.dirEventsPane.innerHTML = `
          <div class="dir-placeholder">
            <div class="warn-circle">⚠</div>
            <div>${escapeHtml(state.eventsError)}</div>
            <button type="button" class="pill-btn accent" id="retryEventsBtn">Try again</button>
          </div>`;
        el.dirEventsPane.querySelector('#retryEventsBtn')?.addEventListener('click', () => {
          if (state.selectedLeagueId) loadEvents(state.selectedLeagueId, true);
        });
      } else if (query && state.events.length > 0) {
        el.dirEventsPane.innerHTML = `
          <div class="dir-placeholder">
            <div>No matching games for “${escapeHtml(state.dirFilter)}”.</div>
            <button type="button" class="pill-btn accent" id="clearFilterAction">Clear filter</button>
          </div>`;
        el.dirEventsPane.querySelector('#clearFilterAction')?.addEventListener('click', () => {
          state.dirFilter = '';
          el.dirFilterInput.value = '';
          renderDirectory();
        });
      } else {
        el.dirEventsPane.innerHTML = `<div class="dir-placeholder"><div>No games listed right now for this sport.</div></div>`;
      }
    } else {
      // Group by day heading
      const sections = [];
      for (const ev of filtered) {
        const dayTitle = ev.day || 'Games';
        let sec = sections.find((s) => s.title === dayTitle);
        if (!sec) {
          sec = { title: dayTitle, events: [] };
          sections.push(sec);
        }
        sec.events.push(ev);
      }

      const playingUrls = new Set(state.slots.map((s) => s.sourceUrl).filter(Boolean));

      for (const sec of sections) {
        const header = document.createElement('div');
        header.className = 'dir-day-header';
        header.innerHTML = `<span>${escapeHtml(sec.title)}</span><span class="dir-day-count">${sec.events.length}</span>`;
        el.dirEventsPane.appendChild(header);

        for (const ev of sec.events) {
          const isPlaying = playingUrls.has(ev.url);
          const prominent = ev.status === 'live' || ev.status === 'channel' || ev.status === 'startingSoon';
          const row = document.createElement('div');
          row.className = 'event-row' + (state.selectedEventId === ev.id ? ' selected' : '');

          const playingTag = isPlaying ? `<span class="status-badge playing">PLAYING</span>` : '';
          row.innerHTML = `
            <div class="event-main">
              <div class="event-title-line">
                ${statusBadgeHtml(ev.status)}
                ${playingTag}
                <span class="event-title" title="${escapeAttr(ev.title)}">${escapeHtml(ev.title)}</span>
              </div>
              <div class="event-meta">
                <span>${escapeHtml(formatLocalStart(ev))}</span>
                ${ev.startText && ev.startUnix ? `<span style="opacity:0.48;">(${escapeHtml(ev.startText)})</span>` : ''}
              </div>
            </div>
            <button type="button" class="watch-cta-btn${prominent ? ' prominent' : ''}">Watch</button>
          `;

          row.addEventListener('click', () => {
            state.selectedEventId = ev.id;
            el.dirEventsPane.querySelectorAll('.event-row').forEach((r) => r.classList.remove('selected'));
            row.classList.add('selected');
          });
          row.addEventListener('dblclick', () => watchEvent(ev));
          row.querySelector('.watch-cta-btn').addEventListener('click', (e) => {
            e.stopPropagation();
            watchEvent(ev);
          });
          el.dirEventsPane.appendChild(row);
        }
      }
    }

    // Footer status
    if (state.message && state.dirOpen) {
      el.dirFooterStatus.textContent = state.message;
      el.dirFooterStatus.classList.add('warn');
    } else if (state.eventsWarning) {
      el.dirFooterStatus.textContent = state.eventsWarning;
      el.dirFooterStatus.classList.add('warn');
    } else {
      el.dirFooterStatus.textContent = 'Click Watch or double-click any matchup. Streams typically go live up to 60 minutes before kickoff.';
      el.dirFooterStatus.classList.remove('warn');
    }
  }

  function escapeHtml(str) {
    return String(str || '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  function escapeAttr(str) {
    return escapeHtml(str).replace(/'/g, '&#39;');
  }

  // Idle cursor / auto-hide dock & controls
  function wakePointer() {
    if (state.isPointerIdle) {
      state.isPointerIdle = false;
      renderAll();
    }
    clearTimeout(idleTimer);
    idleTimer = setTimeout(() => {
      const anyPlaying = state.slots.some((s) => s.state === 'playing');
      if (anyPlaying && !state.isPaletteOpen && !state.dirOpen && !state.isPointerOverChrome) {
        state.isPointerIdle = true;
        renderAll();
      }
    }, IDLE_HIDE_MS);
  }

  // Global Event Wiring
  function wireGlobalEvents() {
    document.addEventListener('mousemove', wakePointer, { passive: true });
    el.multiviewDock.addEventListener('mouseenter', () => { state.isPointerOverChrome = true; });
    el.multiviewDock.addEventListener('mouseleave', () => { state.isPointerOverChrome = false; wakePointer(); });

    el.launchBrowseBtn.addEventListener('click', () => openDirectory(null));
    el.dockBrowseBtn.addEventListener('click', () => openDirectory(null));
    el.dockAddBtn.addEventListener('click', showPalette);
    el.dockGridBtn.addEventListener('click', () => {
      state.focusedIndex = null;
      exitPaneFullscreenIfNeeded();
      renderAll();
    });

    el.pinShortcutBtn.addEventListener('click', async () => {
      try {
        const resp = await apiFetch('/api/window/shortcuts', { method: 'POST' });
        const data = await resp.json().catch(() => ({}));
        if (resp.ok) {
          setMessage('Added Crackstreams shortcut to your Desktop & Start Menu!', 'ok');
        } else {
          setMessage(data.error || 'Could not create shortcut.');
        }
      } catch {
        setMessage('Could not create shortcut.');
      }
    });

    const onInputChange = (val) => {
      state.input = val;
      syncInputs();
    };
    el.launchUrlInput.addEventListener('input', (e) => onInputChange(e.target.value));
    el.paletteUrlInput.addEventListener('input', (e) => onInputChange(e.target.value));

    el.launchClearBtn.addEventListener('click', () => { onInputChange(''); el.launchUrlInput.focus(); });
    el.paletteClearBtn.addEventListener('click', () => { onInputChange(''); el.paletteUrlInput.focus(); });

    el.launchPasteBtn.addEventListener('click', () => pasteIntoField(el.launchUrlInput));
    el.palettePasteBtn.addEventListener('click', () => pasteIntoField(el.paletteUrlInput));
    el.paletteBrowseBtn.addEventListener('click', () => openDirectory(null));

    el.launchUrlForm.addEventListener('submit', (e) => {
      e.preventDefault();
      addFromInput();
    });
    el.paletteUrlForm.addEventListener('submit', (e) => {
      e.preventDefault();
      if (addFromInput()) hidePalette();
    });

    el.launchWarningDismiss.addEventListener('click', () => setMessage(null));
    el.immersiveBannerDismiss.addEventListener('click', () => setMessage(null));

    el.paletteBackdrop.addEventListener('click', (e) => {
      if (e.target === el.paletteBackdrop) hidePalette();
    });

    el.directoryBackdrop.addEventListener('click', (e) => {
      if (e.target === el.directoryBackdrop) closeDirectory();
    });
    el.dirCloseBtn.addEventListener('click', closeDirectory);
    el.dirRefreshBtn.addEventListener('click', () => {
      if (state.leagues.length === 0) loadLeagues(true);
      else if (state.selectedLeagueId) loadEvents(state.selectedLeagueId, true);
    });
    el.dirFilterInput.addEventListener('input', (e) => {
      state.dirFilter = e.target.value;
      renderDirectory();
    });
    el.dirFilterClear.addEventListener('click', () => {
      state.dirFilter = '';
      el.dirFilterInput.value = '';
      renderDirectory();
      el.dirFilterInput.focus();
    });

    // Window-wide drag & drop fallback
    window.addEventListener('dragover', (e) => e.preventDefault());
    window.addEventListener('drop', (e) => {
      e.preventDefault();
      handleDroppedUrl(extractDroppedText(e.dataTransfer), null);
    });

    document.addEventListener('fullscreenchange', () => {
      state.isWindowFullscreen = Boolean(document.fullscreenElement);
      renderAll();
    });

    // Keyboard Shortcuts (Windows Ctrl+ / Alt+ + Mac Cmd+ support)
    window.addEventListener('keydown', (e) => {
      const mod = e.ctrlKey || e.metaKey;

      if (e.key === 'F11') {
        e.preventDefault();
        requestWindowFullscreen('toggle');
        return;
      }

      if (e.key === 'Escape') {
        if (state.dirOpen) {
          e.preventDefault();
          closeDirectory();
        } else if (state.isPaletteOpen) {
          e.preventDefault();
          hidePalette();
        } else if (state.focusedIndex !== null) {
          e.preventDefault();
          state.focusedIndex = null;
          exitPaneFullscreenIfNeeded();
          renderAll();
        } else if (state.isWindowFullscreen) {
          e.preventDefault();
          requestWindowFullscreen('exit');
        }
        return;
      }

      if (state.dirOpen) {
        if (mod && e.key.toLowerCase() === 'r') {
          e.preventDefault();
          el.dirRefreshBtn.click();
        } else if (e.key === 'Enter' && document.activeElement !== el.dirFilterInput && state.selectedEventId) {
          const ev = state.events.find((x) => x.id === state.selectedEventId);
          if (ev) {
            e.preventDefault();
            watchEvent(ev);
          }
        }
        return;
      }

      if (mod && !e.altKey && e.key.toLowerCase() === 'l') {
        e.preventDefault();
        if (state.isPaletteOpen) hidePalette();
        else showPalette();
        return;
      }

      if (mod && !e.altKey && e.key.toLowerCase() === 'b') {
        e.preventDefault();
        openDirectory(null);
        return;
      }

      if (mod && !e.altKey && e.key === '0') {
        e.preventDefault();
        state.focusedIndex = null;
        exitPaneFullscreenIfNeeded();
        renderAll();
        return;
      }

      if (mod && !e.altKey && ['1', '2', '3', '4'].includes(e.key)) {
        e.preventDefault();
        toggleFocus(parseInt(e.key, 10) - 1);
        return;
      }

      if (e.altKey && ['1', '2', '3', '4'].includes(e.key)) {
        e.preventDefault();
        soloAudio(parseInt(e.key, 10) - 1);
      }
    });
  }

  // Boot
  initGridDom();
  wireGlobalEvents();
  renderAll();

  if (BOOT.browserMode) {
    const ping = () => apiFetch('/api/heartbeat', { method: 'POST' }).catch(() => {});
    ping();
    setInterval(ping, 10000);
    window.addEventListener('pagehide', () => {
      apiFetch('/api/heartbeat?bye=1', { method: 'POST', keepalive: true }).catch(() => {});
    });
  }
})();
