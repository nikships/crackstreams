import SwiftUI

struct BrowserView: View {
    @ObservedObject var browser: StreamBrowser
    let destination: String
    let playingURLs: Set<URL>
    /// Returns an error message when the stream could not be added.
    let onWatch: (DirectoryEvent) -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""
    @State private var selection: DirectoryEvent.ID?
    @State private var message: String?
    @FocusState private var isFilterFocused: Bool

    private let accent = Color(red: 0.30, green: 0.72, blue: 0.96)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                leagueList
                    .frame(width: 180)
                Divider()
                eventPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            footer
        }
        .frame(width: 720, height: 480)
        .onAppear { browser.open() }
        .onChange(of: browser.selectedLeagueID) {
            selection = nil
            message = nil
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Browse streams")
                    .font(.headline)
                Text("\(browser.home.host ?? "Stream site") • \(destination)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Filter games", text: $filter)
                    .textFieldStyle(.plain)
                    .focused($isFilterFocused)
                    .accessibilityLabel("Filter games")
            }
            .padding(.horizontal, 10)
            .frame(width: 200, height: 28)
            .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 7))
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(isFilterFocused ? accent.opacity(0.75) : Color.white.opacity(0.09), lineWidth: 1)
            }
            Button(action: browser.refresh) {
                Image(systemName: "arrow.clockwise")
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(browser.isLoadingLeagues || browser.isLoadingEvents)
            .help("Refresh (⌘R)")
            .accessibilityLabel("Refresh listings")
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var leagueList: some View {
        if browser.leagues.isEmpty {
            Group {
                if let error = browser.leaguesError {
                    placeholder("exclamationmark.triangle", "Couldn’t load sports", error, retry: true)
                } else {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Loading sports")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $browser.selectedLeagueID) {
                ForEach(browser.leagues) { league in
                    HStack(spacing: 8) {
                        LeagueLogo(url: league.logo)
                        Text(league.name)
                            .lineLimit(1)
                    }
                    .tag(league.id)
                }
            }
            .listStyle(.sidebar)
            .accessibilityLabel("Sports")
        }
    }

    @ViewBuilder
    private var eventPane: some View {
        let shown = filteredEvents
        if browser.leagues.isEmpty {
            Color.clear
        } else if shown.isEmpty {
            if browser.isLoadingEvents {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Loading games…").font(.callout).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            } else if let error = browser.eventsError {
                placeholder("exclamationmark.triangle", "Couldn’t load games", error, retry: true)
            } else if !filter.isEmpty && !browser.events.isEmpty {
                placeholder("magnifyingglass", "No matching games", "Nothing in \(browser.selectedLeague?.name ?? "this sport") matches “\(filter)”.")
            } else {
                placeholder("calendar", "No games listed",
                            "\(browser.selectedLeague?.name ?? "This sport") has nothing scheduled right now.")
            }
        } else {
            List(selection: $selection) {
                ForEach(sections(shown), id: \.title) { section in
                    Section(section.title) {
                        ForEach(section.events) { event in
                            EventRow(event: event, isPlaying: playingURLs.contains(event.url)) { watch(event) }
                                .tag(event.id)
                        }
                    }
                }
            }
            .contextMenu(forSelectionType: DirectoryEvent.ID.self) { ids in
                if let event = event(for: ids) {
                    Button("Watch \(event.title)") { watch(event) }
                }
            } primaryAction: { ids in
                if let event = event(for: ids) { watch(event) }
            }
            .overlay(alignment: .topTrailing) {
                if browser.isLoadingEvents {
                    ProgressView()
                        .controlSize(.small)
                        .padding(10)
                        .accessibilityLabel("Refreshing games")
                }
            }
            .accessibilityLabel("Games")
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let message {
                Image(systemName: "exclamationmark.circle.fill")
                Text(message).lineLimit(2)
            } else {
                Text("Double-click or press Return to watch. Links usually go live about an hour before start.")
                    .lineLimit(1)
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(message == nil ? Color.secondary : Color.orange)
        .padding(.horizontal, 16)
        .frame(height: 34)
    }

    private var filteredEvents: [DirectoryEvent] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return browser.events }
        return browser.events.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private func sections(_ events: [DirectoryEvent]) -> [(title: String, events: [DirectoryEvent])] {
        var result: [(title: String, events: [DirectoryEvent])] = []
        for event in events {
            let title = event.day ?? "Games"
            if result.last?.title == title {
                result[result.count - 1].events.append(event)
            } else if let index = result.firstIndex(where: { $0.title == title }) {
                result[index].events.append(event)
            } else {
                result.append((title, [event]))
            }
        }
        return result
    }

    private func event(for ids: Set<DirectoryEvent.ID>) -> DirectoryEvent? {
        guard let id = ids.first else { return nil }
        return browser.events.first { $0.id == id }
    }

    private func watch(_ event: DirectoryEvent) {
        if let error = onWatch(event) {
            message = error
        } else {
            dismiss()
        }
    }

    private func placeholder(_ symbol: String, _ title: String, _ detail: String, retry: Bool = false) -> some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if retry {
                Button("Try again", action: browser.refresh)
                    .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EventRow: View {
    let event: DirectoryEvent
    let isPlaying: Bool
    let onWatch: () -> Void

    var body: some View {
        let status = event.status()
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .lineLimit(1)
                    .help(event.title)
                if let time = timeText {
                    Text(time)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            StatusBadge(status: status)
            if isPlaying {
                Label("Playing", systemImage: "play.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 72)
            } else {
                Button("Watch", action: onWatch)
                    .controlSize(.small)
                    .frame(width: 72)
                    .accessibilityLabel("Watch \(event.title)")
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    private var timeText: String? {
        if let start = event.start {
            return start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return event.startText
    }
}

private struct StatusBadge: View {
    let status: DirectoryEvent.Status

    var body: some View {
        switch status {
        case .live:
            badge("LIVE", color: .red, filled: true)
        case .channel:
            badge("24/7", color: .red, filled: false)
        case .startingSoon:
            badge("SOON", color: .orange, filled: false)
        case .earlier:
            badge("EARLIER", color: .secondary, filled: false)
        case .upcoming, .unscheduled:
            EmptyView()
        }
    }

    private func badge(_ text: String, color: Color, filled: Bool) -> some View {
        Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(filled ? Color.white : color)
            .background(filled ? AnyShapeStyle(color) : AnyShapeStyle(color.opacity(0.15)), in: Capsule())
    }
}

private struct LeagueLogo: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFit()
            } else {
                Image(systemName: "sportscourt")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 18, height: 18)
        .accessibilityHidden(true)
    }
}
