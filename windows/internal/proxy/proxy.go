package proxy

import (
	"crypto/rand"
	"crypto/subtle"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"path"
	"regexp"
	"strconv"
	"strings"

	"github.com/nikships/crackstreams/windows/internal/netclient"
)

var reAttributeURI = regexp.MustCompile(`URI="([^"]*)"`)

// HLSProxy rewrites HLS playlists and relays segments/keys over loopback with token and Host checks.
type HLSProxy struct {
	client *netclient.Client
	port   int
	token  string
}

func New(client *netclient.Client, port int, token string) (*HLSProxy, error) {
	if client == nil {
		client = netclient.Default
	}
	if token == "" {
		var buf [32]byte
		if _, err := rand.Read(buf[:]); err != nil {
			return nil, err
		}
		token = hex.EncodeToString(buf[:])
	}
	return &HLSProxy{
		client: client,
		port:   port,
		token:  token,
	}, nil
}

func (p *HLSProxy) SetPort(port int) {
	p.port = port
}

func (p *HLSProxy) Port() int {
	return p.port
}

func (p *HLSProxy) Token() string {
	return p.token
}

func (p *HLSProxy) ValidToken(candidate string) bool {
	if len(candidate) != len(p.token) {
		return false
	}
	return subtle.ConstantTimeCompare([]byte(candidate), []byte(p.token)) == 1
}

func (p *HLSProxy) ValidHost(hostHeader string) bool {
	h := strings.ToLower(strings.TrimSpace(hostHeader))
	return h == fmt.Sprintf("127.0.0.1:%d", p.port) ||
		h == fmt.Sprintf("localhost:%d", p.port) ||
		h == fmt.Sprintf("[::1]:%d", p.port)
}

func (p *HLSProxy) LocalURL(upstream *url.URL, referer string, kind string) string {
	if kind == "" {
		kind = "m.m3u8"
	}
	q := fmt.Sprintf("u=%s&t=%s", encodeParam(upstream.String()), encodeParam(p.token))
	if referer != "" {
		q += "&r=" + encodeParam(referer)
	}
	return fmt.Sprintf("http://127.0.0.1:%d/hls/%s?%s", p.port, kind, q)
}

func encodeParam(s string) string {
	return url.QueryEscape(s)
}

func (p *HLSProxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	if !p.ValidHost(r.Host) {
		w.WriteHeader(http.StatusForbidden)
		return
	}
	// Block cross-site requests from external browser tabs while allowing same-origin WebView2/MSE requests.
	if secSite := strings.ToLower(r.Header.Get("Sec-Fetch-Site")); secSite != "" && secSite != "same-origin" && secSite != "none" {
		w.WriteHeader(http.StatusForbidden)
		return
	}
	if origin := r.Header.Get("Origin"); origin != "" {
		ou, err := url.Parse(origin)
		if err != nil || !p.ValidHost(ou.Host) {
			w.WriteHeader(http.StatusForbidden)
			return
		}
	}

	query := r.URL.Query()
	if !p.ValidToken(query.Get("t")) {
		w.WriteHeader(http.StatusForbidden)
		return
	}
	source := query.Get("u")
	upstream, ok := netclient.ValidStreamURL(source)
	if !ok {
		w.WriteHeader(http.StatusForbidden)
		return
	}

	referer := query.Get("r")
	rangeHeader := strings.TrimSpace(r.Header.Get("Range"))

	resp, err := p.client.FetchBytes(r.Context(), upstream, referer, rangeHeader, netclient.MaxSegmentBytes)
	if err != nil {
		if errors.Is(err, r.Context().Err()) {
			return
		}
		w.WriteHeader(http.StatusBadGateway)
		return
	}

	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		writeHeaders(w, resp.StatusCode, "application/octet-stream", 0, "")
		return
	}

	trimmed := strings.TrimLeft(strings.TrimPrefix(string(resp.Data[:min(len(resp.Data), 64)]), "\xef\xbb\xbf"), " \t\r\n")
	if strings.HasPrefix(trimmed, "#EXTM3U") {
		if len(resp.Data) > netclient.MaxPlaylistBytes {
			w.WriteHeader(http.StatusBadGateway)
			return
		}
		playlistText := strings.TrimPrefix(string(resp.Data), "\xef\xbb\xbf")
		rewritten := []byte(p.Rewrite(playlistText, upstream, referer))
		writeHeaders(w, http.StatusOK, "application/vnd.apple.mpegurl", len(rewritten), "")
		if r.Method != http.MethodHead {
			_, _ = w.Write(rewritten)
		}
		return
	}

	contentType := resp.ContentType
	if strings.HasSuffix(strings.ToLower(r.URL.Path), ".ts") {
		contentType = "video/mp2t"
	} else if contentType == "" {
		contentType = "application/octet-stream"
	}

	if resp.StatusCode == http.StatusPartialContent {
		writeHeaders(w, http.StatusPartialContent, contentType, len(resp.Data), resp.ContentRange)
		if r.Method != http.MethodHead {
			_, _ = w.Write(resp.Data)
		}
		return
	}

	if rangeHeader != "" {
		sliced, start, end, ok := Slice(resp.Data, rangeHeader)
		if !ok {
			writeHeaders(w, http.StatusRequestedRangeNotSatisfiable, contentType, 0, fmt.Sprintf("bytes */%d", len(resp.Data)))
			return
		}
		contentRange := fmt.Sprintf("bytes %d-%d/%d", start, end, len(resp.Data))
		writeHeaders(w, http.StatusPartialContent, contentType, len(sliced), contentRange)
		if r.Method != http.MethodHead {
			_, _ = w.Write(sliced)
		}
		return
	}

	writeHeaders(w, http.StatusOK, contentType, len(resp.Data), "")
	if r.Method != http.MethodHead {
		_, _ = w.Write(resp.Data)
	}
}

