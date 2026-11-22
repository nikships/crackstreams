import Foundation

struct ResolvedStream {
    let playlist: URL
    let referer: String?
    let title: String
}

enum ResolveError: LocalizedError {
    case badPage(String)
    case noEmbeds
    case noPlaylist
    case responseTooLarge
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .badPage(let why): return "Could not load the page (\(why))."
        case .noEmbeds: return "No stream player was found on that page."
        case .noPlaylist: return "No compatible direct feed was found. Try another link or try again later."
        case .responseTooLarge: return "The server returned an unexpectedly large response."
        case .invalidResponse: return "The server returned an invalid response."
        }
    }
}

enum Net {
    static let userAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/156.0.0.0 Safari/537.36"
    static let maximumPlaylistBytes = 4 * 1024 * 1024
    static let maximumSegmentBytes = 128 * 1024 * 1024

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 45
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 8
        return URLSession(configuration: configuration)
    }()

    static func request(_ url: URL, referer: String?, range: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        if let range { request.setValue(range, forHTTPHeaderField: "Range") }
        return request
    }

    static func data(_ url: URL, referer: String?, range: String? = nil,
                     maximumBytes: Int = maximumSegmentBytes) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request(url, referer: referer, range: range))
        guard let http = response as? HTTPURLResponse else { throw ResolveError.invalidResponse }
        if http.expectedContentLength > Int64(maximumBytes) || data.count > maximumBytes {
            throw ResolveError.responseTooLarge
        }
        return (data, http)
    }

    static func text(_ url: URL, referer: String?) async throws -> (String, Int) {
        let page = try await loadPage(url, referer: referer)
        return (page.body, page.status)
    }

    static func loadPage(_ url: URL, referer: String?) async throws -> (body: String, status: Int, url: URL) {
        let (data, response) = try await data(url, referer: referer, maximumBytes: maximumPlaylistBytes)
        return (String(decoding: data, as: UTF8.self), response.statusCode, response.url ?? url)
    }

    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)/"
    }
}

enum Resolver {
    typealias Page = (body: String, status: Int, url: URL)
    typealias PageLoader = (URL, String?) async throws -> Page

    static func resolve(_ input: URL, load: PageLoader = Net.loadPage) async throws -> ResolvedStream {
        let title = prettyTitle(from: input)

        if input.path.lowercased().hasSuffix(".m3u8") {
            let referer = Net.origin(of: input)
            if let playlist = try await playlist(input, referer: referer, load: load) {
                return ResolvedStream(playlist: playlist, referer: referer, title: title)
            }
            throw ResolveError.noPlaylist
        }

        let page: Page
        do {
            page = try await load(input, nil)
            guard (200..<300).contains(page.status) else { throw ResolveError.badPage("HTTP \(page.status)") }
        } catch let error as ResolveError {
            throw error
        } catch {
            try Task.checkCancellation()
            throw ResolveError.badPage(error.localizedDescription)
        }

        if let primary = try await findPlaylist(in: page, title: title, depth: 1, limit: 8, load: load) {
            return primary
        }
        if let match = event(in: page.body, infoClass: "event-info") {
            for alternative in alternatePages(for: page.url, college: match.college) {
                try Task.checkCancellation()
                guard let candidate = try? await load(alternative, nil), (200..<300).contains(candidate.status),
                      Net.origin(of: candidate.url) == Net.origin(of: alternative),
                      let other = event(in: candidate.body, infoClass: "custom-player-category"),
                      other.teams == match.teams, other.date == match.date else { continue }
                if let playable = try await findPlaylist(in: candidate, title: title, depth: 3, limit: 5, load: load) {
                    return playable
                }
            }
        }
        try Task.checkCancellation()
        if embedURLs(in: page.body, base: page.url).isEmpty { throw ResolveError.noEmbeds }
        throw ResolveError.noPlaylist
    }

    private static func findPlaylist(in page: Page, title: String, depth: Int, limit: Int,
                                     load: PageLoader) async throws -> ResolvedStream? {
        var visited = Set([page.url])
        var queue = embedURLs(in: page.body, base: page.url).map { (url: $0, parent: page.url, level: 1) }
        var remaining = limit
        while !queue.isEmpty && remaining > 0 {
            try Task.checkCancellation()
            let (embed, parent, level) = queue.removeFirst()
            guard visited.insert(embed).inserted else { continue }
            remaining -= 1
            guard let origin = Net.origin(of: embed) else { continue }
            // Some embeds only expose DIRECT_STREAM_URL when the Referer is the watch site, not their own origin.
            // The playlist itself still needs the embed's origin.
            var embedReferers = [origin]
            if let parentOrigin = Net.origin(of: parent), parentOrigin != origin { embedReferers.append(parentOrigin) }
            for embedReferer in embedReferers {
                try Task.checkCancellation()
                guard let child = try? await load(embed, embedReferer), (200..<300).contains(child.status),
                      let childOrigin = Net.origin(of: child.url) else { continue }
                if let candidate = playlistURL(in: child.body, base: child.url),
                   let playlist = try? await playlist(candidate, referer: childOrigin, load: load) {
                    return ResolvedStream(playlist: playlist, referer: childOrigin, title: title)
                }
                if level < depth {
                    let nested = embedURLs(in: child.body, base: child.url)
                    if !nested.isEmpty {
                        queue.append(contentsOf: nested.map { (url: $0, parent: child.url, level: level + 1) })
                        break
                    }
                }
            }
        }
        return nil
    }

