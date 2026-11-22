package resolver

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"path"
	"regexp"
	"strings"
	"unicode"

	"github.com/nikships/crackstreams/windows/internal/netclient"
)

type ResolvedStream struct {
	Playlist   *url.URL
	Referer    string
	Title      string
	EmbedIndex int
	EmbedCount int
}

var (
	ErrNoEmbeds        = errors.New("No stream player was found on that page.")
	ErrNoPlaylist      = errors.New("The stream is not live yet, or every listed feed is unavailable.")
	ErrResponseTooBig  = errors.New("The server returned an unexpectedly large response.")
	ErrInvalidResponse = errors.New("The server returned an invalid response.")
)

var (
	reAllStreams     = regexp.MustCompile(`(?s)(?:const|let|var)\s+allStreams\s*=\s*(\[.*?\])\s*;`)
	reIframeSrc      = regexp.MustCompile(`(?is)<iframe[^>]*\ssrc=["']([^"']+)["']`)
	reDirectStream   = regexp.MustCompile(`(?s)DIRECT_STREAM_URL\s*=\s*["']([^"']+)["']`)
	reM3U8Plain      = regexp.MustCompile(`(https?://[^"'\s\\]+\.m3u8[^"'\s\\]*)`)
	reM3U8Escaped    = regexp.MustCompile(`(https?:\\/\\/[^"'\s]+\.m3u8[^"'\s]*)`)
	skippedHostParts = []string{"chatango", "histats", "dtscout", "google", "doubleclick", "cloudflare"}
)

type Resolver struct {
	client *netclient.Client
}

func New(client *netclient.Client) *Resolver {
	if client == nil {
		client = netclient.Default
	}
	return &Resolver{client: client}
}

var Default = New(nil)

// Resolve extracts a playable HLS playlist and required Referer from a watch page or direct .m3u8 URL.
// startOffset lets callers cycle through backup feeds when multiple embeds exist.
func (r *Resolver) Resolve(ctx context.Context, input *url.URL, startOffset int) (*ResolvedStream, error) {
	if input == nil {
		return nil, ErrInvalidResponse
	}
	title := PrettyTitle(input)

	if strings.HasSuffix(strings.ToLower(input.Path), ".m3u8") {
		referer := netclient.Origin(input)
		ok, err := r.isPlaylist(ctx, input, referer)
		if err != nil {
			if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
				return nil, err
			}
			return nil, ErrNoPlaylist
		}
		if ok {
			return &ResolvedStream{
				Playlist:   input,
				Referer:    referer,
				Title:      title,
				EmbedIndex: 0,
				EmbedCount: 1,
			}, nil
		}
		return nil, ErrNoPlaylist
	}

	page, code, err := r.client.FetchText(ctx, input, "")
	if err != nil {
		if errors.Is(err, context.Canceled) {
			return nil, err
		}
		if errors.Is(err, netclient.ErrResponseTooLarge) {
			return nil, ErrResponseTooBig
		}
		return nil, fmt.Errorf("Could not load the page (%v).", err)
	}
	if code < 200 || code >= 300 {
		return nil, fmt.Errorf("Could not load the page (HTTP %d).", code)
	}

	embeds := EmbedURLs(page, input)
	if len(embeds) == 0 {
		return nil, ErrNoEmbeds
	}
	if len(embeds) > 8 {
		embeds = embeds[:8]
	}

	count := len(embeds)
	if startOffset < 0 {
		startOffset = 0
	}
	watchOrigin := netclient.Origin(input)

	for step := 0; step < count; step++ {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		idx := (startOffset + step) % count
		embed := embeds[idx]
		origin := netclient.Origin(embed)
		if origin == "" {
			continue
		}

		// Some embeds only expose DIRECT_STREAM_URL when Referer is the watch site, not their own origin.
		// The playlist itself still needs the embed's origin.
		embedReferers := []string{origin}
		if watchOrigin != "" && watchOrigin != origin {
			embedReferers = append(embedReferers, watchOrigin)
		}

		for _, embedReferer := range embedReferers {
			if err := ctx.Err(); err != nil {
				return nil, err
			}
			html, status, err := r.client.FetchText(ctx, embed, embedReferer)
			if err != nil || status < 200 || status >= 300 {
				continue
			}
			candidate := PlaylistURL(html, embed)
			if candidate == nil {
				continue
			}
			if ok, _ := r.isPlaylist(ctx, candidate, origin); ok {
				return &ResolvedStream{
					Playlist:   candidate,
					Referer:    origin,
					Title:      title,
					EmbedIndex: idx,
					EmbedCount: count,
				}, nil
			}
		}
	}

	return nil, ErrNoPlaylist
}

