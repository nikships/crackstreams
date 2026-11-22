package directory

import (
	"context"
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
	_ "time/tzdata"

	"github.com/nikships/crackstreams/windows/internal/netclient"
)

const (
	DefaultHomeURL      = "https://crackstreams.mx/"
	LiveWindow          = 4 * time.Hour
	LinkLeadTime        = 1 * time.Hour
	EventCacheLifetime  = 2 * time.Minute
	LeagueCacheLifetime = 30 * time.Minute
)

var ErrNoLeagues = errors.New("No sports were listed on the stream site.")

type League struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	URL  string `json:"url"`
	Logo string `json:"logo,omitempty"`
}

type EventStatus string

const (
	StatusLive         EventStatus = "live"
	StatusStartingSoon EventStatus = "startingSoon"
	StatusUpcoming     EventStatus = "upcoming"
	StatusEarlier      EventStatus = "earlier"
	StatusChannel      EventStatus = "channel"
	StatusUnscheduled  EventStatus = "unscheduled"
)

type Event struct {
	ID        string      `json:"id"`
	Title     string      `json:"title"`
	URL       string      `json:"url"`
	Day       string      `json:"day,omitempty"`
	StartText string      `json:"startText,omitempty"`
	StartUnix *int64      `json:"startUnix,omitempty"`
	Status    EventStatus `json:"status"`
}

func (e Event) StatusAt(now time.Time) EventStatus {
	lowered := strings.ToLower(e.Title)
	if strings.Contains(lowered, "24/7") || strings.HasSuffix(lowered, " network") {
		return StatusChannel
	}
	if e.StartUnix == nil {
		return StatusUnscheduled
	}
	start := time.Unix(*e.StartUnix, 0)
	if !now.Before(start) {
		if now.Before(start.Add(LiveWindow)) {
			return StatusLive
		}
		return StatusEarlier
	}
	if start.Sub(now) <= LinkLeadTime {
		return StatusStartingSoon
	}
	return StatusUpcoming
}

var (
	reComment       = regexp.MustCompile(`(?s)<!--.*?-->`)
	reTags          = regexp.MustCompile(`(?s)<[^>]+>`)
	reSpaces        = regexp.MustCompile(`\s+`)
	reAnchor        = regexp.MustCompile(`(?is)<a\b([^>]*)>(.*?)</a>`)
	reHeadingOrLink = regexp.MustCompile(`(?is)<h2\b[^>]*>(.*?)</h2>|<a\b([^>]*)>(.*?)</a>`)
	reHref          = regexp.MustCompile(`(?is)\bhref\s*=\s*["']([^"']+)["']`)
	reClass         = regexp.MustCompile(`(?is)\bclass\s*=\s*["']([^"']*)["']`)
	reCardTitle     = regexp.MustCompile(`(?is)class\s*=\s*["']card-title["'][^>]*>(.*?)</div>`)
	reCardSubtitle  = regexp.MustCompile(`(?is)class\s*=\s*["']card-subtitle["'][^>]*>(.*?)</div>`)
	reImgSrc        = regexp.MustCompile(`(?is)<img\b[^>]*\bsrc\s*=\s*["']([^"']+)["']`)
	reStartPrefix   = regexp.MustCompile(`(?i)^\s*start\s*time\s*:\s*`)
	reStreamsSuffix = regexp.MustCompile(`(?i)\s+streams?$`)
	reNumericEntity = regexp.MustCompile(`(?i)&#(x?[0-9a-f]+);`)
)

var namedZones = map[string]string{
	"ET":  "America/New_York",
	"EST": "America/New_York",
	"EDT": "America/New_York",
	"CT":  "America/Chicago",
	"CST": "America/Chicago",
	"CDT": "America/Chicago",
	"MT":  "America/Denver",
	"MST": "America/Denver",
	"MDT": "America/Denver",
	"PT":  "America/Los_Angeles",
	"PST": "America/Los_Angeles",
	"PDT": "America/Los_Angeles",
	"UTC": "UTC",
	"GMT": "GMT",
}

func ParseLeagues(html string, base *url.URL) []League {
	if base == nil {
		return nil
	}
	cleaned := reComment.ReplaceAllString(html, "")
	matches := reAnchor.FindAllStringSubmatch(cleaned, -1)

	var cards []League
	var links []League
	for _, m := range matches {
		a, ok := parseAnchor(m[1], m[2])
		if !ok {
			continue
		}
		u := siteURL(a.href, base, "/league/")
		if u == nil {
			continue
		}
		rawName := a.text
		if a.title != "" {
			rawName = a.title
		}
		name := cleanLeagueName(rawName)
		if name == "" {
			continue
		}
		var logo string
		if a.image != "" {
			if lu := webURL(a.image, base); lu != nil {
				logo = lu.String()
			}
		}
		league := League{
			ID:   u.String(),
			Name: name,
			URL:  u.String(),
			Logo: logo,
		}
		if a.isCard {
			cards = append(cards, league)
		} else {
			links = append(links, league)
		}
	}

	seenNames := make(map[string]bool)
	seenURLs := make(map[string]bool)
	combined := append(cards, links...)
	result := make([]League, 0, len(combined))
	for _, l := range combined {
		keyName := strings.ToLower(l.Name)
		if seenNames[keyName] || seenURLs[l.URL] {
			continue
		}
		seenNames[keyName] = true
		seenURLs[l.URL] = true
		result = append(result, l)
	}
	return result
}

