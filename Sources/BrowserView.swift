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

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
            HStack(spacing: 0) {
                leagueSidebar
                    .frame(width: 196)
                Rectangle()
                    .fill(Color.white.opacity(0.07))
                    .frame(width: 1)
                eventPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 1)
            footer
        }
        .frame(width: 760, height: 492)
        .background(Theme.canvas)
        .preferredColorScheme(.dark)
        .onAppear { browser.open() }
        .onChange(of: browser.selectedLeagueID) {
            selection = nil
            message = nil
        }
        .background {
            Button("") { watchSelected() }
                .keyboardShortcut(.return, modifiers: [])
                .disabled(selectedEvent == nil || isFilterFocused)
                .hidden()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            HStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Theme.accent.opacity(0.12))
                        .frame(width: 36, height: 36)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Theme.accent.opacity(0.28), lineWidth: 0.75)
                        )
                    BrandQuadMark(size: 16)
                }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text("Live Sports Directory")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.96))
                        if liveStreamCount > 0 {
                            HStack(spacing: 4.5) {
                                Circle()
                                    .fill(Theme.live)
                                    .frame(width: 5.5, height: 5.5)
                                Text("\(liveStreamCount) LIVE")
                                    .font(.system(size: 10, weight: .bold).monospacedDigit())
                                    .tracking(0.4)
                            }
                            .foregroundStyle(Theme.live)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2.5)
                            .background(Theme.live.opacity(0.14), in: Capsule())
                            .overlay(Capsule().stroke(Theme.live.opacity(0.28), lineWidth: 0.5))
                        }
                    }

                    HStack(spacing: 6) {
                        Text(browser.home.host ?? "Stream site")
                            .foregroundStyle(.white.opacity(0.45))
                        Text("·")
                            .foregroundStyle(.white.opacity(0.28))
                        Text(destination)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 6.5)
                            .padding(.vertical, 1.5)
                            .background(Theme.accent.opacity(0.12), in: Capsule())
                    }
                    .font(.system(size: 11.5))
                }
            }

            Spacer()

            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isFilterFocused ? Theme.accent : .white.opacity(0.42))
                        .accessibilityHidden(true)
                    TextField("Filter games", text: $filter)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .focused($isFilterFocused)
                        .accessibilityLabel("Filter games")
                    if !filter.isEmpty {
                        Button { filter = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.white.opacity(0.45))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear game filter")
                    }
                }
                .padding(.horizontal, 10)
                .frame(width: 215, height: 32)
                .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Theme.glassBorder(highlighted: isFilterFocused), lineWidth: isFilterFocused ? 1.1 : 0.75)
                }

                Button(action: browser.refresh) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.10), lineWidth: 0.75))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("r", modifiers: .command)
                .disabled(browser.isLoadingLeagues || browser.isLoadingEvents)
                .help("Refresh (⌘R)")
                .accessibilityLabel("Refresh listings")

                Button("Done") { dismiss() }
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 13)
                    .frame(height: 32)
                    .background(Color.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 0.75))
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Theme.elevated.opacity(0.55))
    }

    @ViewBuilder
    private var leagueSidebar: some View {
        if browser.leagues.isEmpty {
            Group {
                if let error = browser.leaguesError {
                    placeholder("exclamationmark.triangle.fill", "Couldn’t load sports", error, retry: true)
                } else {
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading sports…")
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Loading sports")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.opacity(0.22))
        } else {
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(browser.leagues) { league in
                        LeagueSidebarRow(
                            league: league,
                            isSelected: browser.selectedLeagueID == league.id
                        ) {
                            browser.selectedLeagueID = league.id
                        }
                    }
                }
                .padding(10)
            }
            .background(Color.black.opacity(0.22))
            .accessibilityElement(children: .contain)
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
                    Text("Loading games…")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.52))
                }
                .accessibilityElement(children: .combine)
            } else if let error = browser.eventsError {
                placeholder("exclamationmark.triangle.fill", "Couldn’t load games", error, retry: true)
            } else if !filter.isEmpty && !browser.events.isEmpty {
                VStack(spacing: 12) {
                    placeholder(
                        "magnifyingglass",
                        "No matching games",
                        "Nothing in \(browser.selectedLeague?.name ?? "this sport") matches “\(filter)”."
                    )
                    .frame(maxHeight: 160)
                    Button("Clear filter") { filter = "" }
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Theme.accent.opacity(0.12), in: Capsule())
                        .overlay(Capsule().stroke(Theme.accent.opacity(0.30), lineWidth: 0.75))
                        .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                placeholder(
                    "calendar",
                    "No games listed",
                    "\(browser.selectedLeague?.name ?? "This sport") has nothing scheduled right now."
                )
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 6, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections(shown), id: \.title) { section in
                        Section {
                            ForEach(section.events) { event in
                                EventRow(
                                    event: event,
                                    isPlaying: playingURLs.contains(event.url),
                                    isSelected: selection == event.id,
                                    onSelect: { selection = event.id },
                                    onWatch: { watch(event) }
                                )
                            }
                        } header: {
                            HStack {
                                Text(section.title.uppercased())
                                    .font(.system(size: 10.5, weight: .bold))
                                    .tracking(0.75)
                                    .foregroundStyle(.white.opacity(0.45))
                                Spacer()
                                Text("\(section.events.count)")
                                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(.white.opacity(0.38))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1.5)
                                    .background(Color.white.opacity(0.06), in: Capsule())
                            }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 7)
                            .background(Theme.canvas.opacity(0.94))
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .overlay(alignment: .topTrailing) {
                if browser.isLoadingEvents {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Refreshing")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.65))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(12)
                    .accessibilityLabel("Refreshing games")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Games")
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let message {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.amber)
                Text(message)
                    .lineLimit(2)
                    .foregroundStyle(Theme.amber)
            } else if let refreshError {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.amber)
                Text(refreshError)
                    .lineLimit(2)
                    .foregroundStyle(Theme.amber)
                Button("Try again", action: browser.refresh)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.10), in: Capsule())
                    .buttonStyle(.plain)
            } else {
                Image(systemName: "sparkles.tv")
                    .foregroundStyle(Theme.accent.opacity(0.75))
                Text("Double-click a matchup or click Watch. Feeds typically go live up to an hour before kickoff.")
                    .lineLimit(1)
                    .foregroundStyle(.white.opacity(0.46))
            }
            Spacer()
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 18)
        .frame(height: 36)
        .background(Theme.elevated.opacity(0.40))
    }

    private var liveStreamCount: Int {
        browser.events.count {
            let status = $0.status()
            return status == .live || status == .channel
        }
    }

    /// Failures that would otherwise be hidden behind listings that are still on screen.
    private var refreshError: String? {
        if let error = browser.eventsError, !browser.events.isEmpty {
            return "Showing earlier listings. \(error)"
        }
        if let error = browser.leaguesError, !browser.leagues.isEmpty {
            return "Couldn’t refresh sports. \(error)"
        }
        return nil
    }

    private var filteredEvents: [DirectoryEvent] {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return browser.events }
        return browser.events.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    private var selectedEvent: DirectoryEvent? {
        guard let selection else { return nil }
        return filteredEvents.first { $0.id == selection }
    }

    private func watchSelected() {
        if let selectedEvent { watch(selectedEvent) }
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

    private func watch(_ event: DirectoryEvent) {
        if let error = onWatch(event) {
            message = error
        } else {
            dismiss()
        }
    }

    private func placeholder(_ symbol: String, _ title: String, _ detail: String, retry: Bool = false) -> some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.05))
                    .frame(width: 42, height: 42)
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(retry ? Theme.amber : .white.opacity(0.5))
            }
            .accessibilityHidden(true)

            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
            Text(detail)
                .font(.system(size: 12.5))
                .foregroundStyle(.white.opacity(0.52))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            if retry {
                Button("Try again", action: browser.refresh)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Theme.accent.opacity(0.18), in: Capsule())
                    .overlay(Capsule().stroke(Theme.accent.opacity(0.38), lineWidth: 0.75))
                    .buttonStyle(.plain)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Sidebar Row