func (r *Resolver) isPlaylist(ctx context.Context, u *url.URL, referer string) (bool, error) {
	body, code, err := r.client.FetchText(ctx, u, referer)
	if err != nil {
		return false, err
	}
	trimmed := strings.TrimLeft(strings.TrimPrefix(body, "\xef\xbb\xbf"), " \t\r\n")
	return code >= 200 && code < 300 && strings.HasPrefix(trimmed, "#EXTM3U"), nil
}

func EmbedURLs(html string, base *url.URL) []*url.URL {
	if base == nil {
		return nil
	}
	var urls []*url.URL

	if m := reAllStreams.FindStringSubmatch(html); len(m) >= 2 {
		var items []map[string]any
		if err := json.Unmarshal([]byte(m[1]), &items); err == nil {
			for _, item := range items {
				if val, ok := item["value"].(string); ok {
					if u := streamURL(val, base); u != nil {
						urls = append(urls, u)
					}
				}
			}
		}
	}
	if len(urls) > 0 {
		return urls
	}

	for _, m := range reIframeSrc.FindAllStringSubmatch(html, -1) {
		if len(m) < 2 {
			continue
		}
		u := streamURL(m[1], base)
		if u == nil {
			continue
		}
		hostLower := strings.ToLower(u.Hostname())
		skip := false
		for _, part := range skippedHostParts {
			if strings.Contains(hostLower, part) {
				skip = true
				break
			}
		}
		if !skip {
			urls = append(urls, u)
		}
	}
	return urls
}

func PlaylistURL(html string, base *url.URL) *url.URL {
	if base == nil {
		return nil
	}
	if m := reDirectStream.FindStringSubmatch(html); len(m) >= 2 {
		return streamURL(m[1], base)
	}
	if m := reM3U8Plain.FindStringSubmatch(html); len(m) >= 2 {
		return streamURL(m[1], base)
	}
	if m := reM3U8Escaped.FindStringSubmatch(html); len(m) >= 2 {
		return streamURL(m[1], base)
	}
	return nil
}

func streamURL(source string, base *url.URL) *url.URL {
	cleaned := strings.ReplaceAll(source, `\/`, `/`)
	cleaned = strings.ReplaceAll(cleaned, "&amp;", "&")
	cleaned = strings.TrimSpace(cleaned)
	if cleaned == "" {
		return nil
	}
	parsed, err := url.Parse(cleaned)
	if err != nil {
		return nil
	}
	resolved := base.ResolveReference(parsed)
	scheme := strings.ToLower(resolved.Scheme)
	if (scheme != "http" && scheme != "https") || resolved.Hostname() == "" || resolved.User != nil {
		return nil
	}
	return resolved
}

func PrettyTitle(u *url.URL) string {
	if u == nil {
		return "Stream"
	}
	trimmedPath := strings.TrimSuffix(u.Path, "/")
	base := path.Base(trimmedPath)
	if base == "." || base == "/" || base == "" {
		if u.Hostname() != "" {
			return u.Hostname()
		}
		return "Stream"
	}
	if ext := path.Ext(base); ext != "" {
		base = strings.TrimSuffix(base, ext)
	}
	rawWords := strings.FieldsFunc(base, func(r rune) bool {
		return r == '-' || r == '_'
	})
	if len(rawWords) == 0 {
		if u.Hostname() != "" {
			return u.Hostname()
		}
		return "Stream"
	}
	words := make([]string, 0, len(rawWords))
	for _, w := range rawWords {
		if strings.EqualFold(w, "vs") {
			words = append(words, "vs")
			continue
		}
		runes := []rune(w)
		runes[0] = unicode.ToUpper(runes[0])
		words = append(words, string(runes))
	}
	return strings.Join(words, " ")
}
