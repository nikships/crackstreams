import XCTest
@testable import Crackstreams

final class ResolverTests: XCTestCase {
    func testExtractsEmbedsFromStreamJSON() throws {
        let html = #"""
        <script>const allStreams = [
          {"label":"Link-1 HD","type":"external","value":"https:\/\/yieldz.example\/nba\/game?a=1&amp;b=2"},
          {"label":"Link-2 HD","type":"external","value":"https://backup.example/embed"}
        ];</script>
        """#
        let embeds = Resolver.embedURLs(in: html, base: URL(string: "https://crackstreams.example/stream/game")!)
        XCTAssertEqual(embeds.count, 2)
        XCTAssertEqual(embeds[0].absoluteString, "https://yieldz.example/nba/game?a=1&b=2")
        XCTAssertEqual(embeds[1].host, "backup.example")
    }

    func testFallsBackToIframesAndSkipsTrackers() {
        let html = #"""
        <iframe src="https://histats.example/track"></iframe>
        <iframe src='/embed/live'></iframe>
        """#
        let embeds = Resolver.embedURLs(in: html, base: URL(string: "https://watch.example/game")!)
        XCTAssertEqual(embeds, [URL(string: "https://watch.example/embed/live")!])
    }

    func testExtractsDirectPlaylistAndRelativeM3U8() {
        let direct = #"DIRECT_STREAM_URL = "https:\/\/cdn.example\/live\/playlist.m3u8?token=a&amp;b=c";"#
        XCTAssertEqual(
            Resolver.playlistURL(in: direct, base: URL(string: "https://embed.example/player")!)?.absoluteString,
            "https://cdn.example/live/playlist.m3u8?token=a&b=c"
        )
        let fallback = #"var other = 'https://cdn.example/v2/master.m3u8?key=1';"#
        XCTAssertEqual(
            Resolver.playlistURL(in: fallback, base: URL(string: "https://embed.example")!)?.path,
            "/v2/master.m3u8"
        )
    }

    func testRejectsNonHTTPSchemes() {
        let html = #"DIRECT_STREAM_URL = "javascript:alert(1)";"#
        XCTAssertNil(Resolver.playlistURL(in: html, base: URL(string: "https://embed.example")!))
    }

    func testPrettyTitle() {
        XCTAssertEqual(
            Resolver.prettyTitle(from: URL(string: "https://watch.example/stream/golden-state-warriors-vs-houston-rockets")!),
            "Golden State Warriors vs Houston Rockets"
        )
    }

    func testOriginIncludesNonDefaultPort() {
        XCTAssertEqual(Net.origin(of: URL(string: "https://cdn.example:8443/a/b")!), "https://cdn.example:8443/")
        XCTAssertNil(Net.origin(of: URL(string: "file:///tmp/video.m3u8")!))
    }

    func testFindsSameGameViaNestedAlternateButNeverUsesOtherDates() async throws {
        let watch = URL(string: "https://crackstreams.mx/stream/red-team-vs-blue-team")!
        let wrongDay = "https://hdcrackstreams.live/custom-stream/ncaaf-red-team-at-blue-team"
        let verified = "https://hdcrackstreams.live/custom-stream/red-team-at-blue-team"
        let first = "https://player.example/first"
        let second = "https://middle.example/event"
        let third = "https://embed.example/watch"
        let playlist = "https://cdn.example/game/index.m3u8"
        let pages: [String: String] = [
            watch.absoluteString: """
                <h1>Red Team vs Blue Team</h1><div class="event-info"><span>NCAA</span> November 21, 2026</div>
                <iframe src="https://player.example/js-only"></iframe>
                """,
            "https://player.example/js-only": "<script src='/player.js'></script>",
            wrongDay: """
                <h1>NCAAF: Red Team at Blue Team</h1><div class="custom-player-category">November 20, 2026</div>
                <iframe src="https://old.example/player"></iframe>
                """,
            verified: """
                <h1>Red Team at Blue Team</h1><div class="custom-player-category">November 21, 2026</div>
                <iframe src="\(first)"></iframe>
                """,
            first: "<iframe src='\(second)'></iframe>",
            second: "<iframe src='\(third)'></iframe>",
            third: "const DIRECT_STREAM_URL = '\(playlist)';",
            playlist: "#EXTM3U\n"
        ]
        var requested: [String] = []
        let result = try await Resolver.resolve(watch) { url, referer in
            requested.append(url.absoluteString)
            if url.absoluteString == playlist { XCTAssertEqual(referer, "https://embed.example/") }
            return (pages[url.absoluteString] ?? "", pages[url.absoluteString] == nil ? 404 : 200, url)
        }
        XCTAssertEqual(result.playlist.absoluteString, playlist)
        XCTAssertEqual(result.title, "Red Team vs Blue Team")
        XCTAssertTrue(requested.contains(wrongDay))
        XCTAssertFalse(requested.contains("https://old.example/player"))
    }

    func testPrefersOriginalDirectFeedAndUsesFinalURLs() async throws {
        let watch = URL(string: "https://crackstreams.mx/stream/red-team-vs-blue-team")!
        let embed = URL(string: "https://player.example/embed")!
        let finalEmbed = URL(string: "https://player-cdn.example/game/")!
        let playlist = URL(string: "https://player-cdn.example/game/live.m3u8")!
        let finalPlaylist = URL(string: "https://cdn.example/live.m3u8")!
        let resolved = try await Resolver.resolve(watch) { url, referer in
            switch url {
            case watch: return ("<iframe src='\(embed)'></iframe>", 200, url)
            case embed: return ("DIRECT_STREAM_URL = 'live.m3u8';", 200, finalEmbed)
            case playlist:
                XCTAssertEqual(referer, "https://player-cdn.example/")
                return ("#EXTM3U\n", 200, finalPlaylist)
            default:
                XCTFail("Unexpected request: \(url)")
                return ("", 404, url)
            }
        }
        XCTAssertEqual(resolved.playlist, finalPlaylist)
    }
}
