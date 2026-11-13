import AppKit
import SwiftUI

extension Notification.Name {
    static let showStreamLocation = Notification.Name("com.nik.crackstreams.show-location")
    static let showStreamBrowser = Notification.Name("com.nik.crackstreams.show-browser")
}

private struct BrowserTarget: Identifiable {
    let id = UUID()
    let slot: StreamSlot?
}

struct ContentView: View {
    @ObservedObject var store: StreamStore
    @StateObject private var browser = StreamBrowser()
    @State private var browserTarget: BrowserTarget?
    @State private var isPaletteVisible = false
    @State private var isWindowHovered = false
    @State private var isNearTopZone = false
    @State private var isPointerIdle = false
    @State private var isPointerOverChrome = false
    @State private var isWindowFullScreen = false
    @State private var didEnterFullScreenForPane = false
    @FocusState private var isLocationFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let launchHeaderHeight: CGFloat = 112
    private static let launchFooterHeight: CGFloat = 40

    var body: some View {
        ZStack(alignment: .top) {
            backdrop

            grid

            if isImmersive {
                immersiveChrome
            } else {
                VStack(spacing: 0) {
                    launchHeader
                    Spacer(minLength: 0)
                    launchFooter
                }
                .transition(.opacity)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 800, minHeight: 540)
        .preferredColorScheme(.dark)
        .background(
            WindowChromeConfigurator(
                isWindowHovered: $isWindowHovered,
                isNearTopZone: $isNearTopZone,
                isPointerIdle: $isPointerIdle,
                isImmersive: isImmersive,
                isPlayingAny: isPlayingAny,
                isLocationVisible: isPaletteVisible,
                isSheetPresented: browserTarget != nil,
                isPointerOverChrome: isPointerOverChrome,
                reduceMotion: reduceMotion
            )
        )
        .onDrop(of: [.url, .text], isTargeted: nil) { store.handleDrop($0) }
        .onReceive(NotificationCenter.default.publisher(for: .showStreamLocation)) { _ in showPalette() }
        .onReceive(NotificationCenter.default.publisher(for: .showStreamBrowser)) { _ in openBrowser(into: nil) }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isWindowFullScreen = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isWindowFullScreen = false
            didEnterFullScreenForPane = false
        }
        .sheet(item: $browserTarget) { target in
            BrowserView(
                browser: browser,
                destination: destination(for: target.slot),
                playingURLs: Set(store.slots.compactMap(\.sourceURL))
            ) { event in
                store.add(event.url, title: event.title, into: target.slot) ? nil : (store.message ?? "This stream could not be added.")
            }
        }
        .onChange(of: isImmersive) {
            if isImmersive {
                isPaletteVisible = false
                DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
            }
        }
        .onChange(of: browserTarget?.id) {
            if browserTarget == nil && isImmersive && !isPaletteVisible {
                DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
            }
        }
        .onChange(of: store.focusedSlotID) {
            if store.focusedSlotID == nil { exitPaneFullScreenIfNeeded() }
        }
        .background {
            Button("") { isPaletteVisible ? hidePalette() : showPalette() }
                .keyboardShortcut("l", modifiers: .command)
                .hidden()
            Button("") { handleEscape() }
                .keyboardShortcut(.escape, modifiers: [])
                .hidden()
        }
        .animation(reduceMotion ? .none : .easeOut(duration: 0.18), value: isPaletteVisible)
        .animation(reduceMotion ? .none : .easeOut(duration: 0.22), value: isImmersive)
        .animation(reduceMotion ? .none : .easeOut(duration: 0.18), value: isWindowHovered)
        .animation(reduceMotion ? .none : .easeOut(duration: 0.22), value: isPointerIdle)
        .animation(reduceMotion ? .none : .snappy(duration: 0.28), value: store.focusedSlotID)
    }

    private var isImmersive: Bool { store.slots.contains { !$0.isEmpty } }

    private var isPlayingAny: Bool {
        store.slots.contains {
            if case .playing = $0.state { return true }
            return false
        }
    }

    private var activeCount: Int { store.slots.count { !$0.isEmpty } }

    private var nextEmptyIndex: Int? { store.slots.firstIndex(where: \.isEmpty) }