func ParseEvents(html string, base *url.URL, now time.Time) []Event {
	if base == nil {
		return nil
	}
	cleaned := reComment.ReplaceAllString(html, "")
	matches := reHeadingOrLink.FindAllStringSubmatch(cleaned, -1)

	var day string
	seen := make(map[string]bool)
	var events []Event

	for _, m := range matches {
		// Group 1 is <h2> inner HTML when matched; check whether group 2/3 matched <a>.
		if strings.HasPrefix(strings.ToLower(strings.TrimSpace(m[0])), "<h2") {
			day = plainText(m[1])
			continue
		}
		a, ok := parseAnchor(m[2], m[3])
		if !ok || !a.isCard {
			continue
		}
		u := siteURL(a.href, base, "/stream/")
		if u == nil {
			continue
		}
		urlStr := u.String()
		if seen[urlStr] {
			continue
		}
		seen[urlStr] = true

		title := a.title
		if title == "" {
			title = a.text
		}
		if title == "" {
			continue
		}

		startText := strings.TrimSpace(reStartPrefix.ReplaceAllString(a.subtitle, ""))
		var startUnix *int64
		if t := StartDate(day, startText); t != nil {
			unix := t.Unix()
			startUnix = &unix
		}

		ev := Event{
			ID:        urlStr,
			Title:     title,
			URL:       urlStr,
			Day:       day,
			StartText: startText,
			StartUnix: startUnix,
		}
		ev.Status = ev.StatusAt(now)
		events = append(events, ev)
	}
	return events
}

func StartDate(day string, timeStr string) *time.Time {
	day = strings.TrimSpace(day)
	parts := strings.Fields(timeStr)
	if day == "" || len(parts) == 0 {
		return nil
	}
	loc, err := time.LoadLocation("America/New_York")
	if err != nil {
		loc = time.FixedZone("EST", -5*3600)
	}
	last := strings.ToUpper(parts[len(parts)-1])
	if zoneID, ok := namedZones[last]; ok {
		if namedLoc, err := time.LoadLocation(zoneID); err == nil {
			loc = namedLoc
			parts = parts[:len(parts)-1]
		}
	}
	if len(parts) == 0 {
		return nil
	}
	combined := day + " " + strings.Join(parts, " ")
	parsed, err := time.ParseInLocation("Monday, January 2, 2006 3:04 PM", combined, loc)
	if err != nil {
		return nil
	}
	utc := parsed.UTC()
	return &utc
}

type anchor struct {
	href     string
	isCard   bool
	title    string
	subtitle string
	image    string
	text     string
}

func parseAnchor(attrs, inner string) (anchor, bool) {
	hrefMatch := reHref.FindStringSubmatch(attrs)
	if len(hrefMatch) < 2 {
		return anchor{}, false
	}
	var isCard bool
	if classMatch := reClass.FindStringSubmatch(attrs); len(classMatch) >= 2 {
		for _, tok := range strings.Fields(classMatch[1]) {
			if tok == "card" {
				isCard = true
				break
			}
		}
	}
	var title string
	if tm := reCardTitle.FindStringSubmatch(inner); len(tm) >= 2 {
		title = plainText(tm[1])
	}
	var subtitle string
	if sm := reCardSubtitle.FindStringSubmatch(inner); len(sm) >= 2 {
		subtitle = plainText(sm[1])
	}
	var image string
	if im := reImgSrc.FindStringSubmatch(inner); len(im) >= 2 {
		image = im[1]
	}
	return anchor{
		href:     hrefMatch[1],
		isCard:   isCard,
		title:    title,
		subtitle: subtitle,
		image:    image,
		text:     plainText(inner),
	}, true
}

func cleanLeagueName(text string) string {
	return strings.TrimSpace(reStreamsSuffix.ReplaceAllString(text, ""))
}

func siteURL(href string, base *url.URL, fragment string) *url.URL {
	u := webURL(href, base)
	if u == nil {
		return nil
	}
	if siteHost(u) != siteHost(base) {
		return nil
	}
	if !strings.Contains(strings.ToLower(u.Path), fragment) {
		return nil
	}
	return u
}

