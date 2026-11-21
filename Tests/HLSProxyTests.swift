import XCTest
@testable import Crackstreams

final class HLSProxyTests: XCTestCase {
    private let base = URL(string: "https://cdn.example/live/master.m3u8")!
    private let referer = "https://embed.example/"

    func testRewritesVariantSegmentsKeysAndInitializationMap() throws {
        let proxy = HLSProxy(port: 4321)
        let playlist = """
        #EXTM3U
        #EXT-X-STREAM-INF:BANDWIDTH=1000000
        video/720p.m3u8
        #EXT-X-KEY:METHOD=AES-128,URI="keys/key.bin",IV=0x1
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:4.0,
        segment-1.txt
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",URI="audio/en.m3u8"
        """
        let rewritten = proxy.rewrite(playlist: playlist, base: base, referer: referer)
        let urls = rewritten.split(separator: "\n").compactMap { line -> URL? in
            guard line.hasPrefix("http") else { return nil }
            return URL(string: String(line))
        } + rewritten.split(separator: "\n").compactMap { line -> URL? in
            guard let start = line.range(of: "URI=\"http")?.lowerBound else { return nil }
            let tail = line[start...].dropFirst(5)
            guard let end = tail.firstIndex(of: "\"") else { return nil }
            return URL(string: String(tail[..<end]))
        }
        XCTAssertEqual(urls.count, 5)
        XCTAssertTrue(rewritten.contains("/m.m3u8?"))
        XCTAssertTrue(rewritten.contains("/s.ts?"))
        XCTAssertTrue(rewritten.contains("/k.key?"))
        XCTAssertTrue(rewritten.contains("/i.mp4?"))
        for url in urls {
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let params = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(components?.host, "127.0.0.1")
            XCTAssertEqual(components?.port, 4321)
            XCTAssertGreaterThan(params["t"]?.count ?? 0, 32)
            XCTAssertEqual(params["r"], referer)
            XCTAssertNotNil(params["u"])
        }
    }

    func testLeavesInvalidAndNonMediaLinesUnchanged() {
        let proxy = HLSProxy(port: 4321)
        let playlist = "#EXTM3U\n#EXTINF:4,\njavascript:alert(1)\n"
        XCTAssertEqual(proxy.rewrite(playlist: playlist, base: base, referer: referer), playlist)
    }

    func testRangeParsing() {
        let data = Data(0..<10)
        XCTAssertEqual(HLSProxy.slice(data, range: "bytes=2-4")?.data, Data([2, 3, 4]))
        XCTAssertEqual(HLSProxy.slice(data, range: "bytes=7-")?.data, Data([7, 8, 9]))
        XCTAssertEqual(HLSProxy.slice(data, range: "bytes=-3")?.data, Data([7, 8, 9]))
        XCTAssertNil(HLSProxy.slice(data, range: "bytes=10-11"))
        XCTAssertNil(HLSProxy.slice(data, range: "bytes=-0"))
        XCTAssertNil(HLSProxy.slice(data, range: "bytes=0-2,5-7"))
        XCTAssertNil(HLSProxy.slice(data, range: "lines=0-2"))
    }
}
