import AppKit
import SwiftUI

extension Notification.Name {
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
    @State private var isWindowHovered = false
    @State private var isPointerIdle = false
    @FocusState private var isLocationFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .top) {
            backdrop

            grid

            if !isImmersive {
                VStack(spacing: 0) {
                    launchHeader
                    Spacer(minLength: 0)
                    launchFooter
                }
                .transition(.opacity)
            } else {
                immersiveChrome
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 800, minHeight: 540)
        .preferredColorScheme(.dark)
        .background(
            WindowChromeConfigurator(
                isWindowHovered: $isWindowHovered,
                isPointerIdle: $isPointerIdle,
                isImmersive: isImmersive,
                isPlayingAny: isPlayingAny,
                isSheetPresented: browserTarget != nil,
                reduceMotion: reduceMotion
            )
        )
        .onDrop(of: [.url, .text], isTargeted: nil) { store.handleDrop($0) }
        .onReceive(NotificationCenter.default.publisher(for: .showStreamBrowser)) { _ in openBrowser(into: nil) }
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
                DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
            }
        }
        .onChange(of: browserTarget?.id) {
            if browserTarget == nil && isImmersive {
                DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
            }
        }
        .animation(reduceMotion ? .none : .easeOut(duration: 0.22), value: isImmersive)
        .animation(reduceMotion ? .none : .easeOut(duration: 0.18), value: isWindowHovered)
        .animation(reduceMotion ? .none : .easeOut(duration: 0.22), value: isPointerIdle)
    }

    private var isImmersive: Bool { store.slots.contains { !$0.isEmpty } }

    private var isPlayingAny: Bool {
        store.slots.contains {
            if case .playing = $0.state { return true }
            return false
        }
    }

    private var activeCount: Int { store.slots.count { !$0.isEmpty } }

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
                    colors: [Theme.accent.opacity(0.11), Theme.accentDeep.opacity(0.04), .clear],
                    center: .init(x: 0.5, y: 0.0),
                    startRadius: 20,
                    endRadius: 520
                )
            }
            .ignoresSafeArea()
        }
    }

    // MARK: - Launch Studio Header & Footer

    private var launchHeader: some View {
        VStack(spacing: 10) {
            ZStack {
                HStack(spacing: 9) {
                    BrandQuadMark(size: 16)
                    Text("Crackstreams")
                        .font(.system(size: 13.5, weight: .semibold))
                        .tracking(0.15)
                        .foregroundStyle(.white.opacity(0.95))
                    Text("\(activeCount) / 4")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.58))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2.5)
                        .background(Color.white.opacity(0.07), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.08), lineWidth: 0.5))
                        .accessibilityLabel("\(activeCount) of 4 panes occupied")
                }

                HStack {
                    // Reserves clean space on the left for hover-only macOS traffic lights.
                    Spacer(minLength: 88)
                    Button { openBrowser(into: nil) } label: {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(Theme.live)
                                .frame(width: 6, height: 6)
                                .shadow(color: Theme.live.opacity(0.7), radius: 4)
                            Text("Browse")
                                .font(.system(size: 12, weight: .medium))
                            Text("⌘B")
                                .font(.system(size: 10.5, weight: .medium).monospaced())
                                .foregroundStyle(.white.opacity(0.48))
                        }
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 11)
                        .frame(height: 26)
                        .background(Color.white.opacity(0.065), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.11), lineWidth: 0.75))
                    }
                    .buttonStyle(.plain)
                    .help("Browse games on \(browser.home.host ?? "the stream site") (⌘B)")
                    .accessibilityLabel("Browse")
                }
            }
            .frame(height: 34)
            .padding(.top, 2)

            HStack(spacing: 10) {
                urlInputField(height: 42)

                Button(action: submitLocation) {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 11, weight: .bold))
                        Text("Add stream")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .foregroundStyle(trimmedInput.isEmpty ? Color.white.opacity(0.38) : Color.white)
                    .padding(.horizontal, 16)
                    .frame(height: 42)
                    .background {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(trimmedInput.isEmpty ? AnyShapeStyle(Color.white.opacity(0.055)) : AnyShapeStyle(Theme.accentGradient))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(trimmedInput.isEmpty ? Color.white.opacity(0.08) : Color.white.opacity(0.22), lineWidth: 0.75)
                    }
                    .shadow(color: trimmedInput.isEmpty ? .clear : Theme.accentDeep.opacity(0.35), radius: 10, y: 4)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedInput.isEmpty)
                .accessibilityLabel("Add stream")
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    private var launchFooter: some View {
        HStack(spacing: 10) {
            if let message = store.message {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.amber)
                    Text(message)
                        .lineLimit(1)
                        .help(message)
                        .foregroundStyle(.white.opacity(0.92))
                    Button { store.message = nil } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss message")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Theme.amber.opacity(0.12), in: Capsule())
                .overlay(Capsule().stroke(Theme.amber.opacity(0.28), lineWidth: 0.75))
            } else {
                shortcutHint("⌘B", "Live directory")
                Text("·").foregroundStyle(.quaternary)
                Text("Drag any watch or .m3u8 link onto a viewport")
                    .foregroundStyle(.white.opacity(0.45))
            }
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.system(size: 10))
                Text("Direct HLS · Ad & popup free")
            }
            .foregroundStyle(.white.opacity(0.36))
        }
        .font(.system(size: 11.5))
        .padding(.horizontal, 22)
        .frame(height: 38)
    }

    private func shortcutHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10.5, weight: .semibold).monospaced())
                .foregroundStyle(.white.opacity(0.75))
                .padding(.horizontal, 5.5)
                .padding(.vertical, 1.5)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).stroke(Color.white.opacity(0.09), lineWidth: 0.5))
            Text(label)
                .foregroundStyle(.white.opacity(0.48))
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Immersive MPV Floating Chrome

    @ViewBuilder
    private var immersiveChrome: some View {
        if let message = store.message {
            messageBanner(message)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 20)
        }
    }

    private func urlInputField(height: CGFloat) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "link")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(isLocationFocused ? Theme.accent : .white.opacity(0.42))
                .accessibilityHidden(true)

            TextField("Watch page or .m3u8 URL", text: $store.input)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isLocationFocused)
                .onSubmit(submitLocation)
                .accessibilityLabel("Stream URL")

            if !store.input.isEmpty {
                Button { store.input = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear stream URL")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: height)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: height > 38 ? 11 : 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: height > 38 ? 11 : 9, style: .continuous)
                .stroke(Theme.glassBorder(highlighted: isLocationFocused), lineWidth: isLocationFocused ? 1.2 : 0.75)
        }
    }

    // MARK: - Multiview Stage

    private var grid: some View {
        GeometryReader { geometry in
            let shown = visibleSlots
            let columns = store.focusedSlotID == nil ? 2 : 1
            let rows = store.focusedSlotID == nil ? 2 : 1
            let spacing: CGFloat = isImmersive ? 0 : 12
            let totalSpacingX = spacing * CGFloat(max(0, columns - 1))
            let totalSpacingY = spacing * CGFloat(max(0, rows - 1))
            let width = max(0, (geometry.size.width - totalSpacingX) / CGFloat(columns))
            let height = max(0, (geometry.size.height - totalSpacingY) / CGFloat(rows))

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
                        isImmersive: isImmersive,
                        isFocused: isFocused,
                        occupiesTrafficLightCorner: isImmersive && (isFocused || slotIndex == 0),
                        activeCount: activeCount,
                        isWindowHovered: isWindowHovered,
                        isPointerIdle: isPointerIdle,
                        onClose: { store.close(slot) },
                        onFocus: { store.toggleFocus(slot) },
                        onSoloAudio: { store.soloAudio(slot) },
                        onDrop: { store.handleDrop($0, into: slot) },
                        onPaste: { paste(into: slot) },
                        onBrowse: { openBrowser(into: slot) }
                    )
                    .frame(width: width, height: height)
                }
            }
        }
        .padding(.horizontal, isImmersive ? 0 : 20)
        .padding(.top, isImmersive ? 0 : 98)
        .padding(.bottom, isImmersive ? 0 : 38)
    }

    private func messageBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.amber)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)
            Button { store.message = nil } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.65))
                    .frame(width: 22, height: 22)
                    .background(Color.white.opacity(0.08), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss message")
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background {
            Capsule()
                .fill(.ultraThinMaterial)
                .overlay(Capsule().fill(Theme.canvas.opacity(0.82)))
        }
        .overlay(Capsule().stroke(Theme.amber.opacity(0.35), lineWidth: 0.85))
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

    private func submitLocation() {
        store.addFromInput()
    }

    private func openBrowser(into slot: StreamSlot?) {
        browserTarget = BrowserTarget(slot: slot)
    }

    private func destination(for slot: StreamSlot?) -> String {
        guard let slot, let index = store.slots.firstIndex(where: { $0 === slot }) else {
            return "Plays in the next free pane"
        }
        return slot.isEmpty ? "Plays in pane \(index + 1)" : "Replaces pane \(index + 1)"
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
    let isImmersive: Bool
    let isFocused: Bool
    let occupiesTrafficLightCorner: Bool
    let activeCount: Int
    let isWindowHovered: Bool
    let isPointerIdle: Bool
    let onClose: () -> Void
    let onFocus: () -> Void
    let onSoloAudio: () -> Void
    let onDrop: ([NSItemProvider]) -> Bool
    let onPaste: () -> Void
    let onBrowse: () -> Void

    @State private var isDropTargeted = false
    @State private var isHovering = false
    @State private var pulseResolving = false
    @FocusState private var isTileFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var showsControls: Bool {
        !slot.isEmpty && ((isHovering && isWindowHovered && !isPointerIdle) || isTileFocused)
    }

    private var isPlaying: Bool {
        if case .playing = slot.state { return true }
        return false
    }

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
                        Text("Reconnecting…")
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
            .focusable()
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
            .accessibilityLabel(slot.title)
    }

    private var tileControlBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 7) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 6.5, height: 6.5)
                    .shadow(color: statusDotColor.opacity(0.8), radius: 4)
                Text(slot.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .help(slot.title)
                    .shadow(color: .black.opacity(0.75), radius: 3, y: 1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                Capsule()
                    .fill(.ultraThinMaterial)
                    .overlay(Capsule().fill(Color.black.opacity(0.42)))
            }
            .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 0.5))

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                if activeCount > 1 && slot.isMuted {
                    iconButton("headphones", label: "Listen only to \(slot.title)", action: onSoloAudio)
                }
                iconButton(
                    slot.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    label: slot.isMuted ? "Unmute \(slot.title)" : "Mute \(slot.title)",
                    tint: slot.isMuted ? Theme.amber : .white
                ) {
                    slot.isMuted.toggle()
                }
                iconButton(
                    "list.bullet.rectangle",
                    label: "Browse replacement for \(slot.title)",
                    action: onBrowse
                )
                iconButton(
                    isFocused ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                    label: isFocused ? "Show all four panes" : "Expand \(slot.title)",
                    action: onFocus
                )
                iconButton("xmark", label: "Close \(slot.title)", action: onClose)
            }
        }
        .padding(.leading, occupiesTrafficLightCorner ? ChromeVisibility.trafficLightExclusionWidth : 12)
        .padding(.trailing, 12)
        .padding(.top, 7)
        .padding(.bottom, 10)
        .foregroundStyle(.white)
        .background(alignment: .top) {
            LinearGradient(
                colors: [Color.black.opacity(0.82), Color.black.opacity(0.36), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 76)
            .allowsHitTesting(false)
        }
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
            PlayerView(player: slot.player)
        case .failed(let message):
            failedContent(message)
        }
    }

    private var idleContent: some View {
        ZStack {
            if !isImmersive {
                RadialGradient(
                    colors: [
                        Theme.accent.opacity(isHovering ? 0.08 : 0.03),
                        Color.clear
                    ],
                    center: .topLeading,
                    startRadius: 8,
                    endRadius: 280
                )
            } else {
                Color(red: 0.016, green: 0.020, blue: 0.030)
            }

            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(isHovering ? 0.08 : 0.045))
                        .frame(width: 46, height: 46)
                        .overlay(
                            Circle()
                                .stroke(isHovering ? Theme.accent.opacity(0.45) : Color.white.opacity(0.09), lineWidth: 0.75)
                        )
                    Image(systemName: "play.tv")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(isHovering ? Theme.accent : .white.opacity(0.65))
                }
                .accessibilityHidden(true)

                VStack(spacing: 4) {
                    Text("Drop a stream link")
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                    Text("Watch page or direct HLS playlist")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.45))
                }

                HStack(spacing: 8) {
                    tilePillButton("Browse games", icon: "dot.radiowaves.left.and.right", prominent: true, action: onBrowse)
                    tilePillButton("Paste from clipboard", icon: "doc.on.clipboard", prominent: false, action: onPaste)
                }
                .padding(.top, 2)
            }
            .padding(16)
            .opacity(isImmersive && (!(isHovering && !isPointerIdle) && !isTileFocused && !isDropTargeted) ? 0.24 : 1.0)
        }
        .overlay(alignment: .topLeading) {
            if !isImmersive {
                HStack(spacing: 6) {
                    Text(String(format: "0%d", slotIndex + 1))
                        .font(.system(size: 10.5, weight: .bold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.42))
                    Text(slotIndex == 0 ? "PRIMARY AUDIO" : "AUTO-MUTED")
                        .font(.system(size: 9.5, weight: .semibold))
                        .tracking(0.5)
                        .foregroundStyle(slotIndex == 0 ? Theme.accent.opacity(0.75) : .white.opacity(0.26))
                }
                .padding(.horizontal, 14)
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
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.accent.opacity(0.9))
                Text("Checking the available sources")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.white.opacity(0.45))
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
        .background(Theme.canvas)
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
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.58))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            HStack(spacing: 8) {
                tilePillButton("Try again", icon: "arrow.clockwise", prominent: true, action: slot.retry)
                tilePillButton("Browse games", icon: "list.bullet.rectangle", prominent: false, action: onBrowse)
                tilePillButton("Use another link", icon: "xmark", prominent: false, action: onClose)
            }
            .padding(.top, 2)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
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
            .frame(height: 29)
            .background {
                Capsule()
                    .fill(prominent ? Theme.accent.opacity(0.13) : Color.white.opacity(0.06))
            }
            .overlay {
                Capsule()
                    .stroke(prominent ? Theme.accent.opacity(0.34) : Color.white.opacity(0.10), lineWidth: 0.75)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func iconButton(
        _ systemName: String,
        label: String,
        tint: Color = .white,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .overlay(Circle().fill(Color.black.opacity(0.45)))
                }
                .overlay(Circle().stroke(Color.white.opacity(0.14), lineWidth: 0.5))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
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
