package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io/fs"
	"net"
	"net/http"
	"net/url"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/nikships/crackstreams/windows/internal/directory"
	"github.com/nikships/crackstreams/windows/internal/netclient"
	"github.com/nikships/crackstreams/windows/internal/proxy"
	"github.com/nikships/crackstreams/windows/internal/resolver"
)

const sessionCookieName = "cs_session"

type WindowController interface {
	HasNativeWindow() bool
	SetFullscreen(mode string) bool
	IsFullscreen() bool
	CreateShortcuts() error
}

type Server struct {
	listener   net.Listener
	httpServer *http.Server
	proxy      *proxy.HLSProxy
	directory  *directory.Service
	resolver   *resolver.Resolver
	assets     fs.FS
	winCtrl    WindowController

	hbMu       sync.Mutex
	hbSeen     bool
	hbLastTime time.Time
	hbClosed   bool
}

type Config struct {
	Client    *netclient.Client
	HomeURL   string
	Assets    fs.FS
	Token     string
	WinCtrl   WindowController
}

func New(cfg Config) (*Server, error) {
	client := cfg.Client
	if client == nil {
		client = netclient.Default
	}
	homeURL := cfg.HomeURL
	if homeURL == "" {
		homeURL = directory.DefaultHomeURL
	}

	// Bind strictly to IPv4 loopback 127.0.0.1 so Windows Defender Firewall never prompts.
	ln, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, fmt.Errorf("could not start local playback server: %w", err)
	}
	port := ln.Addr().(*net.TCPAddr).Port

	hlsProxy, err := proxy.New(client, port, cfg.Token)
	if err != nil {
		_ = ln.Close()
		return nil, err
	}

	s := &Server{
		listener:  ln,
		proxy:     hlsProxy,
		directory: directory.NewService(client, homeURL),
		resolver:  resolver.New(client),
		assets:    cfg.Assets,
		winCtrl:   cfg.WinCtrl,
	}

	mux := http.NewServeMux()
	mux.Handle("/hls/", hlsProxy)
	mux.HandleFunc("/api/leagues", s.requireAuth(s.handleLeagues))
	mux.HandleFunc("/api/events", s.requireAuth(s.handleEvents))
	mux.HandleFunc("/api/resolve", s.requireAuth(s.handleResolve))
	mux.HandleFunc("/api/window/fullscreen", s.requireAuth(s.handleFullscreen))
	mux.HandleFunc("/api/window/shortcuts", s.requireAuth(s.handleShortcuts))
	mux.HandleFunc("/api/heartbeat", s.requireAuth(s.handleHeartbeat))
	mux.HandleFunc("/", s.handleAsset)

	s.httpServer = &http.Server{
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	return s, nil
}

func (s *Server) SetWindowController(ctrl WindowController) {
	s.winCtrl = ctrl
}

func (s *Server) Start() {
	go func() {
		_ = s.httpServer.Serve(s.listener)
	}()
}

func (s *Server) Close(ctx context.Context) error {
	return s.httpServer.Shutdown(ctx)
}

func (s *Server) Port() int {
	return s.proxy.Port()
}

func (s *Server) Token() string {
	return s.proxy.Token()
}

func (s *Server) LaunchURL() string {
	return fmt.Sprintf("http://127.0.0.1:%d/?t=%s", s.Port(), url.QueryEscape(s.Token()))
}

func (s *Server) Proxy() *proxy.HLSProxy {
	return s.proxy
}

func (s *Server) checkRequestOrigin(r *http.Request) bool {
	if !s.proxy.ValidHost(r.Host) {
		return false
	}
	if secSite := strings.ToLower(r.Header.Get("Sec-Fetch-Site")); secSite != "" && secSite != "same-origin" && secSite != "none" {
		return false
	}
	if origin := r.Header.Get("Origin"); origin != "" {
		ou, err := url.Parse(origin)
		if err != nil || !s.proxy.ValidHost(ou.Host) {
			return false
		}
	}
	return true
}

func (s *Server) extractAuthenticated(r *http.Request) bool {
	if tok := r.Header.Get("X-Crackstreams-Token"); s.proxy.ValidToken(tok) {
		return true
	}
	if tok := r.URL.Query().Get("t"); s.proxy.ValidToken(tok) {
		return true
	}
	if c, err := r.Cookie(sessionCookieName); err == nil && s.proxy.ValidToken(c.Value) {
		return true
	}
	return false
}

func (s *Server) requireAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if !s.checkRequestOrigin(r) || !s.extractAuthenticated(r) {
			writeJSON(w, http.StatusForbidden, map[string]any{"error": "Forbidden"})
			return
		}
		next(w, r)
	}
}

