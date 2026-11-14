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
        case .noPlaylist: return "The stream is not live yet, or every listed feed is unavailable."
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
        let (data, response) = try await data(url, referer: referer, maximumBytes: maximumPlaylistBytes)
        return (String(decoding: data, as: UTF8.self), response.statusCode)
    }

    static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host else { return nil }
        let port = url.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)/"
    }
}

enum Resolver {
    static func resolve(_ input: URL) async throws -> ResolvedStream {
        let title = prettyTitle(from: input)

        if input.path.lowercased().hasSuffix(".m3u8") {
            let referer = Net.origin(of: input)
            if try await isPlaylist(input, referer: referer) {
                return ResolvedStream(playlist: input, referer: referer, title: title)
            }
            throw ResolveError.noPlaylist
        }

        let page: String
        do {
            let (body, code) = try await Net.text(input, referer: nil)
            guard (200..<300).contains(code) else { throw ResolveError.badPage("HTTP \(code)") }
            page = body
        } catch let error as ResolveError {
            throw error
        } catch {
            throw ResolveError.badPage(error.localizedDescription)
        }

        let embeds = embedURLs(in: page, base: input)
        guard !embeds.isEmpty else { throw ResolveError.noEmbeds }

        for embed in embeds.prefix(8) {
            try Task.checkCancellation()
            guard let origin = Net.origin(of: embed) else { continue }
            // Some embeds only expose DIRECT_STREAM_URL when the Referer is the watch site, not their own origin.
            // The playlist itself still needs the embed's origin.
            var embedReferers = [origin]
            if let watchOrigin = Net.origin(of: input), watchOrigin != origin { embedReferers.append(watchOrigin) }
            for embedReferer in embedReferers {
                try Task.checkCancellation()
                guard let (html, code) = try? await Net.text(embed, referer: embedReferer),
                      (200..<300).contains(code),
                      let candidate = playlistURL(in: html, base: embed) else { continue }
                if (try? await isPlaylist(candidate, referer: origin)) == true {
                    return ResolvedStream(playlist: candidate, referer: origin, title: title)
                }
            }
        }
        throw ResolveError.noPlaylist
    }

    private static func isPlaylist(_ url: URL, referer: String?) async throws -> Bool {
        let (body, code) = try await Net.text(url, referer: referer)
        return (200..<300).contains(code) && body.hasPrefix("#EXTM3U")
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
