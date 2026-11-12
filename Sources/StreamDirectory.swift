import Foundation

struct DirectoryLeague: Identifiable, Hashable, Sendable {
    let name: String
    let url: URL
    let logo: URL?
    var id: URL { url }
}

struct DirectoryEvent: Identifiable, Hashable, Sendable {
    enum Status: Equatable {
        case live
        case startingSoon
        case upcoming
        case earlier
        case channel
        case unscheduled
    }

    let title: String
    let url: URL
    let day: String?
    let startText: String?
    let start: Date?
    var id: URL { url }

    func status(at now: Date = Date()) -> Status {
        let lowered = title.lowercased()
        if lowered.contains("24/7") || lowered.hasSuffix(" network") { return .channel }
        guard let start else { return .unscheduled }
        if now >= start {
            return now < start.addingTimeInterval(StreamDirectory.liveWindow) ? .live : .earlier
        }
        return start.timeIntervalSince(now) <= StreamDirectory.linkLeadTime ? .startingSoon : .upcoming
    }
}

enum DirectoryError: LocalizedError {
    case noLeagues

    var errorDescription: String? {
        switch self {
        case .noLeagues: return "No sports were listed on the stream site."
        }
    }
}

/// Reads the league and game listings from a Crackstreams-style site. Only same-site
/// `/league/` and `/stream/` links are returned, so ads and partner sites never appear.
enum StreamDirectory {
    static let home = URL(string: "https://crackstreams.mx/")!
    /// How long after its listed start a game is treated as live.
    static let liveWindow: TimeInterval = 4 * 60 * 60
    /// The site posts links about an hour before the start time.
    static let linkLeadTime: TimeInterval = 60 * 60

    static func leagues(from home: URL) async throws -> [DirectoryLeague] {
        let leagues = parseLeagues(try await page(home), base: home)
        guard !leagues.isEmpty else { throw DirectoryError.noLeagues }
        return leagues
    }

    static func events(in league: DirectoryLeague) async throws -> [DirectoryEvent] {
        parseEvents(try await page(league.url), base: league.url)
    }

    private static func page(_ url: URL) async throws -> String {
        let body: String
        let code: Int
        do {
            (body, code) = try await Net.text(url, referer: nil)
        } catch let error as ResolveError {
            throw error
        } catch {
            try Task.checkCancellation()
            throw ResolveError.badPage(error.localizedDescription)
        }
        guard (200..<300).contains(code) else { throw ResolveError.badPage("HTTP \(code)") }
        return body
    }

    static func parseLeagues(_ html: String, base: URL) -> [DirectoryLeague] {
        var cards: [DirectoryLeague] = []
        var links: [DirectoryLeague] = []
        for match in HTML.captures(#"<a\b([^>]*)>(.*?)</a>"#, in: HTML.removingComments(html)) {
            guard let anchor = Anchor(attributes: match[0], inner: match[1]),
                  let url = siteURL(anchor.href, base: base, pathContaining: "/league/") else { continue }
            let name = leagueName(anchor.title ?? anchor.text)
            guard !name.isEmpty else { continue }
            let league = DirectoryLeague(name: name, url: url, logo: anchor.image.flatMap { webURL($0, base: base) })
            if anchor.isCard { cards.append(league) } else { links.append(league) }
        }

        // Cards carry logos, so they win over navigation links with the same name.
        var names = Set<String>()
        var urls = Set<URL>()
        return (cards + links).filter { league in
            names.insert(league.name.lowercased()).inserted && urls.insert(league.url).inserted
        }
    }

    static func parseEvents(_ html: String, base: URL) -> [DirectoryEvent] {
        var day: String?
        var events: [DirectoryEvent] = []
        var seen = Set<URL>()
        let pattern = #"<h2\b[^>]*>(.*?)</h2>|<a\b([^>]*)>(.*?)</a>"#
        for match in HTML.captures(pattern, in: HTML.removingComments(html)) {
            if let heading = match[0] {
                day = HTML.plainText(heading)
                continue
            }
            guard let anchor = Anchor(attributes: match[1], inner: match[2]), anchor.isCard,
                  let url = siteURL(anchor.href, base: base, pathContaining: "/stream/"),
                  seen.insert(url).inserted else { continue }
            let title = anchor.title ?? anchor.text
            guard !title.isEmpty else { continue }
            let startText = anchor.subtitle
                .map { $0.replacingOccurrences(of: #"^\s*start\s*time\s*:\s*"#, with: "",
                                               options: [.regularExpression, .caseInsensitive]) }
                .flatMap { $0.isEmpty ? nil : $0 }
            events.append(DirectoryEvent(title: title, url: url, day: day, startText: startText,
                                         start: startDate(day: day, time: startText)))
        }
        return events
    }