    private static func playlist(_ url: URL, referer: String?, load: PageLoader) async throws -> URL? {
        let page = try await load(url, referer)
        try Task.checkCancellation()
        return (200..<300).contains(page.status) && page.body.hasPrefix("#EXTM3U") ? page.url : nil
    }

    private static func event(in html: String, infoClass: String) -> (teams: String, date: String, college: Bool)? {
        guard let heading = firstMatch(#"<h1\b[^>]*>(.*?)</h1>"#, in: html),
              let info = firstMatch(#"<div\b[^>]*class=["']"# + infoClass + #"["'][^>]*>(.*?)</div>"#, in: html)
        else { return nil }
        let teams = heading.lowercased()
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"^\s*ncaaf\s*:\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+(?:vs\.?|at)\s+"#, with: " vs ", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        let detail = info.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        guard let date = firstMatch(#"\b((?:January|February|March|April|May|June|July|August|September|October|November|December) \d{1,2}, \d{4})\b"#, in: detail)
        else { return nil }
        return (teams, date.lowercased(), detail.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("NCAA"))
    }

    private static func alternatePages(for watch: URL, college: Bool) -> [URL] {
        guard ["crackstreams.mx", "www.crackstreams.mx"].contains(watch.host?.lowercased() ?? ""),
              let slug = firstMatch(#"^/stream/([a-z0-9-]+)/?$"#, in: watch.path.lowercased()),
              slug.contains("-vs-") else { return [] }
        let alternate = slug.replacingOccurrences(of: "-vs-", with: "-at-")
        return (college ? ["ncaaf-" + alternate, alternate] : [alternate]).compactMap {
            URL(string: "https://hdcrackstreams.live/custom-stream/" + $0)
        }
    }

    static func embedURLs(in html: String, base: URL) -> [URL] {
        var urls: [URL] = []

        if let match = firstMatch(#"(?:const|let|var)\s+allStreams\s*=\s*(\[.*?\])\s*;"#, in: html),
           let data = match.data(using: .utf8),
           let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            for item in array {
                if let value = item["value"] as? String,
                   let url = streamURL(value, relativeTo: base) {
                    urls.append(url)
                }
            }
        }
        if !urls.isEmpty { return urls }

        let skippedHosts = ["chatango", "histats", "dtscout", "google", "doubleclick", "cloudflare"]
        for source in allMatches(#"<iframe[^>]*\ssrc=[\"']([^\"']+)[\"']"#, in: html) {
            guard let url = streamURL(source, relativeTo: base) else { continue }
            if skippedHosts.contains(where: { url.host?.localizedCaseInsensitiveContains($0) == true }) { continue }
            urls.append(url)
        }
        return urls
    }

    static func playlistURL(in html: String, base: URL) -> URL? {
        if let source = firstMatch(#"DIRECT_STREAM_URL\s*=\s*[\"']([^\"']+)[\"']"#, in: html) {
            return streamURL(source, relativeTo: base)
        }
        if let source = firstMatch(#"(https?://[^\"'\s\\]+\.m3u8[^\"'\s\\]*)"#, in: html) {
            return streamURL(source, relativeTo: base)
        }
        return nil
    }

    private static func streamURL(_ source: String, relativeTo base: URL) -> URL? {
        let cleaned = source.replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "&amp;", with: "&")
        guard let url = URL(string: cleaned, relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
        return url
    }

    static func prettyTitle(from url: URL) -> String {
        let slug = url.deletingPathExtension().lastPathComponent
        let words = slug.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { word -> String in
            let value = String(word)
            if value.lowercased() == "vs" { return "vs" }
            return value.prefix(1).uppercased() + value.dropFirst()
        }
        return words.isEmpty ? (url.host ?? "Stream") : words.joined(separator: " ")
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let capture = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[capture])
    }

    private static func allMatches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1, let capture = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[capture])
        }
    }
}