    private var trimmedInput: String {
        store.input.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @ViewBuilder
    private var backdrop: some View {
        if isImmersive {
            Color.black
                .ignoresSafeArea()
        } else {
            ZStack {
                Theme.canvas
                RadialGradient(
                    colors: [Theme.accent.opacity(0.10), Theme.accentDeep.opacity(0.03), .clear],
                    center: .init(x: 0.5, y: 0.0),
                    startRadius: 20,
                    endRadius: 560
                )
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - Launch

    private var launchHeader: some View {
        VStack(spacing: 14) {
            ZStack {
                HStack(spacing: 9) {
                    BrandQuadMark(size: 15)
                    Text("Crackstreams")
                        .font(.system(size: 13, weight: .semibold))
                        .tracking(0.2)
                        .foregroundStyle(.white.opacity(0.92))
                }

                HStack {
                    // Leaves the hover-only traffic lights a clean corner.
                    Spacer(minLength: ChromeVisibility.trafficLightExclusionWidth)
                    browseButton
                }
            }
            .frame(height: 30)
            .padding(.top, 8)

            urlField(height: 46)
        }
        .padding(.horizontal, 20)
    }

    private var browseButton: some View {
        Button { openBrowser(into: nil) } label: {
            HStack(spacing: 7) {
                LiveDot(size: 6)
                Text("Live games")
                    .font(.system(size: 12, weight: .medium))
                Text("⌘B")
                    .font(.system(size: 10.5, weight: .medium).monospaced())
                    .foregroundStyle(.white.opacity(0.42))
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background(Color.white.opacity(0.06), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.75))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Browse live games on \(browser.home.host ?? "the stream site") (⌘B)")
        .accessibilityLabel("Browse live games")
    }

    private var launchFooter: some View {
        HStack(spacing: 14) {
            if let message = store.message {
                inlineWarning(message)
            } else {
                shortcutHint("⌘L", "Paste a link")
                shortcutHint("⌘B", "Live games")
                shortcutHint("⌘1–4", "Expand a pane")
                Text("Double-click video for full screen")
                    .foregroundStyle(.white.opacity(0.40))
                    .lineLimit(1)
            }
            Spacer(minLength: 12)
            HStack(spacing: 6) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 10))
                Text("Direct HLS · No ads or popups")
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(0.32))
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 22)
        .frame(height: Self.launchFooterHeight)
    }

    private func shortcutHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 6) {
            KeyCap(key)
            Text(label)
                .foregroundStyle(.white.opacity(0.48))
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private func inlineWarning(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.amber)
            Text(message)
                .lineLimit(1)
                .help(message)
                .foregroundStyle(.white.opacity(0.92))
            Button { store.message = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss message")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(Theme.amber.opacity(0.12), in: Capsule())
        .overlay(Capsule().stroke(Theme.amber.opacity(0.28), lineWidth: 0.75))
    }

    private func urlField(height: CGFloat) -> some View {
        let radius: CGFloat = height > 44 ? 12 : 10
        return HStack(spacing: 10) {
            Image(systemName: "link")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isLocationFocused ? Theme.accent : .white.opacity(0.40))
                .accessibilityHidden(true)

            TextField("Paste a watch page or .m3u8 link", text: $store.input)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($isLocationFocused)
                .onSubmit(submitLocation)
                .accessibilityLabel("Stream URL")

            if !store.input.isEmpty {
                Button { store.input = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.40))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear stream URL")
            } else if !isLocationFocused {
                KeyCap("⌘L")
                    .accessibilityHidden(true)
            }

            submitButton(height: height - 12)
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .frame(height: height)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Theme.glassBorder(highlighted: isLocationFocused), lineWidth: isLocationFocused ? 1.1 : 0.75)
        }
    }

    private func submitButton(height: CGFloat) -> some View {
        let isEnabled = !trimmedInput.isEmpty
        return Button(action: submitLocation) {
            HStack(spacing: 6) {
                Text("Play")
                    .font(.system(size: 12.5, weight: .semibold))
                Image(systemName: "return")
                    .font(.system(size: 10, weight: .bold))
                    .opacity(0.8)
            }
            .foregroundStyle(isEnabled ? Color.white : Color.white.opacity(0.34))
            .padding(.horizontal, 13)
            .frame(height: height)
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isEnabled ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.white.opacity(0.06)))
            }
            .shadow(color: isEnabled ? Theme.accentDeep.opacity(0.35) : .clear, radius: 8, y: 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.defaultAction)
        .disabled(!isEnabled)
        .accessibilityLabel("Add stream")
    }

    // MARK: - Immersive chrome

    /// One chrome layer per region: panes own their top edge, the dock owns the bottom
    /// center, and the palette only opens on request. Nothing reveals from the window's top edge.
    @ViewBuilder
    private var immersiveChrome: some View {
        if showsDock {
            dock
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 14)
                .transition(.opacity.combined(with: .offset(y: 8)))
        }

        if let message = store.message, !isPaletteVisible {
            messageBanner(message)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, showsDock ? 64 : 18)
        }

        if isPaletteVisible {
            palette
        }
    }

    private var showsDock: Bool {
        isWindowHovered && !isPointerIdle && !isPaletteVisible && browserTarget == nil
    }

    private var dock: some View {
        HStack(spacing: 2) {
            HStack(spacing: 3) {
                DockIconButton(
                    systemName: "square.grid.2x2",
                    label: "Show all four panes (⌘0)",
                    isSelected: store.focusedSlotID == nil
                ) {
                    store.focusedSlotID = nil
                }
                ForEach(Array(store.slots.enumerated()), id: \.element.id) { index, slot in
                    DockPaneChip(slot: slot, index: index, isFocused: store.focusedSlotID == slot.id) {
                        store.toggleFocus(slot)
                    }
                }
            }
            .padding(.horizontal, 3)

            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1, height: 16)
                .padding(.horizontal, 4)

            DockTextButton(title: "Add", help: "Add a stream (⌘L)", action: showPalette) {
                Image(systemName: "plus")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(Theme.accent)
            }
            DockTextButton(title: "Live games", help: "Browse live games (⌘B)", action: { openBrowser(into: nil) }) {
                LiveDot(size: 5.5)
            }
        }
        .padding(4)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().fill(Color.black.opacity(0.50)))
        }
        .overlay(Capsule().stroke(Theme.glassBorder(), lineWidth: 0.75))
        .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
        .onHover { isPointerOverChrome = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Multiview controls")
    }

    private var palette: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.48)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: hidePalette)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Text("ADD STREAM")
                        .font(.system(size: 10.5, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(.white.opacity(0.48))
                    Spacer()
                    KeyCap("esc")
                    Text("to close")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.36))
                }

                urlField(height: 48)

                HStack(spacing: 8) {
                    Image(systemName: nextEmptyIndex == nil ? "rectangle.fill.on.rectangle.fill" : "rectangle.inset.filled")
                        .font(.system(size: 11))
                        .foregroundStyle(nextEmptyIndex == nil ? Theme.amber : Theme.accent)
                    Text(paletteDestination)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.58))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    PalettePillButton(title: "Paste", systemName: "doc.on.clipboard", action: pasteIntoField)
                    PalettePillButton(title: "Live games", systemName: "dot.radiowaves.left.and.right") {
                        openBrowser(into: nil)
                    }
                }

                if let message = store.message {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.amber)
                        Text(message)
                            .foregroundStyle(.white.opacity(0.9))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.amber.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.amber.opacity(0.25), lineWidth: 0.75))
                }
            }
            .padding(16)
            .frame(maxWidth: 620)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.canvas.opacity(0.80)))
            }
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Theme.glassBorder(), lineWidth: 0.85))
            .shadow(color: .black.opacity(0.55), radius: 30, y: 14)
            .padding(.horizontal, 28)
            .padding(.top, 76)
            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
        }
        .transition(.opacity)
    }

    private var paletteDestination: String {
        guard let index = nextEmptyIndex else {
            return "All four panes are playing. Drop a link on a pane to replace it."
        }
        return activeCount == 0 ? "Plays in pane \(index + 1) with sound" : "Plays in pane \(index + 1), muted"
    }

    // MARK: - Multiview stage

    private var grid: some View {
        GeometryReader { geometry in
            let shown = visibleSlots
            let columns = store.focusedSlotID == nil ? 2 : 1
            let rows = store.focusedSlotID == nil ? 2 : 1
            let spacing: CGFloat = isImmersive ? 0 : 10
            let width = max(0, (geometry.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
            let height = max(0, (geometry.size.height - spacing * CGFloat(rows - 1)) / CGFloat(rows))

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns),
                spacing: spacing
            ) {
                ForEach(shown) { slot in
                    let slotIndex = store.slots.firstIndex(where: { $0.id == slot.id }) ?? 0
                    let isFocused = store.focusedSlotID == slot.id
                    StreamTile(
                        slot: slot,
                        slotIndex: slotIndex,
                        tileWidth: width,
                        isImmersive: isImmersive,
                        isFocused: isFocused,
                        isFullScreen: ChromeVisibility.isPaneFullScreen(isFocused: isFocused, isWindowFullScreen: isWindowFullScreen),
                        isNextTarget: slotIndex == nextEmptyIndex,
                        occupiesTrafficLightCorner: isImmersive && !isWindowFullScreen && (isFocused || slotIndex == 0),
                        isChromeSuppressed: isPaletteVisible || browserTarget != nil,
                        activeCount: activeCount,
                        isWindowHovered: isWindowHovered,
                        isPointerIdle: isPointerIdle,
                        onClose: { store.close(slot) },
                        onFocus: { store.toggleFocus(slot) },
                        onFullScreen: { toggleFullScreen(slot) },
                        onToggleAudio: { store.toggleAudio(slot, mixing: $0) },
                        onDrop: { store.handleDrop($0, into: slot) },
                        onPaste: { paste(into: slot) },
                        onBrowse: { openBrowser(into: slot) },
                        onChromeHover: { isPointerOverChrome = $0 }
                    )
                    .frame(width: width, height: height)
                }
            }
        }
        .padding(.horizontal, isImmersive ? 0 : 20)
        .padding(.top, isImmersive ? 0 : Self.launchHeaderHeight)
        .padding(.bottom, isImmersive ? 0 : Self.launchFooterHeight)
    }

    private func messageBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.amber)
            Text(message)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(2)
            Button { store.message = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(width: 20, height: 20)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss message")
        }
        .foregroundStyle(.white)
        .padding(.leading, 14)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().fill(Theme.canvas.opacity(0.82)))
        }
        .overlay(Capsule().stroke(Theme.amber.opacity(0.32), lineWidth: 0.85))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        .padding(.horizontal, 24)
        .accessibilityLabel(message)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private var visibleSlots: [StreamSlot] {
        if let id = store.focusedSlotID, let slot = store.slots.first(where: { $0.id == id }) {
            return [slot]
        }
        return store.slots
    }

    // MARK: - Actions

    private func showPalette() {
        if isImmersive {
            isPaletteVisible = true
            isPointerIdle = false
        }
        DispatchQueue.main.async { isLocationFocused = true }
    }

    private func hidePalette() {
        isLocationFocused = false
        isPaletteVisible = false
    }

    private func handleEscape() {
        if isPaletteVisible {
            hidePalette()
        } else if store.focusedSlotID != nil {
            store.focusedSlotID = nil
        } else {
            isLocationFocused = false
        }
    }

    private func submitLocation() {
        if store.addFromInput() && isImmersive { hidePalette() }
    }

    private func openBrowser(into slot: StreamSlot?) {
        hidePalette()
        browserTarget = BrowserTarget(slot: slot)
    }

    private func toggleFullScreen(_ slot: StreamSlot) {
        guard let window = NSApp.mainWindow else { return }
        let isFull = window.styleMask.contains(.fullScreen)
        if ChromeVisibility.isPaneFullScreen(isFocused: store.focusedSlotID == slot.id, isWindowFullScreen: isFull) {
            // The collapse handler performs the single exit, even for a full screen the user entered.
            didEnterFullScreenForPane = true
            store.focusedSlotID = nil
            return
        }
        store.focusedSlotID = slot.id
        if !isFull {
            didEnterFullScreenForPane = true
            window.toggleFullScreen(nil)
        }
    }

    private func exitPaneFullScreenIfNeeded() {
        guard let window = NSApp.mainWindow else { return }
        let isFull = window.styleMask.contains(.fullScreen)
        if ChromeVisibility.shouldExitFullScreenOnCollapse(enteredForPane: didEnterFullScreenForPane, isWindowFullScreen: isFull) {
            window.toggleFullScreen(nil)
        }
        didEnterFullScreenForPane = false
    }

    private func destination(for slot: StreamSlot?) -> String {
        guard let slot, let index = store.slots.firstIndex(where: { $0 === slot }) else {
            return "Plays in the next free pane"
        }
        return slot.isEmpty ? "Plays in pane \(index + 1)" : "Replaces pane \(index + 1)"
    }

    private func pasteIntoField() {
        guard let text = NSPasteboard.general.string(forType: .string)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            store.message = "The clipboard is empty."
            return
        }
        store.input = text
        isLocationFocused = true
    }

    private func paste(into slot: StreamSlot) {
        guard let text = NSPasteboard.general.string(forType: .string),
              let url = StreamStore.validURL(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            store.message = "The clipboard does not contain a valid stream URL."
            return
        }
        store.add(url, into: slot)
    }
}