    /// Parses a site heading such as "Wednesday, November 11, 2026" and a time such as "7:00 PM ET".
    static func startDate(day: String?, time: String?) -> Date? {
        guard let day, var parts = time?.split(separator: " ").map(String.init), !parts.isEmpty else { return nil }
        var zone = TimeZone(identifier: "America/New_York")!
        if let last = parts.last, let named = zones[last.uppercased()].flatMap(TimeZone.init(identifier:)) {
            zone = named
            parts.removeLast()
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "EEEE, MMMM d, yyyy h:mm a"
        return formatter.date(from: "\(day) \(parts.joined(separator: " "))")
    }

    private static let zones = [
        "ET": "America/New_York", "EST": "America/New_York", "EDT": "America/New_York",
        "CT": "America/Chicago", "CST": "America/Chicago", "CDT": "America/Chicago",
        "MT": "America/Denver", "MST": "America/Denver", "MDT": "America/Denver",
        "PT": "America/Los_Angeles", "PST": "America/Los_Angeles", "PDT": "America/Los_Angeles",
        "UTC": "UTC", "GMT": "GMT"
    ]

    private static func leagueName(_ text: String) -> String {
        text.replacingOccurrences(of: #"\s+streams?$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func siteURL(_ href: String, base: URL, pathContaining fragment: String) -> URL? {
        guard let url = webURL(href, base: base), siteHost(url) == siteHost(base),
              url.path.lowercased().contains(fragment) else { return nil }
        return url
    }

    private static func webURL(_ source: String, base: URL) -> URL? {
        let cleaned = HTML.decodingEntities(source).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: cleaned, relativeTo: base)?.absoluteURL,
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              url.host != nil else { return nil }
        return url
    }

    private static func siteHost(_ url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private struct Anchor {
        let href: String
        let isCard: Bool
        let title: String?
        let subtitle: String?
        let image: String?
        let text: String

        init?(attributes: String?, inner: String?) {
            guard let attributes, let inner,
                  let href = HTML.first(#"\bhref\s*=\s*["']([^"']+)["']"#, in: attributes) else { return nil }
            self.href = href
            let classes = HTML.first(#"\bclass\s*=\s*["']([^"']*)["']"#, in: attributes) ?? ""
            isCard = classes.split(whereSeparator: \.isWhitespace).contains("card")
            title = HTML.first(#"class\s*=\s*["']card-title["'][^>]*>(.*?)</div>"#, in: inner)
                .map(HTML.plainText).flatMap { $0.isEmpty ? nil : $0 }
            subtitle = HTML.first(#"class\s*=\s*["']card-subtitle["'][^>]*>(.*?)</div>"#, in: inner)
                .map(HTML.plainText)
            image = HTML.first(#"<img\b[^>]*\bsrc\s*=\s*["']([^"']+)["']"#, in: inner)
            text = HTML.plainText(inner)
        }
    }
}

private enum HTML {
    static func captures(_ pattern: String, in text: String) -> [[String?]] {
        guard let regex = try? NSRegularExpression(pattern: pattern,
                                                   options: [.dotMatchesLineSeparators, .caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (1..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) }
            }
        }
    }

    static func first(_ pattern: String, in text: String) -> String? {
        captures(pattern, in: text).first?.first ?? nil
    }

    static func removingComments(_ html: String) -> String {
        html.replacingOccurrences(of: #"<!--.*?-->"#, with: "", options: .regularExpression)
    }

    static func plainText(_ html: String) -> String {
        let stripped = html.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        return decodingEntities(stripped)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodingEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = text
        for (entity, value) in [("&quot;", "\""), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
            result = result.replacingOccurrences(of: entity, with: value)
        }
        for match in captures(#"&#(x?[0-9a-f]+);"#, in: result) {
            guard let code = match[0] else { continue }
            let scalar = code.lowercased().hasPrefix("x")
                ? UInt32(code.dropFirst(), radix: 16) : UInt32(code, radix: 10)
            guard let scalar, let character = Unicode.Scalar(scalar) else { continue }
            result = result.replacingOccurrences(of: "&#\(code);", with: String(Character(character)))
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }
}

/// Browsing state shared by every presentation of the stream browser. Results from a league
/// that is no longer selected are discarded.
@MainActor
final class StreamBrowser: ObservableObject {
    typealias LeagueLoader = @Sendable (URL) async throws -> [DirectoryLeague]
    typealias EventLoader = @Sendable (DirectoryLeague) async throws -> [DirectoryEvent]

    static let eventCacheLifetime: TimeInterval = 2 * 60
    static let leagueCacheLifetime: TimeInterval = 30 * 60

    let home: URL
    @Published private(set) var leagues: [DirectoryLeague] = []
    @Published private(set) var isLoadingLeagues = false
    @Published private(set) var leaguesError: String?
    @Published var selectedLeagueID: URL? {
        didSet { if oldValue != selectedLeagueID { loadEvents() } }
    }
    @Published private(set) var events: [DirectoryEvent] = []
    @Published private(set) var isLoadingEvents = false
    @Published private(set) var eventsError: String?

    private let fetchLeagues: LeagueLoader
    private let fetchEvents: EventLoader
    private var leaguesLoadedAt: Date?
    private var cache: [URL: (loadedAt: Date, events: [DirectoryEvent])] = [:]
    private var leaguesTask: Task<Void, Never>?
    private var eventsTask: Task<Void, Never>?

    init(home: URL = StreamDirectory.home,
         leagues: @escaping LeagueLoader = { try await StreamDirectory.leagues(from: $0) },
         events: @escaping EventLoader = { try await StreamDirectory.events(in: $0) }) {
        self.home = home
        fetchLeagues = leagues
        fetchEvents = events
    }

    var selectedLeague: DirectoryLeague? { leagues.first { $0.id == selectedLeagueID } }

    func open() {
        let leaguesAreStale = leaguesLoadedAt.map { Date().timeIntervalSince($0) > Self.leagueCacheLifetime } ?? true
        if leagues.isEmpty || leaguesAreStale {
            if !isLoadingLeagues { reloadLeagues() }
        } else {
            loadEvents()
        }
    }

    func refresh() {
        if leagues.isEmpty { reloadLeagues() } else { loadEvents(force: true) }
    }

    private func reloadLeagues() {
        leaguesTask?.cancel()
        isLoadingLeagues = true
        leaguesError = nil
        let home = self.home
        let fetchLeagues = self.fetchLeagues
        leaguesTask = Task { [weak self] in
            do {
                let leagues = try await fetchLeagues(home)
                guard let self, !Task.isCancelled else { return }
                self.leagues = leagues
                self.leaguesLoadedAt = Date()
                self.isLoadingLeagues = false
                if let id = self.selectedLeagueID, leagues.contains(where: { $0.id == id }) {
                    self.loadEvents()
                } else {
                    self.selectedLeagueID = leagues.first?.id
                }
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.isLoadingLeagues = false
                self.leaguesError = error.localizedDescription
            }
        }
    }

    private func loadEvents(force: Bool = false) {
        eventsTask?.cancel()
        eventsError = nil
        guard let league = selectedLeague else {
            events = []
            isLoadingEvents = false
            return
        }
        let cached = cache[league.id]
        if !force, let cached, Date().timeIntervalSince(cached.loadedAt) < Self.eventCacheLifetime {
            events = cached.events
            isLoadingEvents = false
            return
        }
        // Keep showing stale games while a refresh is in flight.
        events = cached?.events ?? []
        isLoadingEvents = true
        let fetchEvents = self.fetchEvents
        eventsTask = Task { [weak self] in
            do {
                let events = try await fetchEvents(league)
                guard let self, !Task.isCancelled, self.selectedLeagueID == league.id else { return }
                self.cache[league.id] = (Date(), events)
                self.events = events
                self.isLoadingEvents = false
            } catch {
                guard let self, !Task.isCancelled, self.selectedLeagueID == league.id else { return }
                self.isLoadingEvents = false
                self.eventsError = error.localizedDescription
            }
        }
    }
}