func writeHeaders(w http.ResponseWriter, status int, contentType string, contentLen int, contentRange string) {
	safeType := strings.NewReplacer("\r", "", "\n", "").Replace(contentType)
	h := w.Header()
	h.Set("Content-Type", safeType)
	h.Set("Content-Length", strconv.Itoa(contentLen))
	h.Set("Accept-Ranges", "bytes")
	h.Set("Cache-Control", "no-store")
	h.Set("X-Content-Type-Options", "nosniff")
	if contentRange != "" {
		h.Set("Content-Range", contentRange)
	}
	w.WriteHeader(status)
}

func (p *HLSProxy) Rewrite(playlist string, base *url.URL, referer string) string {
	normalized := strings.ReplaceAll(playlist, "\r\n", "\n")
	lines := strings.Split(normalized, "\n")
	output := make([]string, 0, len(lines))
	nextIsVariant := false

	for _, raw := range lines {
		line := strings.TrimSpace(raw)
		if line == "" {
			output = append(output, raw)
			continue
		}
		if strings.HasPrefix(line, "#") {
			nextIsVariant = strings.HasPrefix(line, "#EXT-X-STREAM-INF")
			output = append(output, p.rewriteAttributeURI(line, base, referer))
			continue
		}
		abs := resolveMediaURL(line, base)
		if abs == nil {
			output = append(output, raw)
			continue
		}
		kind := "s." + segmentExtension(abs)
		if nextIsVariant {
			kind = "m.m3u8"
		}
		output = append(output, p.LocalURL(abs, referer, kind))
		nextIsVariant = false
	}
	return strings.Join(output, "\n")
}

func (p *HLSProxy) rewriteAttributeURI(tag string, base *url.URL, referer string) string {
	if !strings.Contains(tag, `URI="`) {
		return tag
	}
	indices := reAttributeURI.FindAllStringSubmatchIndex(tag, -1)
	if len(indices) == 0 {
		return tag
	}
	result := tag
	for i := len(indices) - 1; i >= 0; i-- {
		loc := indices[i]
		rawURI := tag[loc[2]:loc[3]]
		abs := resolveMediaURL(rawURI, base)
		if abs == nil {
			continue
		}
		var kind string
		switch {
		case strings.HasPrefix(tag, "#EXT-X-MEDIA") || strings.HasPrefix(tag, "#EXT-X-I-FRAME-STREAM-INF"):
			kind = "m.m3u8"
		case strings.HasPrefix(tag, "#EXT-X-KEY") || strings.HasPrefix(tag, "#EXT-X-SESSION-KEY"):
			kind = "k.key"
		case strings.HasPrefix(tag, "#EXT-X-MAP"):
			kind = "i.mp4"
		default:
			kind = "s." + segmentExtension(abs)
		}
		replacement := fmt.Sprintf(`URI="%s"`, p.LocalURL(abs, referer, kind))
		result = result[:loc[0]] + replacement + result[loc[1]:]
	}
	return result
}

func resolveMediaURL(raw string, base *url.URL) *url.URL {
	if base == nil || raw == "" {
		return nil
	}
	parsed, err := url.Parse(raw)
	if err != nil {
		return nil
	}
	// Reject explicit non-HTTP(S) schemes like javascript:alert(1)
	if parsed.Scheme != "" {
		s := strings.ToLower(parsed.Scheme)
		if s != "http" && s != "https" {
			return nil
		}
	}
	abs := base.ResolveReference(parsed)
	scheme := strings.ToLower(abs.Scheme)
	if (scheme != "http" && scheme != "https") || abs.Hostname() == "" || abs.User != nil {
		return nil
	}
	return abs
}

func segmentExtension(u *url.URL) string {
	ext := strings.TrimPrefix(strings.ToLower(path.Ext(u.Path)), ".")
	switch ext {
	case "m4s", "mp4", "aac", "m4a", "cmfv", "cmfa":
		return ext
	default:
		return "ts"
	}
}

func Slice(data []byte, rangeHeader string) ([]byte, int, int, bool) {
	if !strings.HasPrefix(rangeHeader, "bytes=") || strings.Contains(rangeHeader, ",") || len(data) == 0 {
		return nil, 0, 0, false
	}
	spec := strings.SplitN(strings.TrimPrefix(rangeHeader, "bytes="), "-", 2)
	if len(spec) != 2 {
		return nil, 0, 0, false
	}
	var start, end int
	if spec[0] == "" {
		length, err := strconv.Atoi(spec[1])
		if err != nil || length <= 0 {
			return nil, 0, 0, false
		}
		start = max(0, len(data)-length)
		end = len(data) - 1
	} else {
		first, err := strconv.Atoi(spec[0])
		if err != nil || first < 0 {
			return nil, 0, 0, false
		}
		start = first
		if spec[1] == "" {
			end = len(data) - 1
		} else {
			last, err := strconv.Atoi(spec[1])
			if err != nil {
				return nil, 0, 0, false
			}
			end = min(last, len(data)-1)
		}
	}
	if start > end || start >= len(data) || end < 0 {
		return nil, 0, 0, false
	}
	return data[start : end+1], start, end, true
}