// MARK: - Stream Tile

private struct StreamTile: View {
    @ObservedObject var slot: StreamSlot
    let slotIndex: Int
    let tileWidth: CGFloat
    let isImmersive: Bool
    let isFocused: Bool
    let isFullScreen: Bool
    let isNextTarget: Bool
    let occupiesTrafficLightCorner: Bool
    let isChromeSuppressed: Bool
    let activeCount: Int
    let isWindowHovered: Bool
    let isPointerIdle: Bool
    let onClose: () -> Void
    let onFocus: () -> Void
    let onFullScreen: () -> Void
    let onToggleAudio: (_ mixing: Bool) -> Void
    let onDrop: ([NSItemProvider]) -> Bool
    let onPaste: () -> Void
    let onBrowse: () -> Void
    let onChromeHover: (Bool) -> Void

    @State private var isDropTargeted = false
    @State private var isHovering = false
    @State private var pulseResolving = false
    @FocusState private var isTileFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsControls: Bool {
        !slot.isEmpty && !isChromeSuppressed && ((isHovering && isWindowHovered && !isPointerIdle) || isTileFocused)
    }

    private var isPlaying: Bool {
        if case .playing = slot.state { return true }
        return false
    }

    private var isWide: Bool { tileWidth >= 560 }

    private var tileCornerRadius: CGFloat {
        isImmersive ? 0 : 14
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isImmersive ? Color.black : Theme.cardFill)
            .clipShape(RoundedRectangle(cornerRadius: tileCornerRadius, style: .continuous))
            .overlay {
                if !isImmersive {
                    RoundedRectangle(cornerRadius: tileCornerRadius, style: .continuous)
                        .stroke(
                            isDropTargeted
                                ? AnyShapeStyle(Theme.accent)
                                : AnyShapeStyle(Theme.glassBorder(highlighted: isHovering || isTileFocused)),
                            lineWidth: isDropTargeted ? 1.5 : 0.85
                        )
                        .allowsHitTesting(false)
                } else if !isFocused && !isPlaying {
                    Rectangle()
                        .stroke(Color.white.opacity(0.05), lineWidth: 0.5)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .top) {
                if showsControls {
                    tileControlBar
                        .transition(.opacity)
                }
            }
            .overlay {
                if slot.isBuffering, case .playing = slot.state {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Buffering…")
                            .font(.system(size: 12.5, weight: .medium))
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background {
                        Capsule()
                            .fill(.ultraThinMaterial)
                            .overlay(Capsule().fill(Color.black.opacity(0.55)))
                    }
                    .overlay(Capsule().stroke(Color.white.opacity(0.14), lineWidth: 0.75))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 12, y: 4)
                    .allowsHitTesting(false)
                }
            }
            .overlay {
                if isDropTargeted {
                    ZStack {
                        RoundedRectangle(cornerRadius: tileCornerRadius, style: .continuous)
                            .fill(Theme.accent.opacity(0.15))
                        VStack(spacing: 8) {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(Theme.accent)
                            Text(slot.isEmpty ? "Drop to play in pane \(slotIndex + 1)" : "Drop to replace \(slot.title)")
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.url, .text], isTargeted: $isDropTargeted, perform: onDrop)
            .background(HoverSensor(isHovering: $isHovering, reduceMotion: reduceMotion))
            // Keyboard-only focus: a click on video must not pin the controls open.
            .focusable(interactions: .activate)
            .focused($isTileFocused)
            .focusEffectDisabled()
            .onChange(of: isWindowHovered) {
                if !isWindowHovered {
                    isHovering = false
                    isTileFocused = false
                }
            }
            .onChange(of: slot.state) {
                if slot.state != .idle {
                    isTileFocused = false
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(slot.isEmpty ? "Pane \(slotIndex + 1), empty" : slot.title)
    }

    private var tileControlBar: some View {
        HStack(alignment: .center, spacing: 8) {
            HStack(spacing: 7) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 6.5, height: 6.5)
                    .shadow(color: statusDotColor.opacity(0.8), radius: 4)
                Text(slot.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                    .help(slot.title)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(Capsule().fill(Color.black.opacity(0.42)))
            }
            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
            .layoutPriority(-1)

            Spacer(minLength: 8)

            HStack(spacing: 0) {
                PaneIconButton(
                    systemName: slot.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    label: audioLabel,
                    tint: slot.isMuted ? .white.opacity(0.55) : .white
                ) {
                    onToggleAudio(NSEvent.modifierFlags.contains(.option))
                }
                if isWide && !slot.isMuted {
                    Slider(value: volumeBinding, in: 0...1)
                        .controlSize(.mini)
                        .tint(.white)
                        .frame(width: 64)
                        .padding(.horizontal, 4)
                        .accessibilityLabel("Volume for \(slot.title)")
                }

                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 1, height: 14)
                    .padding(.horizontal, 3)

                if isWide {
                    PaneIconButton(systemName: "list.bullet.rectangle", label: "Replace \(slot.title) with another game", action: onBrowse)
                }
                PaneIconButton(
                    systemName: isFocused ? "square.grid.2x2" : "rectangle.inset.filled",
                    label: isFocused ? "Show all four panes" : "Expand \(slot.title) in the window",
                    action: onFocus
                )
                PaneIconButton(
                    systemName: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    label: isFullScreen ? "Exit full screen" : "Full screen \(slot.title)",
                    action: onFullScreen
                )
                PaneIconButton(systemName: "xmark", label: "Close \(slot.title)", action: onClose)
            }
            .padding(2)
            .background {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(Capsule().fill(Color.black.opacity(0.45)))
            }
            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5))
            .fixedSize()
            .onHover(perform: onChromeHover)
        }
        .padding(.leading, occupiesTrafficLightCorner ? ChromeVisibility.trafficLightExclusionWidth : 10)
        .padding(.trailing, 10)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .foregroundStyle(.white)
        .background(alignment: .top) {
            LinearGradient(
                colors: [Color.black.opacity(0.78), Color.black.opacity(0.30), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 84)
            .allowsHitTesting(false)
        }
        .onDisappear { onChromeHover(false) }
    }