func webURL(raw string, base *url.URL) *url.URL {
	cleaned := strings.TrimSpace(decodeEntities(raw))
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

func siteHost(u *url.URL) string {
	h := strings.ToLower(u.Hostname())
	return strings.TrimPrefix(h, "www.")
}

func plainText(html string) string {
	stripped := reTags.ReplaceAllString(html, " ")
	decoded := decodeEntities(stripped)
	return strings.TrimSpace(reSpaces.ReplaceAllString(decoded, " "))
}

func decodeEntities(text string) string {
	if !strings.Contains(text, "&") {
		return text
	}
	replacer := strings.NewReplacer(
		"&quot;", `"`,
		"&apos;", `'`,
		"&lt;", "<",
		"&gt;", ">",
		"&nbsp;", " ",
	)
	res := replacer.Replace(text)
	res = reNumericEntity.ReplaceAllStringFunc(res, func(entity string) string {
		sub := reNumericEntity.FindStringSubmatch(entity)
		if len(sub) < 2 {
			return entity
		}
		code := sub[1]
		var val uint64
		var err error
		if strings.HasPrefix(strings.ToLower(code), "x") {
			val, err = strconv.ParseUint(code[1:], 16, 32)
		} else {
			val, err = strconv.ParseUint(code, 10, 32)
		}
		if err != nil || val == 0 || val > 0x10FFFF {
			return entity
		}
		return string(rune(val))
	})
	return strings.ReplaceAll(res, "&amp;", "&")
}

// Service fetches and caches directory listings.
type Service struct {
	client *netclient.Client
	home   *url.URL

	mu            sync.Mutex
	leagues       []League
	leaguesAt     time.Time
	eventsByURL   map[string]cachedEvents
}

type cachedEvents struct {
	loadedAt time.Time
	events   []Event
}

func NewService(client *netclient.Client, homeURL string) *Service {
	if client == nil {
		client = netclient.Default
	}
	u, err := url.Parse(homeURL)
	if err != nil || u.Scheme == "" {
		u, _ = url.Parse(DefaultHomeURL)
	}
	return &Service{
		client:      client,
		home:        u,
		eventsByURL: make(map[string]cachedEvents),
	}
}

func (s *Service) HomeHost() string {
	return s.home.Hostname()
}

func (s *Service) Leagues(ctx context.Context, force bool) ([]League, error) {
	s.mu.Lock()
	if !force && len(s.leagues) > 0 && time.Since(s.leaguesAt) < LeagueCacheLifetime {
		cached := append([]League(nil), s.leagues...)
		s.mu.Unlock()
		return cached, nil
	}
	stale := append([]League(nil), s.leagues...)
	s.mu.Unlock()

	body, err := s.fetchPage(ctx, s.home)
	if err != nil {
		if len(stale) > 0 && !force {
			return stale, nil
		}
		return nil, err
	}
	parsed := ParseLeagues(body, s.home)
	if len(parsed) == 0 {
		return nil, ErrNoLeagues
	}

	s.mu.Lock()
	s.leagues = parsed
	s.leaguesAt = time.Now()
	s.mu.Unlock()
	return append([]League(nil), parsed...), nil
}

func (s *Service) Events(ctx context.Context, leagueURL string, force bool) ([]Event, string, error) {
	u, ok := netclient.ValidStreamURL(leagueURL)
	if !ok || siteHost(u) != siteHost(s.home) || !strings.Contains(strings.ToLower(u.Path), "/league/") {
		return nil, "", errors.New("Invalid league URL.")
	}
	key := u.String()
	now := time.Now()

	s.mu.Lock()
	entry, hasCache := s.eventsByURL[key]
	s.mu.Unlock()

	if !force && hasCache && now.Sub(entry.loadedAt) < EventCacheLifetime {
		return refreshStatuses(entry.events, now), "", nil
	}

	body, err := s.fetchPage(ctx, u)
	if err != nil {
		if hasCache && len(entry.events) > 0 {
			return refreshStatuses(entry.events, now), fmt.Sprintf("Showing earlier listings. %s", err.Error()), nil
		}
		return nil, "", err
	}

	events := ParseEvents(body, u, now)
	s.mu.Lock()
	s.eventsByURL[key] = cachedEvents{loadedAt: now, events: events}
	s.mu.Unlock()
	return events, "", nil
}

func refreshStatuses(events []Event, now time.Time) []Event {
	out := make([]Event, len(events))
	for i, ev := range events {
		ev.Status = ev.StatusAt(now)
		out[i] = ev
	}
	return out
}

func (s *Service) fetchPage(ctx context.Context, u *url.URL) (string, error) {
	body, code, err := s.client.FetchText(ctx, u, "")
	if err != nil {
		if errors.Is(err, netclient.ErrResponseTooLarge) {
			return "", errors.New("The server returned an unexpectedly large response.")
		}
		return "", fmt.Errorf("Could not load the page (%v).", err)
	}
	if code < 200 || code >= 300 {
		return "", fmt.Errorf("Could not load the page (HTTP %d).", code)
	}
	return body, nil
}
