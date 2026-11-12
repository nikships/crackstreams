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
}