    private var audioLabel: String {
        if !slot.isMuted { return "Mute \(slot.title)" }
        return activeCount > 1 ? "Listen to \(slot.title) (Option-click to mix)" : "Unmute \(slot.title)"
    }

    private var volumeBinding: Binding<Double> {
        Binding(get: { Double(slot.volume) }, set: { slot.volume = Float($0) })
    }

    private var statusDotColor: Color {
        switch slot.state {
        case .playing:
            return slot.isBuffering ? Theme.amber : Theme.live
        case .resolving:
            return Theme.accent
        case .failed:
            return Theme.amber
        case .idle:
            return .secondary
        }
    }

    @ViewBuilder
    private var content: some View {
        switch slot.state {
        case .idle:
            idleContent
        case .resolving:
            resolvingContent
        case .playing:
            PlayerView(player: slot.player, onDoubleClick: onFullScreen)
        case .failed(let message):
            failedContent(message)
        }
    }

    private var isRevealed: Bool {
        isHovering || isTileFocused || isDropTargeted || (!isImmersive && isNextTarget)
    }

    private var idleContent: some View {
        ZStack {
            if isImmersive {
                Color(red: 0.016, green: 0.020, blue: 0.030)
            } else {
                RadialGradient(
                    colors: [Theme.accent.opacity(isHovering ? 0.08 : (isNextTarget ? 0.05 : 0.0)), .clear],
                    center: .top,
                    startRadius: 8,
                    endRadius: 300
                )
            }

            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(isRevealed ? 0.07 : 0.04))
                        .frame(width: 42, height: 42)
                    Circle()
                        .strokeBorder(
                            isRevealed ? Theme.accent.opacity(0.5) : Color.white.opacity(0.12),
                            style: StrokeStyle(lineWidth: 1, dash: isRevealed ? [] : [3, 3])
                        )
                        .frame(width: 42, height: 42)
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(isRevealed ? Theme.accent : .white.opacity(0.45))
                }
                .accessibilityHidden(true)

