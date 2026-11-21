import Foundation
import Network

struct Settings: Decodable {
    let host: String
    let tv: String
    let port: UInt16
    let token: String
}

struct League: Encodable {
    let name: String
    let url: String
}

struct Game: Encodable {
    let title: String
    let url: String
    let detail: String?
    let start: Date?
    let channel: Bool
}

struct Playback: Encodable {
    let title: String
    let url: String
}

func webURL(_ value: String?) -> URL? {
    guard let value, value.utf8.count <= 2048,
          let url = URL(string: value), let host = url.host, host.contains("."),
          !host.hasSuffix(".local"), !host.hasSuffix(".localhost"),
          IPv4Address(host) == nil, url.user == nil, url.password == nil,
          ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
          url.port == nil || url.port == (url.scheme?.lowercased() == "https" ? 443 : 80)
    else { return nil }
    return url
}

func siteURL(_ value: String?, path: String) -> URL? {
    guard let url = webURL(value),
          ["crackstreams.mx", "www.crackstreams.mx"].contains(url.host?.lowercased() ?? ""),
          url.path.lowercased().hasPrefix(path) else { return nil }
    return url
}

func failure(_ status: Int, _ message: String) -> HLSProxy.APIError {
    .init(status: status, message: message)
}

func localAddress(_ string: String) -> IPv4Address? {
    guard let address = IPv4Address(string) else { return nil }
    let bytes = Array(address.rawValue)
    guard bytes[0] == 10 || (bytes[0] == 172 && (16...31).contains(bytes[1]))
        || (bytes[0] == 192 && bytes[1] == 168) else { return nil }
    return address
}

func run() throws {
    guard CommandLine.arguments.count == 2 else {
        throw failure(400, "Usage: CrackstreamsTVRelay <settings.json>")
    }
    let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
    let config = try JSONDecoder().decode(Settings.self, from: data)
    guard let address = localAddress(config.host), let client = localAddress(config.tv),
          config.port > 1024, config.token.count == 64,
          config.token.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    else { throw failure(400, "Relay settings require private IPv4 addresses, a port above 1024, and a 32-byte hex token.") }

    let proxy = HLSProxy(port: config.port, companion: .init(address: address, client: client) { proxy, path, query in
        guard query["t"] == config.token else { throw failure(403, "This TV is not paired with the Mac relay.") }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        switch path {
        case "/api/leagues":
            let leagues = try await StreamDirectory.leagues(from: StreamDirectory.home)
            return try encoder.encode(leagues.map { League(name: $0.name, url: $0.url.absoluteString) })
        case "/api/games":
            guard let league = siteURL(query["url"], path: "/league/") else {
                throw failure(400, "Choose a sport from the directory.")
            }
            let games = try await StreamDirectory.events(in: .init(name: "", url: league, logo: nil))
            return try encoder.encode(games.map {
                Game(title: $0.title, url: $0.url.absoluteString, detail: $0.startText ?? $0.day,
                     start: $0.start, channel: $0.status() == .channel)
            })
        case "/api/play":
            guard let url = webURL(query["url"]),
                  url.pathExtension.lowercased() == "m3u8" || siteURL(query["url"], path: "/stream/") != nil else {
                throw failure(400, "Enter a Crackstreams watch link or a public .m3u8 URL.")
            }
            let stream = try await Resolver.resolve(url)
            let urlString = proxy.localURL(for: stream.playlist, referer: stream.referer).absoluteString
            return try encoder.encode(Playback(title: stream.title, url: urlString))
        default:
            throw failure(404, "This relay route does not exist.")
        }
    })
    try proxy.start()
    print("Crackstreams TV relay listening on \(address):\(proxy.port), only accepting \(client).")
    withExtendedLifetime(proxy) { RunLoop.main.run() }
}

do {
    try run()
} catch {
    FileHandle.standardError.write(Data("Crackstreams TV relay: \(error.localizedDescription)\n".utf8))
    exit(EXIT_FAILURE)
}
