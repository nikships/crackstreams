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
    @State private var isLocationVisible = false
    @FocusState private var isLocationFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let accent = Color(red: 0.30, green: 0.72, blue: 0.96)

    var body: some View {
        ZStack(alignment: .top) {
            grid

            if !isImmersive {
                VStack(spacing: 0) {
                    header
                    Spacer()
                    footer
                }
            } else {
                Color.clear
                    .frame(height: 10)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering { showLocation() }
                    }
                    .accessibilityHidden(true)

                if isLocationVisible {
                    header
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.12)))
                        .padding(12)
                        .shadow(color: .black.opacity(0.35), radius: 18, y: 8)
                        .onHover { hovering in
                            if !hovering && !isLocationFocused { hideLocation() }
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                if let message = store.message {
                    messageBanner(message)
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, 18)
                }
            }
        }
        .frame(minWidth: 800, minHeight: 540)
        .background(Color(red: 0.025, green: 0.032, blue: 0.045))
        .onDrop(of: [.url, .text], isTargeted: nil) { store.handleDrop($0) }
        .onReceive(NotificationCenter.default.publisher(for: .showStreamLocation)) { _ in showLocation() }
        .onReceive(NotificationCenter.default.publisher(for: .showStreamBrowser)) { _ in openBrowser(into: nil) }
        .sheet(item: $browserTarget) { target in
            BrowserView(browser: browser,
                        destination: destination(for: target.slot),
                        playingURLs: Set(store.slots.compactMap(\.sourceURL))) { event in
                store.add(event.url, title: event.title, into: target.slot) ? nil : (store.message ?? "This stream could not be added.")
            }
        }
        .background {
            Button("") { isLocationVisible ? hideLocation() : showLocation() }
                .keyboardShortcut("l", modifiers: .command)
                .hidden()
            Button("") { hideLocation() }
                .keyboardShortcut(.escape, modifiers: [])
                .hidden()
        }
        .animation(reduceMotion ? .none : .easeOut(duration: 0.2), value: isLocationVisible)
        .animation(reduceMotion ? .none : .easeOut(duration: 0.2), value: isImmersive)
    }

    private var isImmersive: Bool { store.slots.contains { !$0.isEmpty } }

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "rectangle.stack.fill")
                    .font(.title3)
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)
                Text("Crackstreams")
                    .font(.headline.weight(.semibold))
                Text("\(activeCount) / 4")
                    .font(.caption.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.white.opacity(0.07), in: Capsule())
                    .accessibilityLabel("\(activeCount) of 4 panes occupied")
                Spacer()
                if isImmersive {
                    Text("Esc to hide")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(action: hideLocation) {
                        Image(systemName: "xmark")
                            .frame(width: 24, height: 24)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Hide stream URL bar")
                } else {
                    Text("Four games. One window.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "link")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    TextField("Watch page or .m3u8 URL", text: $store.input)
                        .textFieldStyle(.plain)
                        .focused($isLocationFocused)
                        .accessibilityLabel("Stream URL")
                    if !store.input.isEmpty {
                        Button { store.input = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear stream URL")
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(isLocationFocused ? accent.opacity(0.75) : Color.white.opacity(0.09), lineWidth: 1)
                }

                Button { openBrowser(into: nil) } label: {
                    Label("Browse", systemImage: "list.bullet.rectangle")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help("Browse games on \(browser.home.host ?? "the stream site") (⌘B)")

                Button(action: submitLocation) {
                    Label("Add stream", systemImage: "plus")
                        .frame(width: 112)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(store.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
    }

    private var grid: some View {
        GeometryReader { geometry in
            let shown = visibleSlots
            let columns = store.focusedSlotID == nil ? 2 : 1
            let rows = store.focusedSlotID == nil ? 2 : 1
            let width = geometry.size.width / CGFloat(columns)
            let height = geometry.size.height / CGFloat(rows)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: columns),
                spacing: 0
            ) {
                ForEach(shown) { slot in
                    StreamTile(
                        slot: slot,
                        isFocused: store.focusedSlotID == slot.id,
                        onClose: { store.close(slot) },
                        onFocus: { store.toggleFocus(slot) },
                        onDrop: { store.handleDrop($0, into: slot) },
                        onPaste: { paste(into: slot) },
                        onBrowse: { openBrowser(into: slot) }
                    )
                    .frame(width: width, height: height)
                }
            }
        }
        .padding(.top, isImmersive ? 0 : 101)
        .padding(.bottom, isImmersive ? 0 : 34)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let message = store.message {
                Image(systemName: "exclamationmark.circle.fill")
                Text(message).lineLimit(1).help(message)
            } else {
                Image(systemName: "command")
                Text("⌘L for URL bar")
                    .accessibilityLabel("Command L for URL bar")
                Text("•")
                Text("⌘B to browse games")
                    .accessibilityLabel("Command B to browse games")
                Text("•")
                Text("Drop a link on any pane")
            }
            Spacer()
            Text("Native playback • no browser popups")
                .foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(store.message == nil ? Color.secondary : Color.orange)
        .padding(.horizontal, 16)
        .frame(height: 34)
        .background(Color(red: 0.025, green: 0.032, blue: 0.045))
    }

    private func messageBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
            Text(message).lineLimit(2)
            Button { store.message = nil } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss message")
        }
        .font(.callout)
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 24)
        .accessibilityLabel(message)
        .transition(.opacity)
    }

    private var activeCount: Int { store.slots.count { !$0.isEmpty } }

    private var visibleSlots: [StreamSlot] {
        if let id = store.focusedSlotID, let slot = store.slots.first(where: { $0.id == id }) {
            return [slot]
        }
        return store.slots
    }

    private func showLocation() {
        isLocationVisible = true
        DispatchQueue.main.async { isLocationFocused = true }
    }

    private func hideLocation() {
        isLocationFocused = false
        isLocationVisible = false
    }

    private func submitLocation() {
        if store.addFromInput() && isImmersive { hideLocation() }
    }

    private func openBrowser(into slot: StreamSlot?) {
        if isImmersive { hideLocation() }
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

private struct StreamTile: View {
    @ObservedObject var slot: StreamSlot
    let isFocused: Bool
    let onClose: () -> Void
    let onFocus: () -> Void
    let onDrop: ([NSItemProvider]) -> Bool
    let onPaste: () -> Void
    let onBrowse: () -> Void

    @State private var isDropTargeted = false
    @State private var isHovering = false
    @FocusState private var isTileFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .overlay(alignment: .top) {
                if (isHovering || isTileFocused) && !slot.isEmpty {
                    HStack(spacing: 8) {
                        Text(slot.title)
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .help(slot.title)
                        Spacer()
                        iconButton(slot.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                   label: slot.isMuted ? "Unmute \(slot.title)" : "Mute \(slot.title)") {
                            slot.isMuted.toggle()
                        }
                        .foregroundStyle(slot.isMuted ? Color.orange : Color.white)
                        iconButton(isFocused ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                   label: isFocused ? "Show all four panes" : "Expand \(slot.title)", action: onFocus)
                        iconButton("xmark", label: "Close \(slot.title)", action: onClose)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .foregroundStyle(.white)
                    .background {
                        LinearGradient(colors: [Color.black.opacity(0.88), Color.black.opacity(0)],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(height: 82)
                            .padding(.bottom, -36)
                            .allowsHitTesting(false)
                    }
                    .transition(.opacity)
                }
            }
            .overlay {
                if slot.isBuffering, case .playing = slot.state {
                    Label("Reconnecting…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.65), in: Capsule())
                        .foregroundStyle(.white)
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if isDropTargeted {
                    ZStack {
                        Color.accentColor.opacity(0.16)
                        Label("Drop to play", systemImage: "arrow.down.circle.fill")
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                    .allowsHitTesting(false)
                }
            }
            .onDrop(of: [.url, .text], isTargeted: $isDropTargeted, perform: onDrop)
            .background(HoverSensor(isHovering: $isHovering, reduceMotion: reduceMotion))
            .focusable()
            .focused($isTileFocused)
            .focusEffectDisabled()
            .accessibilityElement(children: .contain)
            .accessibilityLabel(slot.title)
    }

    @ViewBuilder
    private var content: some View {
        switch slot.state {
        case .idle:
            VStack(spacing: 12) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Drop a stream link")
                    .font(.headline)
                Text("Watch page or direct HLS playlist")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("Browse games", action: onBrowse)
                        .buttonStyle(.bordered)
                    Button("Paste from clipboard", action: onPaste)
                        .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white.opacity(0.018))
        case .resolving:
            VStack(spacing: 14) {
                ProgressView().controlSize(.regular)
                Text("Finding the live feed…")
                    .font(.headline)
                Text("Checking the available sources")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .combine)
        case .playing:
            PlayerView(player: slot.player)
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 28))
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("Couldn’t play this stream")
                    .font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                HStack {
                    Button("Try again", action: slot.retry).buttonStyle(.borderedProminent)
                    Button("Use another link", action: onClose).buttonStyle(.bordered)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityElement(children: .contain)
        }
    }

    private func iconButton(_ systemName: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 32, height: 32)
                .background(Color.black.opacity(0.45), in: Circle())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct HoverSensor: NSViewRepresentable {
    @Binding var isHovering: Bool
    let reduceMotion: Bool

    func makeNSView(context: Context) -> NSView {
        let view = HoverTrackingView()
        view.onHoverChange = { hovering in
            DispatchQueue.main.async {
                withAnimation(reduceMotion ? .none : .easeOut(duration: 0.15)) { isHovering = hovering }
            }
        }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

private final class HoverTrackingView: NSView {
    var onHoverChange: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChange?(false) }
}