                VStack(spacing: 4) {
                    Text(isNextTarget ? "Add a stream" : "Empty pane")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(isRevealed ? 0.92 : 0.55))
                    Text("Pick a live game, paste a link, or drop one here")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.40))
                        .multilineTextAlignment(.center)
                }

                HStack(spacing: 8) {
                    tilePillButton("Live games", icon: "dot.radiowaves.left.and.right", prominent: true, action: onBrowse)
                    tilePillButton("Paste link", icon: "doc.on.clipboard", prominent: false, action: onPaste)
                }
                .padding(.top, 2)
                .opacity(isRevealed ? 1 : 0)
                .allowsHitTesting(isRevealed)
            }
            .padding(16)
            .opacity(isImmersive && !isRevealed ? 0.35 : 1)
        }
        .overlay(alignment: .topLeading) {
            if !isImmersive {
                HStack(spacing: 7) {
                    Text("\(slotIndex + 1)")
                        .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 18, height: 18)
                        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    if isNextTarget {
                        Text("NEXT")
                            .font(.system(size: 9.5, weight: .semibold))
                            .tracking(0.6)
                            .foregroundStyle(Theme.accent.opacity(0.85))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .accessibilityHidden(true)
            }
        }
    }

    private var resolvingContent: some View {
        VStack(spacing: 14) {
            ZStack {
                Circle()
                    .stroke(Theme.accent.opacity(0.22), lineWidth: 1.5)
                    .frame(width: 52, height: 52)
                    .scaleEffect(pulseResolving && !reduceMotion ? 1.25 : 0.92)
                    .opacity(pulseResolving && !reduceMotion ? 0.0 : 0.8)
                Circle()
                    .fill(Theme.accent.opacity(0.10))
                    .frame(width: 42, height: 42)
                ProgressView()
                    .controlSize(.regular)
            }
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 1.35).repeatForever(autoreverses: false)) {
                    pulseResolving = true
                }
            }
            .onDisappear { pulseResolving = false }

            VStack(spacing: 4) {
                Text(slot.title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                Text("Finding the live feed…")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.50))
            }

            Button("Cancel", action: onClose)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.white.opacity(0.07), in: Capsule())
                .buttonStyle(.plain)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isImmersive ? Color(red: 0.016, green: 0.020, blue: 0.030) : Theme.canvas)
        .accessibilityElement(children: .contain)
    }

    private func failedContent(_ message: String) -> some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Theme.amber.opacity(0.12))
                    .frame(width: 44, height: 44)
                    .overlay(Circle().stroke(Theme.amber.opacity(0.32), lineWidth: 0.75))
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Theme.amber)
            }
            .accessibilityHidden(true)

            VStack(spacing: 4) {
                Text("Couldn’t play this stream")
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.55))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .frame(maxWidth: 360)
            }

            HStack(spacing: 8) {
                tilePillButton("Try again", icon: "arrow.clockwise", prominent: true, action: slot.retry)
                tilePillButton("Live games", icon: "list.bullet.rectangle", prominent: false, action: onBrowse)
                tilePillButton("Close", icon: "xmark", prominent: false, action: onClose)
            }
            .padding(.top, 2)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(isImmersive ? Color(red: 0.016, green: 0.020, blue: 0.030) : Theme.canvas)
        .accessibilityElement(children: .contain)
    }

    private func tilePillButton(_ title: String, icon: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5.5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(prominent ? Theme.accent : .white.opacity(0.65))
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
            }
            .padding(.horizontal, 11)
            .frame(height: 28)
            .background {
                Capsule()
                    .fill(prominent ? Theme.accent.opacity(0.13) : Color.white.opacity(0.06))
            }
            .overlay {
                Capsule()
                    .stroke(prominent ? Theme.accent.opacity(0.34) : Color.white.opacity(0.10), lineWidth: 0.75)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}

