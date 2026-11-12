import AVFoundation
import Combine
import Foundation
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class StreamSlot: ObservableObject, Identifiable {
    enum State: Equatable {
        case idle
        case resolving
        case playing
        case failed(String)
    }

    let id = UUID()
    @Published private(set) var state: State = .idle
    @Published private(set) var title = "Empty slot"
    @Published private(set) var sourceURL: URL?
    @Published private(set) var player: AVPlayer?
    @Published private(set) var isBuffering = false
    @Published var isMuted: Bool {
        didSet { player?.isMuted = isMuted }
    }

    private var loadTask: Task<Void, Never>?
    private var generation = UUID()
    private var preferredTitle: String?
    private var statusObservation: NSKeyValueObservation?
    private var timeControlObservation: NSKeyValueObservation?
    private var notificationObservers: [NSObjectProtocol] = []

    init(isMuted: Bool = false) {
        self.isMuted = isMuted
    }

    var isEmpty: Bool { state == .idle }

    func load(_ url: URL, title preferredTitle: String? = nil) {
        loadTask?.cancel()
        stopPlayer()
        generation = UUID()
        let generation = self.generation
        sourceURL = url
        self.preferredTitle = preferredTitle
        title = preferredTitle ?? Resolver.prettyTitle(from: url)
        state = .resolving

        loadTask = Task { [weak self] in
            do {
                let resolved = try await Resolver.resolve(url)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard let self, self.generation == generation else { return }
                    let item = AVPlayerItem(url: HLSProxy.shared.localURL(
                        for: resolved.playlist,
                        referer: resolved.referer
                    ))
                    let player = AVPlayer(playerItem: item)
                    player.isMuted = self.isMuted
                    player.automaticallyWaitsToMinimizeStalling = true
                    self.player = player
                    self.title = self.preferredTitle ?? resolved.title
                    self.isBuffering = true
                    self.state = .playing
                    self.observe(item: item, player: player, generation: generation)
                    player.play()
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    guard let self, self.generation == generation else { return }
                    self.fail(with: error.localizedDescription)
                }
            }
        }
    }

    func retry() {
        guard let sourceURL else { return }
        load(sourceURL, title: preferredTitle)
    }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
        generation = UUID()
        stopPlayer()
        state = .idle
        title = "Empty slot"
        sourceURL = nil
        preferredTitle = nil
    }

    private func observe(item: AVPlayerItem, player: AVPlayer, generation: UUID) {
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                switch item.status {
                case .readyToPlay:
                    self.isBuffering = player.timeControlStatus != .playing
                case .failed:
                    self.fail(with: item.error?.localizedDescription ?? "The live feed could not be opened.")
                default:
                    break
                }
            }
        }
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.isBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
            }
        }

        let center = NotificationCenter.default
        let failed = center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError
                self.fail(with: error?.localizedDescription ?? "Playback was interrupted.")
            }
        }
        let stalled = center.addObserver(forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.isBuffering = true
            }
        }
        let ended = center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.fail(with: "This live stream ended.")
            }
        }
        notificationObservers = [failed, stalled, ended]
    }

    private func fail(with message: String) {
        stopPlayer()
        state = .failed(message)
    }

    private func stopPlayer() {
        statusObservation?.invalidate()
        timeControlObservation?.invalidate()
        statusObservation = nil
        timeControlObservation = nil
        notificationObservers.forEach(NotificationCenter.default.removeObserver)
        notificationObservers.removeAll()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        isBuffering = false
    }
}

@MainActor
final class StreamStore: ObservableObject {
    static let maximumStreams = 4

    @Published var slots: [StreamSlot]
    @Published var input = ""
    @Published var message: String?
    @Published var focusedSlotID: UUID?

    init() {
        slots = (0..<Self.maximumStreams).map { StreamSlot(isMuted: $0 > 0) }
    }

    @discardableResult
    func addFromInput() -> Bool {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        guard let url = Self.validURL(text) else {
            message = "Enter a valid http:// or https:// stream URL."
            return false
        }
        guard add(url) else { return false }
        input = ""
        return true
    }

    @discardableResult
    func add(_ url: URL, title: String? = nil, into target: StreamSlot? = nil) -> Bool {
        guard Self.validURL(url.absoluteString) != nil else {
            message = "Only http:// and https:// stream URLs are supported."
            return false
        }
        message = nil
        if let target {
            if target.isEmpty { target.isMuted = slots.contains { !$0.isEmpty && $0 !== target } }
            target.load(url, title: title)
            return true
        }
        guard let empty = slots.first(where: { $0.isEmpty }) else {
            message = "All four panes are in use. Close one or drop the link onto a pane to replace it."
            return false
        }
        empty.isMuted = slots.contains { !$0.isEmpty }
        empty.load(url, title: title)
        return true
    }

    func close(_ slot: StreamSlot) {
        slot.stop()
        if focusedSlotID == slot.id { focusedSlotID = nil }
    }

    func stopAll() {
        slots.forEach { $0.stop() }
        focusedSlotID = nil
    }

    func toggleFocus(_ slot: StreamSlot) {
        focusedSlotID = focusedSlotID == slot.id ? nil : slot.id
    }

    func handleDrop(_ providers: [NSItemProvider], into target: StreamSlot? = nil) -> Bool {
        guard let provider = providers.first else { return false }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            _ = provider.loadObject(ofClass: URL.self) { [weak self] url, _ in
                guard let url else { return }
                Task { @MainActor in self?.add(url, into: target) }
            }
            return true
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
            _ = provider.loadObject(ofClass: String.self) { [weak self] text, _ in
                guard let text else { return }
                Task { @MainActor in
                    guard let self, let url = Self.validURL(text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                        self?.message = "The dropped text is not a valid stream URL."
                        return
                    }
                    self.add(url, into: target)
                }
            }
            return true
        }
        return false
    }

    nonisolated static func validURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}
