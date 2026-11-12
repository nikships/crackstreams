import XCTest
@testable import Crackstreams

final class StreamDirectoryTests: XCTestCase {
    private let home = URL(string: "https://watch.example/")!

    func testParsesLeagueCardsAndSkipsExternalAndCommentedLinks() {
        let html = #"""
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
        <a class="card" href="https://www.watch.example/league/f1streams"><div class="card-title">F1 &amp; Racing Streams</div></a>
        """#
        let leagues = StreamDirectory.parseLeagues(html, base: home)
        XCTAssertEqual(leagues.map(\.name), ["NFL", "NBA", "F1 & Racing", "WWE"])
        XCTAssertEqual(leagues[0].url.absoluteString, "https://watch.example/league/nflstreams")
        XCTAssertEqual(leagues[0].logo?.absoluteString, "https://cdn.example/nfl.png")
        XCTAssertEqual(leagues[1].url.path, "/league/nbastreams")
        XCTAssertNil(leagues[3].logo)
    }

    func testParsesGameCardsWithDayHeadings() {
        let html = #"""
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
        <footer><a href="/stream/nfl-redzone">crackstreams Redzone</a></footer>
        """#
        let events = StreamDirectory.parseEvents(html, base: URL(string: "https://watch.example/league/nbastreams")!)
        XCTAssertEqual(events.map(\.title), ["NBA 24/7 Live Stream", "Toronto Raptors vs Boston Celtics", "O'Neil vs Smith"])
        XCTAssertEqual(events.map(\.day), ["Sunday, November 1, 2026", "Wednesday, November 11, 2026", "Wednesday, November 11, 2026"])
        XCTAssertEqual(events[1].url.absoluteString, "https://watch.example/stream/toronto-raptors-vs-boston-celtics")
        XCTAssertEqual(events[1].startText, "7:00 PM ET")
        XCTAssertNil(events[2].startText)
        XCTAssertNil(events[2].start)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        // 7:00 PM EST is midnight UTC the next day.
        XCTAssertEqual(events[1].start, calendar.date(from: DateComponents(year: 2026, month: 11, day: 12, hour: 0)))
    }

    func testParsesOtherTimeZonesAndRejectsUnparseableTimes() {
        let pacific = StreamDirectory.startDate(day: "Saturday, July 4, 2026", time: "5:30 PM PT")
        let utc = StreamDirectory.startDate(day: "Saturday, July 4, 2026", time: "12:30 AM UTC")
        XCTAssertEqual(pacific?.timeIntervalSince1970, 1_783_211_400)
        XCTAssertEqual(utc?.timeIntervalSince1970, 1_783_125_000)
        XCTAssertNil(StreamDirectory.startDate(day: "What can I watch here?", time: "7:00 PM ET"))
        XCTAssertNil(StreamDirectory.startDate(day: "Saturday, July 4, 2026", time: "TBA"))
    }

    func testStatusWindows() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let game = DirectoryEvent(title: "A vs B", url: home, day: nil, startText: nil, start: start)
        XCTAssertEqual(game.status(at: start.addingTimeInterval(-2 * 3600)), .upcoming)
        XCTAssertEqual(game.status(at: start.addingTimeInterval(-30 * 60)), .startingSoon)
        XCTAssertEqual(game.status(at: start), .live)
        XCTAssertEqual(game.status(at: start.addingTimeInterval(3 * 3600)), .live)
        XCTAssertEqual(game.status(at: start.addingTimeInterval(5 * 3600)), .earlier)

        let channel = DirectoryEvent(title: "NFL Network", url: home, day: nil, startText: nil, start: start)
        XCTAssertEqual(channel.status(at: start.addingTimeInterval(90 * 86_400)), .channel)
        let unscheduled = DirectoryEvent(title: "A vs B", url: home, day: nil, startText: "TBA", start: nil)
        XCTAssertEqual(unscheduled.status(), .unscheduled)
    }
}

@MainActor
final class StreamBrowserTests: XCTestCase {
    private let nfl = DirectoryLeague(name: "NFL", url: URL(string: "https://watch.example/league/nfl")!, logo: nil)
    private let nba = DirectoryLeague(name: "NBA", url: URL(string: "https://watch.example/league/nba")!, logo: nil)

    private func game(_ slug: String) -> DirectoryEvent {
        DirectoryEvent(title: slug, url: URL(string: "https://watch.example/stream/\(slug)")!,
                       day: nil, startText: nil, start: nil)
    }

    private func waitUntil(_ condition: @autoclosure () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    func testSelectsFirstLeagueAndLoadsItsGames() async throws {
        let leagues = [nfl, nba]
        let nflGame = game("nfl-game")
        let browser = StreamBrowser(leagues: { _ in leagues }, events: { _ in [nflGame] })
        browser.open()
        XCTAssertTrue(browser.isLoadingLeagues)
        try await waitUntil(!browser.events.isEmpty)
        XCTAssertEqual(browser.selectedLeagueID, nfl.id)
        XCTAssertEqual(browser.events, [nflGame])
        XCTAssertFalse(browser.isLoadingEvents)
    }

    func testIgnoresResultsFromAPreviouslySelectedLeague() async throws {
        let nflGame = game("nfl-game")
        let nbaGame = game("nba-game")
        let leagues = [nfl, nba]
        let browser = StreamBrowser(leagues: { _ in leagues }, events: { league in
            // The slow response ignores cancellation, so only the selection guard can drop it.
            if league.name == "NFL" {
                try? await Task.sleep(nanoseconds: 200_000_000)
                return [nflGame]
            }
            return [nbaGame]
        })
        browser.open()
        try await waitUntil(browser.isLoadingEvents)
        browser.selectedLeagueID = nba.id
        try await waitUntil(browser.events == [nbaGame])
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(browser.selectedLeagueID, nba.id)
        XCTAssertEqual(browser.events, [nbaGame])
        XCTAssertFalse(browser.isLoadingEvents)
    }

    func testReportsLeagueFailureAndRecoversOnRefresh() async throws {
        final class Attempts: @unchecked Sendable { var count = 0 }
        let attempts = Attempts()
        let leagues = [nfl]
        let browser = StreamBrowser(leagues: { _ in
            attempts.count += 1
            if attempts.count == 1 { throw ResolveError.badPage("HTTP 503") }
            return leagues
        }, events: { _ in [] })
        browser.open()
        try await waitUntil(browser.leaguesError != nil)
        XCTAssertEqual(browser.leaguesError, "Could not load the page (HTTP 503).")
        browser.refresh()
        try await waitUntil(!browser.leagues.isEmpty && !browser.isLoadingEvents)
        XCTAssertNil(browser.leaguesError)
        XCTAssertEqual(browser.selectedLeagueID, nfl.id)
    }
}