// MARK: - Chrome Components

private struct LiveDot: View {
    var size: CGFloat = 6

    var body: some View {
        Circle()
            .fill(Theme.live)
            .frame(width: size, height: size)
            .shadow(color: Theme.live.opacity(0.7), radius: 4)
            .accessibilityHidden(true)
    }
}

private struct KeyCap: View {
    let key: String

    init(_ key: String) { self.key = key }

    var body: some View {
        Text(key)
            .font(.system(size: 10.5, weight: .semibold).monospaced())
            .foregroundStyle(.white.opacity(0.62))
            .padding(.horizontal, 5.5)
            .padding(.vertical, 1.5)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(Color.white.opacity(0.09), lineWidth: 0.5))
    }
}

private struct PaneIconButton: View {
    let systemName: String
    let label: String
    var tint: Color = .white
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 28)
                .background(Capsule().fill(Color.white.opacity(isHovered ? 0.16 : 0)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct DockIconButton: View {
    let systemName: String
    let label: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(isSelected ? Theme.accent : .white.opacity(0.75))
                .frame(width: 30, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? Theme.accent.opacity(0.16) : Color.white.opacity(isHovered ? 0.10 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Dock chip for one pane: shows whether it plays, has the sound, or is expanded.
private struct DockPaneChip: View {
    @ObservedObject var slot: StreamSlot
    let index: Int
    let isFocused: Bool
    let action: () -> Void

    @State private var isHovered = false

    private var isAudible: Bool { !slot.isEmpty && !slot.isMuted }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text("\(index + 1)")
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                if isAudible {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(.system(size: 7.5, weight: .bold))
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, 8)
            .frame(minWidth: 26)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(background)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(slot.isEmpty ? Color.white.opacity(0.10) : .clear, style: StrokeStyle(lineWidth: 0.75, dash: [2, 2]))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(slot.isEmpty)
        .onHover { isHovered = $0 }
        .help(slot.isEmpty ? "Pane \(index + 1) is empty" : (isFocused ? "Show all four panes" : "Expand \(slot.title) (⌘\(index + 1))"))
        .accessibilityLabel(slot.isEmpty ? "Pane \(index + 1), empty" : "Pane \(index + 1), \(slot.title)\(isAudible ? ", playing sound" : "")")
        .accessibilityAddTraits(isFocused ? .isSelected : [])
    }

    private var foreground: Color {
        if slot.isEmpty { return .white.opacity(0.28) }
        if isFocused { return Theme.accent }
        return isAudible ? .white : .white.opacity(0.70)
    }

    private var background: Color {
        if isFocused { return Theme.accent.opacity(0.18) }
        if slot.isEmpty { return .clear }
        return Color.white.opacity(isHovered ? 0.16 : 0.08)
    }
}

private struct DockTextButton<Icon: View>: View {
    let title: String
    let help: String
    let action: () -> Void
    @ViewBuilder let icon: () -> Icon

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                icon()
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.92))
            .padding(.horizontal, 11)
            .frame(height: 26)
            .background(Capsule().fill(Color.white.opacity(isHovered ? 0.12 : 0)))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
        .accessibilityLabel(title)
    }
}

private struct PalettePillButton: View {
    let title: String
    let systemName: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemName)
                    .font(.system(size: 10.5, weight: .semibold))
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(Capsule().fill(Color.white.opacity(isHovered ? 0.12 : 0.06)))
            .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 0.75))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(title)
    }
}

// MARK: - Tile Hover Sensor

private struct HoverSensor: NSViewRepresentable {
    @Binding var isHovering: Bool
    let reduceMotion: Bool

    func makeNSView(context: Context) -> NSView {
        let view = HoverTrackingView()
        view.onHoverChange = { hovering in
            DispatchQueue.main.async {
                guard isHovering != hovering else { return }
                withAnimation(reduceMotion ? .none : .easeOut(duration: 0.15)) {
                    isHovering = hovering
                }
            }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

private final class HoverTrackingView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseMoved(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}
