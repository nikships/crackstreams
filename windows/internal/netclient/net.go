package netclient

import (
	"bytes"
	"compress/gzip"
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"time"
)

const (
	UserAgent        = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
	MaxPlaylistBytes = 4 * 1024 * 1024
	MaxSegmentBytes  = 128 * 1024 * 1024
)

var (
	ErrResponseTooLarge = errors.New("the server returned an unexpectedly large response")
	ErrInvalidResponse  = errors.New("the server returned an invalid response")
)

type Response struct {
	Data         []byte
	StatusCode   int
	ContentType  string
	ContentRange string
}

type Client struct {
	httpClient *http.Client
}

func New() *Client {
	transport := &http.Transport{
		Proxy: http.ProxyFromEnvironment,
		DialContext: (&net.Dialer{
			Timeout:   10 * time.Second,
			KeepAlive: 30 * time.Second,
		}).DialContext,
		ForceAttemptHTTP2:     true,
		MaxIdleConns:          64,
		MaxIdleConnsPerHost:   12,
		MaxConnsPerHost:       16,
		IdleConnTimeout:       60 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ResponseHeaderTimeout: 20 * time.Second,
		ExpectContinueTimeout: 1 * time.Second,
	}
	return &Client{
		httpClient: &http.Client{
			Transport: transport,
			Timeout:   45 * time.Second,
		},
	}
}

func NewWithHTTPClient(hc *http.Client) *Client {
	return &Client{httpClient: hc}
}

var Default = New()

func (c *Client) FetchBytes(ctx context.Context, target *url.URL, referer string, rangeHeader string, maxBytes int64) (*Response, error) {
	if target == nil {
		return nil, ErrInvalidResponse
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, target.String(), nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", UserAgent)
	req.Header.Set("Accept-Encoding", "identity")
	if referer != "" {
		req.Header.Set("Referer", referer)
	}
	if rangeHeader != "" {
		req.Header.Set("Range", rangeHeader)
	}

	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	if resp.ContentLength > maxBytes {
		return nil, ErrResponseTooLarge
	}

	var reader io.Reader = resp.Body
	// Some CDNs send gzip even when Accept-Encoding: identity was requested on non-range responses.
	if rangeHeader == "" && strings.EqualFold(strings.TrimSpace(resp.Header.Get("Content-Encoding")), "gzip") {
		gz, err := gzip.NewReader(resp.Body)
		if err == nil {
			defer gz.Close()
			reader = gz
		}
	}

	limited := io.LimitReader(reader, maxBytes+1)
	data, err := io.ReadAll(limited)
	if err != nil {
		return nil, err
	}
	if int64(len(data)) > maxBytes {
		return nil, ErrResponseTooLarge
	}

	// Transparently gunzip if upstream omitted Content-Encoding header on gzipped playlist/HTML.
	if rangeHeader == "" && resp.StatusCode == http.StatusOK && len(data) >= 2 && data[0] == 0x1f && data[1] == 0x8b {
		if gz, err := gzip.NewReader(bytes.NewReader(data)); err == nil {
			if unzipped, err := io.ReadAll(io.LimitReader(gz, maxBytes+1)); err == nil {
				_ = gz.Close()
				if int64(len(unzipped)) > maxBytes {
					return nil, ErrResponseTooLarge
				}
				data = unzipped
			} else {
				_ = gz.Close()
			}
		}
	}

	return &Response{
		Data:         data,
		StatusCode:   resp.StatusCode,
		ContentType:  resp.Header.Get("Content-Type"),
		ContentRange: resp.Header.Get("Content-Range"),
	}, nil
}

func (c *Client) FetchText(ctx context.Context, target *url.URL, referer string) (string, int, error) {
	ctx, cancel := context.WithTimeout(ctx, 22*time.Second)
	defer cancel()
	resp, err := c.FetchBytes(ctx, target, referer, "", MaxPlaylistBytes)
	if err != nil {
		return "", 0, err
	}
	return string(resp.Data), resp.StatusCode, nil
}

func Origin(u *url.URL) string {
	if u == nil {
		return ""
	}
	scheme := strings.ToLower(u.Scheme)
	if (scheme != "http" && scheme != "https") || u.Hostname() == "" {
		return ""
	}
	return fmt.Sprintf("%s://%s/", scheme, u.Host)
}

func ValidStreamURL(raw string) (*url.URL, bool) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return nil, false
	}
	u, err := url.Parse(trimmed)
	if err != nil {
		return nil, false
	}
	scheme := strings.ToLower(u.Scheme)
	if (scheme != "http" && scheme != "https") || u.Hostname() == "" || u.User != nil {
		return nil, false
	}
	return u, true
}
