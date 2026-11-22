package server_test

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/nikships/crackstreams/windows/internal/netclient"
	"github.com/nikships/crackstreams/windows/internal/server"
	"github.com/nikships/crackstreams/windows/web"
)

func TestEndToEndBootDirectoryResolveAndLoopbackHLSProxy(t *testing.T) {
	var upstream *httptest.Server
	upstream = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/":
			_, _ = w.Write([]byte(`<a class="card" href="/league/nbastreams"><div class="card-title">NBA Streams</div></a>`))
		case "/league/nbastreams":
			_, _ = w.Write([]byte(`<h2>Wednesday, November 11, 2026</h2><a class="card" href="/stream/warriors-vs-lakers"><div class="card-title">Warriors vs Lakers</div><div class="card-subtitle">Start time: 7:00 PM ET</div></a>`))
		case "/stream/warriors-vs-lakers":
			_, _ = w.Write([]byte(`<script>const allStreams = [{"value":"` + upstream.URL + `/embed/1"}];</script>`))
		case "/embed/1":
			_, _ = w.Write([]byte(`<script>const DIRECT_STREAM_URL = "` + upstream.URL + `/hls/master.m3u8";</script>`))
		case "/hls/master.m3u8":
			if r.Header.Get("Referer") != upstream.URL+"/" {
				w.WriteHeader(http.StatusForbidden)
				return
			}
			_, _ = w.Write([]byte("#EXTM3U\n#EXTINF:4.0,\nchunk-1.txt\n"))
		case "/hls/chunk-1.txt":
			if r.Header.Get("Referer") != upstream.URL+"/" {
				w.WriteHeader(http.StatusForbidden)
				return
			}
			_, _ = w.Write([]byte{0x47, 0x40, 0x00, 0x10, 0xFF})
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer upstream.Close()

	srv, err := server.New(server.Config{
		Client:  netclient.NewWithHTTPClient(upstream.Client()),
		HomeURL: upstream.URL + "/",
		Assets:  web.Assets,
	})
	if err != nil {
		t.Fatalf("server.New: %v", err)
	}
	srv.Start()
	defer func() {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		_ = srv.Close(ctx)
	}()

	// Unauthenticated root request must be rejected with 403.
	unauthResp, err := http.Get(fmt.Sprintf("http://127.0.0.1:%d/", srv.Port()))
	if err != nil {
		t.Fatal(err)
	}
	unauthResp.Body.Close()
	if unauthResp.StatusCode != http.StatusForbidden {
		t.Fatalf("expected 403 without token, got %d", unauthResp.StatusCode)
	}

	// Authenticated launch URL returns index.html with injected boot token and session cookie.
	bootResp, err := http.Get(srv.LaunchURL())
	if err != nil {
		t.Fatal(err)
	}
	bootBody, _ := io.ReadAll(bootResp.Body)
	bootResp.Body.Close()
	if bootResp.StatusCode != http.StatusOK || !strings.Contains(string(bootBody), "window.__CS_BOOT__=") {
		t.Fatalf("unexpected boot response: %d", bootResp.StatusCode)
	}

	// Fetch leagues via API
	reqLeagues, _ := http.NewRequest(http.MethodGet, fmt.Sprintf("http://127.0.0.1:%d/api/leagues", srv.Port()), nil)
	reqLeagues.Header.Set("X-Crackstreams-Token", srv.Token())
	respLeagues, err := http.DefaultClient.Do(reqLeagues)
	if err != nil {
		t.Fatal(err)
	}
	var leaguesPayload struct {
		Leagues []struct {
			Name string `json:"name"`
			URL  string `json:"url"`
		} `json:"leagues"`
	}
	_ = json.NewDecoder(respLeagues.Body).Decode(&leaguesPayload)
	respLeagues.Body.Close()
	if len(leaguesPayload.Leagues) != 1 || leaguesPayload.Leagues[0].Name != "NBA" {
		t.Fatalf("unexpected leagues payload: %+v", leaguesPayload)
	}

	// Resolve watch page via API
	resolveBody, _ := json.Marshal(map[string]any{"url": upstream.URL + "/stream/warriors-vs-lakers"})
	reqResolve, _ := http.NewRequest(http.MethodPost, fmt.Sprintf("http://127.0.0.1:%d/api/resolve", srv.Port()), bytes.NewReader(resolveBody))
	reqResolve.Header.Set("X-Crackstreams-Token", srv.Token())
	reqResolve.Header.Set("Content-Type", "application/json")
	respResolve, err := http.DefaultClient.Do(reqResolve)
	if err != nil {
		t.Fatal(err)
	}
	var resolvedPayload struct {
		PlaylistURL string `json:"playlistUrl"`
		Title       string `json:"title"`
	}
	_ = json.NewDecoder(respResolve.Body).Decode(&resolvedPayload)
	respResolve.Body.Close()
	if respResolve.StatusCode != http.StatusOK || resolvedPayload.PlaylistURL == "" {
		t.Fatalf("resolve failed: status=%d payload=%+v", respResolve.StatusCode, resolvedPayload)
	}

	// Fetch rewritten playlist from loopback HLS proxy
	respM3U8, err := http.Get(resolvedPayload.PlaylistURL)
	if err != nil {
		t.Fatal(err)
	}
	m3u8Bytes, _ := io.ReadAll(respM3U8.Body)
	respM3U8.Body.Close()
	m3u8Text := string(m3u8Bytes)
	if !strings.Contains(m3u8Text, "/hls/s.ts?") {
		t.Fatalf("expected rewritten .ts segment URL in playlist:\n%s", m3u8Text)
	}

	// Fetch rewritten media segment from loopback HLS proxy
	var segURL string
	for _, line := range strings.Split(m3u8Text, "\n") {
		if strings.HasPrefix(line, "http://127.0.0.1:") {
			segURL = strings.TrimSpace(line)
			break
		}
	}
	respSeg, err := http.Get(segURL)
	if err != nil {
		t.Fatal(err)
	}
	segData, _ := io.ReadAll(respSeg.Body)
	respSeg.Body.Close()
	if respSeg.StatusCode != http.StatusOK || respSeg.Header.Get("Content-Type") != "video/mp2t" || len(segData) != 5 {
		t.Fatalf("unexpected segment response: status=%d type=%s len=%d", respSeg.StatusCode, respSeg.Header.Get("Content-Type"), len(segData))
	}
}
