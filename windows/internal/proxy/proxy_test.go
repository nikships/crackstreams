package proxy_test

import (
	"bytes"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"

	"github.com/nikships/crackstreams/windows/internal/netclient"
	"github.com/nikships/crackstreams/windows/internal/proxy"
)

func mustURL(t *testing.T, raw string) *url.URL {
	t.Helper()
	u, err := url.Parse(raw)
	if err != nil {
		t.Fatalf("parse %q: %v", raw, err)
	}
	return u
}

func TestRewritesVariantSegmentsKeysAndInitializationMap(t *testing.T) {
	p, err := proxy.New(nil, 4321, "")
	if err != nil {
		t.Fatal(err)
	}
	base := mustURL(t, "https://cdn.example/live/master.m3u8")
	referer := "https://embed.example/"

	playlist := strings.Join([]string{
		"#EXTM3U",
		"#EXT-X-STREAM-INF:BANDWIDTH=1000000",
		"video/720p.m3u8",
		`#EXT-X-KEY:METHOD=AES-128,URI="keys/key.bin",IV=0x1`,
		`#EXT-X-MAP:URI="init.mp4"`,
		"#EXTINF:4.0,",
		"segment-1.txt",
		`#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",URI="audio/en.m3u8"`,
	}, "\n")

	rewritten := p.Rewrite(playlist, base, referer)
	for _, needle := range []string{"/hls/m.m3u8?", "/hls/s.ts?", "/hls/k.key?", "/hls/i.mp4?"} {
		if !strings.Contains(rewritten, needle) {
			t.Fatalf("expected rewritten playlist to contain %q:\n%s", needle, rewritten)
		}
	}

	var urls []*url.URL
	for _, line := range strings.Split(rewritten, "\n") {
		if strings.HasPrefix(line, "http") {
			urls = append(urls, mustURL(t, line))
		} else if idx := strings.Index(line, `URI="http`); idx != -1 {
			sub := line[idx+5:]
			end := strings.Index(sub, `"`)
			urls = append(urls, mustURL(t, sub[:end]))
		}
	}
	if len(urls) != 5 {
		t.Fatalf("expected 5 rewritten URLs, got %d", len(urls))
	}
	for _, u := range urls {
		if u.Host != "127.0.0.1:4321" {
			t.Fatalf("unexpected host: %s", u.Host)
		}
		q := u.Query()
		if len(q.Get("t")) < 32 {
			t.Fatalf("expected long token, got %q", q.Get("t"))
		}
		if q.Get("r") != referer {
			t.Fatalf("expected referer %q, got %q", referer, q.Get("r"))
		}
		if q.Get("u") == "" {
			t.Fatalf("missing upstream param u")
		}
	}
}

func TestLeavesInvalidAndNonMediaLinesUnchanged(t *testing.T) {
	p, _ := proxy.New(nil, 4321, "")
	base := mustURL(t, "https://cdn.example/live/master.m3u8")
	playlist := "#EXTM3U\n#EXTINF:4,\njavascript:alert(1)\n"
	if got := p.Rewrite(playlist, base, "https://embed.example/"); got != playlist {
		t.Fatalf("expected unchanged playlist, got:\n%s", got)
	}
}

func TestRangeParsing(t *testing.T) {
	data := []byte{0, 1, 2, 3, 4, 5, 6, 7, 8, 9}

	s, start, end, ok := proxy.Slice(data, "bytes=2-4")
	if !ok || !bytes.Equal(s, []byte{2, 3, 4}) || start != 2 || end != 4 {
		t.Fatalf("unexpected bytes=2-4 result: ok=%v %v %d-%d", ok, s, start, end)
	}
	s, _, _, ok = proxy.Slice(data, "bytes=7-")
	if !ok || !bytes.Equal(s, []byte{7, 8, 9}) {
		t.Fatalf("unexpected bytes=7- result")
	}
	s, _, _, ok = proxy.Slice(data, "bytes=-3")
	if !ok || !bytes.Equal(s, []byte{7, 8, 9}) {
		t.Fatalf("unexpected bytes=-3 result")
	}

	for _, bad := range []string{"bytes=10-11", "bytes=-0", "bytes=0-2,5-7", "lines=0-2"} {
		if _, _, _, ok := proxy.Slice(data, bad); ok {
			t.Fatalf("expected range %q to fail", bad)
		}
	}
}

func TestProxyEnforcesTokenHostAndCrossSiteProtection(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Referer") != "https://embed.example/" {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		_, _ = w.Write([]byte{0x47, 0x01, 0x02, 0x03})
	}))
	defer upstream.Close()

	p, _ := proxy.New(netclient.NewWithHTTPClient(upstream.Client()), 9876, "secret-token-12345678901234567890")
	upURL := mustURL(t, upstream.URL+"/seg.txt")
	validLocal := p.LocalURL(upURL, "https://embed.example/", "s.ts")

	// Valid loopback request succeeds and maps .txt segment to video/mp2t
	req := httptest.NewRequest(http.MethodGet, validLocal, nil)
	req.Host = "127.0.0.1:9876"
	rec := httptest.NewRecorder()
	p.ServeHTTP(rec, req)
	if rec.Code != http.StatusOK || rec.Header().Get("Content-Type") != "video/mp2t" {
		t.Fatalf("expected 200 video/mp2t, got %d %s", rec.Code, rec.Header().Get("Content-Type"))
	}

	// Wrong Host header rejected (DNS rebinding protection)
	reqBadHost := httptest.NewRequest(http.MethodGet, validLocal, nil)
	reqBadHost.Host = "evil.example:9876"
	recBadHost := httptest.NewRecorder()
	p.ServeHTTP(recBadHost, reqBadHost)
	if recBadHost.Code != http.StatusForbidden {
		t.Fatalf("expected 403 for invalid host, got %d", recBadHost.Code)
	}

	// Wrong token rejected
	reqBadTok := httptest.NewRequest(http.MethodGet, strings.ReplaceAll(validLocal, "secret-token", "wrong-token"), nil)
	reqBadTok.Host = "127.0.0.1:9876"
	recBadTok := httptest.NewRecorder()
	p.ServeHTTP(recBadTok, reqBadTok)
	if recBadTok.Code != http.StatusForbidden {
		t.Fatalf("expected 403 for invalid token, got %d", recBadTok.Code)
	}

	// Cross-site browser fetch rejected
	reqCross := httptest.NewRequest(http.MethodGet, validLocal, nil)
	reqCross.Host = "127.0.0.1:9876"
	reqCross.Header.Set("Sec-Fetch-Site", "cross-site")
	recCross := httptest.NewRecorder()
	p.ServeHTTP(recCross, reqCross)
	if recCross.Code != http.StatusForbidden {
		t.Fatalf("expected 403 for cross-site request, got %d", recCross.Code)
	}
}
