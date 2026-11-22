package directory_test

import (
	"net/url"
	"testing"
	"time"

	"github.com/nikships/crackstreams/windows/internal/directory"
)

func mustURL(t *testing.T, raw string) *url.URL {
	t.Helper()
	u, err := url.Parse(raw)
	if err != nil {
		t.Fatalf("parse %q: %v", raw, err)
	}
	return u
}

func TestParsesLeagueCardsAndSkipsExternalAndCommentedLinks(t *testing.T) {
	home := mustURL(t, "https://watch.example/")
	html := `
	<nav>
	  <!-- <a href="/category/ufc"> UFC </a> -->
	  <a href="/league/nflstreams">NFL</a>
	  <a href="/league/nbaregular66">NBA</a>
	  <a href="/league/wwestreams">WWE</a>
	  <a href="https://partner.example/">Partner</a>
	</nav>
	<a class="card" href="/league/nflstreams">
	  <div class="card-left"><img src="https://cdn.example/nfl.png" alt="NFL logo">
	    <div class="card-content"><div class="card-title">NFL Streams</div>
	    <div class="card-subtitle">Click to view all games</div></div></div>
	</a>
	<a class="card" href="/league/nbastreams">
	  <div class="card-title">NBA Streams</div>
	</a>
	<a class="card" href="https://footy.example/"><div class="card-title">Soccer Streams</div></a>
	<a class="card" href="https://www.watch.example/league/f1streams"><div class="card-title">F1 &amp; Racing Streams</div></a>`

	leagues := directory.ParseLeagues(html, home)
	wantNames := []string{"NFL", "NBA", "F1 & Racing", "WWE"}
	if len(leagues) != len(wantNames) {
		t.Fatalf("expected %d leagues, got %d: %+v", len(wantNames), len(leagues), leagues)
	}
	for i, name := range wantNames {
		if leagues[i].Name != name {
			t.Fatalf("league[%d] = %q, want %q", i, leagues[i].Name, name)
		}
	}
	if leagues[0].URL != "https://watch.example/league/nflstreams" {
		t.Fatalf("unexpected NFL URL: %s", leagues[0].URL)
	}
	if leagues[0].Logo != "https://cdn.example/nfl.png" {
		t.Fatalf("unexpected NFL logo: %s", leagues[0].Logo)
	}
	if leagues[1].URL != "https://watch.example/league/nbastreams" {
		t.Fatalf("expected card URL to win over nav link, got %s", leagues[1].URL)
	}
	if leagues[3].Logo != "" {
		t.Fatalf("expected empty logo for WWE, got %s", leagues[3].Logo)
	}
}

func TestParsesGameCardsWithDayHeadings(t *testing.T) {
	html := `
	<h1><a href="/">NBA Streams</a> and Schedule</h1>
	<h2>Sunday, November 1, 2026</h2>  <a class="card" href="/stream/nba-24-7-live-stream">
	  <div class="card-title">NBA 24/7 Live Stream</div>
	  <div class="card-subtitle">
	    Start time: 12:00 PM ET
	  </div>
	</a>
	<h2>Wednesday, November 11, 2026</h2>  <a class="card" href="/stream/toronto-raptors-vs-boston-celtics">
	  <div class="card-title">Toronto Raptors vs Boston Celtics</div>
	  <div class="card-subtitle">Start time: 7:00 PM ET</div>
	</a>
	<a class="card" href="/stream/o&#039;neil-vs-smith"><div class="card-title">O&#039;Neil vs Smith</div></a>
	<a class="card" href="/stream/toronto-raptors-vs-boston-celtics"><div class="card-title">Duplicate</div></a>
	<a class="card" href="https://ads.example/stream/game"><div class="card-title">Ad</div></a>
	<footer><a href="/stream/nfl-redzone">crackstreams Redzone</a></footer>`

	events := directory.ParseEvents(html, mustURL(t, "https://watch.example/league/nbastreams"), time.Unix(1_700_000_000, 0))
	wantTitles := []string{"NBA 24/7 Live Stream", "Toronto Raptors vs Boston Celtics", "O'Neil vs Smith"}
	if len(events) != len(wantTitles) {
		t.Fatalf("expected %d events, got %d: %+v", len(wantTitles), len(events), events)
	}
	for i, want := range wantTitles {
		if events[i].Title != want {
			t.Fatalf("event[%d].Title = %q, want %q", i, events[i].Title, want)
		}
	}
	if events[1].StartText != "7:00 PM ET" {
		t.Fatalf("unexpected startText: %q", events[1].StartText)
	}
	// 7:00 PM EST on Nov 11, 2026 is 2026-11-12 00:00:00 UTC.
	wantUTC := time.Date(2026, 11, 12, 0, 0, 0, 0, time.UTC).Unix()
	if events[1].StartUnix == nil || *events[1].StartUnix != wantUTC {
		t.Fatalf("unexpected StartUnix: %v (want %d)", events[1].StartUnix, wantUTC)
	}
	if events[2].StartUnix != nil {
		t.Fatalf("expected nil StartUnix for unscheduled event")
	}
}

func TestParsesTimeZonesAndStatusWindows(t *testing.T) {
	pacific := directory.StartDate("Saturday, July 4, 2026", "5:30 PM PT")
	utc := directory.StartDate("Saturday, July 4, 2026", "12:30 AM UTC")
	if pacific == nil || pacific.Unix() != 1_783_211_400 {
		t.Fatalf("unexpected pacific unix: %v", pacific)
	}
	if utc == nil || utc.Unix() != 1_783_125_000 {
		t.Fatalf("unexpected utc unix: %v", utc)
	}
	if directory.StartDate("What can I watch here?", "7:00 PM ET") != nil {
		t.Fatal("expected nil for invalid day")
	}
	if directory.StartDate("Saturday, July 4, 2026", "TBA") != nil {
		t.Fatal("expected nil for TBA")
	}

	start := int64(1_000_000)
	startTime := time.Unix(start, 0)
	ev := directory.Event{Title: "A vs B", StartUnix: &start}
	if got := ev.StatusAt(startTime.Add(-2 * time.Hour)); got != directory.StatusUpcoming {
		t.Fatalf("expected upcoming, got %s", got)
	}
	if got := ev.StatusAt(startTime.Add(-30 * time.Minute)); got != directory.StatusStartingSoon {
		t.Fatalf("expected startingSoon, got %s", got)
	}
	if got := ev.StatusAt(startTime); got != directory.StatusLive {
		t.Fatalf("expected live, got %s", got)
	}
	if got := ev.StatusAt(startTime.Add(3 * time.Hour)); got != directory.StatusLive {
		t.Fatalf("expected live at +3h, got %s", got)
	}
	if got := ev.StatusAt(startTime.Add(5 * time.Hour)); got != directory.StatusEarlier {
		t.Fatalf("expected earlier at +5h, got %s", got)
	}

	ch := directory.Event{Title: "NFL Network", StartUnix: &start}
	if got := ch.StatusAt(startTime.Add(90 * 24 * time.Hour)); got != directory.StatusChannel {
		t.Fatalf("expected channel, got %s", got)
	}
}