func (s *Server) handleAsset(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	if !s.checkRequestOrigin(r) {
		w.WriteHeader(http.StatusForbidden)
		return
	}
	if !s.extractAuthenticated(r) {
		w.WriteHeader(http.StatusForbidden)
		return
	}
	if s.assets == nil {
		w.WriteHeader(http.StatusNotFound)
		return
	}

	reqPath := strings.TrimPrefix(r.URL.Path, "/")
	if reqPath == "" || reqPath == "index.html" {
		http.SetCookie(w, &http.Cookie{
			Name:     sessionCookieName,
			Value:    s.Token(),
			Path:     "/",
			HttpOnly: true,
			SameSite: http.SameSiteStrictMode,
		})
		raw, err := fs.ReadFile(s.assets, "index.html")
		if err != nil {
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		isNativeWindow := s.winCtrl != nil && s.winCtrl.HasNativeWindow()
		bootData, _ := json.Marshal(map[string]any{
			"token":        s.Token(),
			"homeHost":     s.directory.HomeHost(),
			"os":           runtime.GOOS,
			"hasShortcuts": runtime.GOOS == "windows",
			"browserMode":  runtime.GOOS == "windows" && !isNativeWindow,
		})
		bootScript := fmt.Sprintf("<script>window.__CS_BOOT__=%s;</script>", string(bootData))
		injected := strings.Replace(string(raw), "<!--__CS_BOOT__-->", bootScript, 1)

		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		w.WriteHeader(http.StatusOK)
		if r.Method != http.MethodHead {
			_, _ = w.Write([]byte(injected))
		}
		return
	}

	data, err := fs.ReadFile(s.assets, reqPath)
	if err != nil {
		w.WriteHeader(http.StatusNotFound)
		return
	}
	var ctype string
	switch {
	case strings.HasSuffix(reqPath, ".css"):
		ctype = "text/css; charset=utf-8"
	case strings.HasSuffix(reqPath, ".js"):
		ctype = "application/javascript; charset=utf-8"
	case strings.HasSuffix(reqPath, ".png"):
		ctype = "image/png"
	case strings.HasSuffix(reqPath, ".svg"):
		ctype = "image/svg+xml"
	default:
		ctype = "application/octet-stream"
	}
	w.Header().Set("Content-Type", ctype)
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(http.StatusOK)
	if r.Method != http.MethodHead {
		_, _ = w.Write(data)
	}
}

func (s *Server) handleLeagues(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "Method not allowed"})
		return
	}
	force := r.URL.Query().Get("force") == "1"
	leagues, err := s.directory.Leagues(r.Context(), force)
	if err != nil {
		if errors.Is(err, context.Canceled) {
			return
		}
		writeJSON(w, http.StatusBadGateway, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"leagues":  leagues,
		"homeHost": s.directory.HomeHost(),
	})
}

func (s *Server) handleEvents(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "Method not allowed"})
		return
	}
	leagueURL := r.URL.Query().Get("league")
	force := r.URL.Query().Get("force") == "1"
	events, warning, err := s.directory.Events(r.Context(), leagueURL, force)
	if err != nil {
		if errors.Is(err, context.Canceled) {
			return
		}
		writeJSON(w, http.StatusBadGateway, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"events":  events,
		"warning": warning,
	})
}

type resolveRequest struct {
	URL    string `json:"url"`
	Offset int    `json:"offset"`
}

func (s *Server) handleResolve(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "Method not allowed"})
		return
	}
	var req resolveRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 16*1024)).Decode(&req); err != nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "Invalid request payload."})
		return
	}
	target, ok := netclient.ValidStreamURL(req.URL)
	if !ok {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "Enter a valid http:// or https:// stream URL."})
		return
	}

	resolved, err := s.resolver.Resolve(r.Context(), target, req.Offset)
	if err != nil {
		if errors.Is(err, context.Canceled) {
			return
		}
		writeJSON(w, http.StatusBadGateway, map[string]any{"error": err.Error()})
		return
	}

	localPlaylist := s.proxy.LocalURL(resolved.Playlist, resolved.Referer, "m.m3u8")
	writeJSON(w, http.StatusOK, map[string]any{
		"playlistUrl": localPlaylist,
		"title":       resolved.Title,
		"embedIndex":  resolved.EmbedIndex,
		"embedCount":  resolved.EmbedCount,
	})
}

type fullscreenRequest struct {
	Mode string `json:"mode"` // "toggle", "enter", "exit"
}

func (s *Server) handleFullscreen(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "Method not allowed"})
		return
	}
	var req fullscreenRequest
	_ = json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&req)
	if req.Mode == "" {
		req.Mode = "toggle"
	}
	if s.winCtrl == nil || !s.winCtrl.HasNativeWindow() {
		writeJSON(w, http.StatusOK, map[string]any{"native": false})
		return
	}
	isFull := s.winCtrl.SetFullscreen(req.Mode)
	writeJSON(w, http.StatusOK, map[string]any{
		"native":     true,
		"fullscreen": isFull,
	})
}

func (s *Server) handleHeartbeat(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "Method not allowed"})
		return
	}
	bye := r.URL.Query().Get("bye") == "1"
	s.hbMu.Lock()
	s.hbSeen = true
	s.hbLastTime = time.Now()
	s.hbClosed = bye
	s.hbMu.Unlock()
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) WaitForBrowserSession(connectGrace, idleTimeout time.Duration) {
	start := time.Now()
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for range ticker.C {
		s.hbMu.Lock()
		seen := s.hbSeen
		last := s.hbLastTime
		closed := s.hbClosed
		s.hbMu.Unlock()

		if !seen {
			if time.Since(start) > connectGrace {
				return
			}
			continue
		}
		if closed && time.Since(last) > 4*time.Second {
			return
		}
		if time.Since(last) > idleTimeout {
			return
		}
	}
}

func (s *Server) handleShortcuts(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		writeJSON(w, http.StatusMethodNotAllowed, map[string]any{"error": "Method not allowed"})
		return
	}
	if s.winCtrl == nil {
		writeJSON(w, http.StatusBadRequest, map[string]any{"error": "Shortcut creation is only available on Windows."})
		return
	}
	if err := s.winCtrl.CreateShortcuts(); err != nil {
		writeJSON(w, http.StatusInternalServerError, map[string]any{"error": err.Error()})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func writeJSON(w http.ResponseWriter, status int, payload any) {
	data, _ := json.Marshal(payload)
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("X-Content-Type-Options", "nosniff")
	w.WriteHeader(status)
	_, _ = w.Write(data)
}