private struct LeagueSidebarRow: View {
    let league: DirectoryLeague
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                LeagueLogo(url: league.logo)
                Text(league.name)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? .white : .white.opacity(0.75))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if isSelected {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 5, height: 5)
                        .shadow(color: Theme.accent.opacity(0.8), radius: 4)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        isSelected
                            ? Theme.accent.opacity(0.16)
                            : (isHovering ? Color.white.opacity(0.055) : Color.clear)
                    )
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Theme.accent.opacity(0.34), lineWidth: 0.75)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel(league.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Event Card Row

private struct EventRow: View {
    let event: DirectoryEvent
    let isPlaying: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onWatch: () -> Void

    @State private var isHovering = false

    var body: some View {
        let status = event.status()
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(indicatorColor(for: status))
                .frame(width: 3, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                    .help(event.title)

                if let time = timeText {
                    HStack(spacing: 4.5) {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                        Text(time)
                            .font(.system(size: 11.5).monospacedDigit())
                    }
                    .foregroundStyle(.white.opacity(0.46))
                }
            }

            Spacer(minLength: 8)

            StatusBadge(status: status)

            if isPlaying {
                HStack(spacing: 5) {
                    Image(systemName: "waveform")
                        .font(.system(size: 10.5, weight: .bold))
                    Text("Playing")
                        .font(.system(size: 11.5, weight: .semibold))
                }
                .foregroundStyle(Theme.emerald)
                .padding(.horizontal, 11)
                .frame(height: 28)
                .background(Theme.emerald.opacity(0.14), in: Capsule())
                .overlay(Capsule().stroke(Theme.emerald.opacity(0.32), lineWidth: 0.75))
            } else {
                Button(action: onWatch) {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9.5, weight: .bold))
                        Text("Watch")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(isProminentCTA(status) ? Color.white : Color.white.opacity(0.9))
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background {
                        Capsule()
                            .fill(
                                isProminentCTA(status)
                                    ? AnyShapeStyle(Theme.accentGradient)
                                    : AnyShapeStyle(Color.white.opacity(0.08))
                            )
                    }
                    .overlay {
                        Capsule()
                            .stroke(
                                isProminentCTA(status)
                                    ? Color.white.opacity(0.22)
                                    : Color.white.opacity(0.12),
                                lineWidth: 0.75
                            )
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Watch \(event.title)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(
                    isSelected
                        ? Theme.accent.opacity(0.11)
                        : (isHovering ? Color.white.opacity(0.055) : Color.white.opacity(0.026))
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    isPlaying
                        ? Theme.emerald.opacity(0.32)
                        : (isSelected ? Theme.accent.opacity(0.42) : Color.white.opacity(isHovering ? 0.11 : 0.055)),
                    lineWidth: 0.75
                )
        }
        .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .onHover { isHovering = $0 }
        .onTapGesture(count: 2, perform: onWatch)
        .simultaneousGesture(TapGesture().onEnded(onSelect))
        .contextMenu {
            Button("Watch \(event.title)", action: onWatch)
        }
        .accessibilityElement(children: .contain)
    }

    private func isProminentCTA(_ status: DirectoryEvent.Status) -> Bool {
        isHovering || isSelected || status == .live || status == .channel
    }

    private func indicatorColor(for status: DirectoryEvent.Status) -> Color {
        switch status {
        case .live, .channel:
            return Theme.live
        case .startingSoon:
            return Theme.amber
        case .upcoming:
            return Theme.accent.opacity(0.45)
        case .earlier, .unscheduled:
            return Color.white.opacity(0.14)
        }
    }

    private var timeText: String? {
        if let start = event.start {
            return start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return event.startText
    }
}

// MARK: - Status & League Badges

private struct StatusBadge: View {
    let status: DirectoryEvent.Status

    var body: some View {
        switch status {
        case .live:
            badge("LIVE", color: Theme.live, filled: true, dot: true)
        case .channel:
            badge("24/7", color: Theme.live, filled: false, dot: false)
        case .startingSoon:
            badge("SOON", color: Theme.amber, filled: false, dot: false)
        case .earlier:
            badge("EARLIER", color: .white.opacity(0.55), filled: false, dot: false)
        case .upcoming, .unscheduled:
            EmptyView()
        }
    }

    private func badge(_ text: String, color: Color, filled: Bool, dot: Bool) -> some View {
        HStack(spacing: 4) {
            if dot {
                Circle()
                    .fill(Color.white)
                    .frame(width: 5, height: 5)
            }
            Text(text)
                .font(.system(size: 10, weight: .bold))
                .tracking(0.45)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(filled ? Color.white : color)
        .background(filled ? AnyShapeStyle(color) : AnyShapeStyle(color.opacity(0.14)), in: Capsule())
        .overlay(Capsule().stroke(filled ? Color.white.opacity(0.20) : color.opacity(0.28), lineWidth: 0.5))
    }
}

private struct LeagueLogo: View {
    let url: URL?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .frame(width: 24, height: 24)
            AsyncImage(url: url) { phase in
                if let image = phase.image {
                    image
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "sportscourt")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
        .accessibilityHidden(true)
    }
}
