package resolver_test

import (
	"context"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"

	"github.com/nikships/crackstreams/windows/internal/netclient"
	"github.com/nikships/crackstreams/windows/internal/resolver"
)

func mustURL(t *testing.T, raw string) *url.URL {
	t.Helper()
	u, err := url.Parse(raw)
	if err != nil {
		t.Fatalf("parse %q: %v", raw, err)
	}
	return u
}

func TestExtractsEmbedsFromStreamJSON(t *testing.T) {
	html := `<script>const allStreams = [
	  {"label":"Link-1 HD","type":"external","value":"https:\/\/yieldz.example\/nba\/game?a=1&amp;b=2"},
	  {"label":"Link-2 HD","type":"external","value":"https://backup.example/embed"}
	];</script>`
	embeds := resolver.EmbedURLs(html, mustURL(t, "https://crackstreams.example/stream/game"))
	if len(embeds) != 2 {
		t.Fatalf("expected 2 embeds, got %d", len(embeds))
	}
	if got := embeds[0].String(); got != "https://yieldz.example/nba/game?a=1&b=2" {
		t.Fatalf("unexpected embed[0]: %s", got)
	}
	if got := embeds[1].Hostname(); got != "backup.example" {
		t.Fatalf("unexpected embed[1] host: %s", got)
	}
}

func TestFallsBackToIframesAndSkipsTrackers(t *testing.T) {
	html := `
	<iframe src="https://histats.example/track"></iframe>
	<iframe src="https://chatango.example/room"></iframe>
	<iframe src='/embed/live'></iframe>`
	embeds := resolver.EmbedURLs(html, mustURL(t, "https://watch.example/game"))
	if len(embeds) != 1 || embeds[0].String() != "https://watch.example/embed/live" {
		t.Fatalf("unexpected embeds: %v", embeds)
	}
}

func TestExtractsDirectPlaylistAndEscapedM3U8(t *testing.T) {
	direct := `DIRECT_STREAM_URL = "https:\/\/cdn.example\/live\/playlist.m3u8?token=a&amp;b=c";`
	got := resolver.PlaylistURL(direct, mustURL(t, "https://embed.example/player"))
	if got == nil || got.String() != "https://cdn.example/live/playlist.m3u8?token=a&b=c" {
		t.Fatalf("unexpected direct playlist: %v", got)
	}

	fallback := `var other = 'https://cdn.example/v2/master.m3u8?key=1';`
	got2 := resolver.PlaylistURL(fallback, mustURL(t, "https://embed.example"))
	if got2 == nil || got2.Path != "/v2/master.m3u8" {
		t.Fatalf("unexpected fallback playlist: %v", got2)
	}

	escaped := `{"file":"https:\/\/cdn.example\/hls\/feed.m3u8?sig=9"}`
	got3 := resolver.PlaylistURL(escaped, mustURL(t, "https://embed.example"))
	if got3 == nil || got3.String() != "https://cdn.example/hls/feed.m3u8?sig=9" {
		t.Fatalf("unexpected escaped playlist: %v", got3)
	}
}

func TestRejectsNonHTTPSchemes(t *testing.T) {
	html := `DIRECT_STREAM_URL = "javascript:alert(1)";`
	if got := resolver.PlaylistURL(html, mustURL(t, "https://embed.example")); got != nil {
		t.Fatalf("expected nil for javascript scheme, got %v", got)
	}
}

func TestPrettyTitle(t *testing.T) {
	got := resolver.PrettyTitle(mustURL(t, "https://watch.example/stream/golden-state-warriors-vs-houston-rockets"))
	if got != "Golden State Warriors vs Houston Rockets" {
		t.Fatalf("unexpected pretty title: %q", got)
	}
}

func TestOriginIncludesNonDefaultPort(t *testing.T) {
	if got := netclient.Origin(mustURL(t, "https://cdn.example:8443/a/b")); got != "https://cdn.example:8443/" {
		t.Fatalf("unexpected origin: %q", got)
	}
	if got := netclient.Origin(mustURL(t, "file:///tmp/video.m3u8")); got != "" {
		t.Fatalf("expected empty origin for file scheme, got %q", got)
	}
}

func TestResolveRetriesEmbedWithWatchSiteRefererAndValidatesPlaylistWithEmbedOrigin(t *testing.T) {
	var cdnSrv, embedSrv, watchSrv *httptest.Server

	cdnSrv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		expectedReferer := embedSrv.URL + "/"
		if r.Header.Get("Referer") != expectedReferer {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		_, _ = w.Write([]byte("#EXTM3U\n#EXTINF:4.0,\nseg1.ts\n"))
	}))
	defer cdnSrv.Close()

	embedSrv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Require watch-site Referer to reveal DIRECT_STREAM_URL (matching commit 39ec707 behavior).
		if r.Header.Get("Referer") != watchSrv.URL+"/" {
			_, _ = w.Write([]byte("<html>blocked without watch referer</html>"))
			return
		}
		_, _ = w.Write([]byte(`<html><script>const DIRECT_STREAM_URL = "` + cdnSrv.URL + `/live/index.m3u8";</script></html>`))
	}))
	defer embedSrv.Close()

	watchSrv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`<iframe src="` + embedSrv.URL + `/embed/1"></iframe>`))
	}))
	defer watchSrv.Close()

	res := resolver.New(netclient.NewWithHTTPClient(watchSrv.Client()))
	resolved, err := res.Resolve(context.Background(), mustURL(t, watchSrv.URL+"/stream/lakers-vs-celtics"), 0)
	if err != nil {
		t.Fatalf("Resolve failed: %v", err)
	}
	if resolved.Playlist.String() != cdnSrv.URL+"/live/index.m3u8" {
		t.Fatalf("unexpected playlist: %s", resolved.Playlist)
	}
	if resolved.Referer != embedSrv.URL+"/" {
		t.Fatalf("unexpected referer: %s", resolved.Referer)
	}
	if resolved.Title != "Lakers vs Celtics" {
		t.Fatalf("unexpected title: %s", resolved.Title)
	}
}
