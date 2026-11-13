import AppKit
import SwiftUI

enum Theme {
    static let canvas = Color(red: 0.024, green: 0.030, blue: 0.046)
    static let elevated = Color(red: 0.055, green: 0.070, blue: 0.102)
    static let cardFill = Color(red: 0.045, green: 0.058, blue: 0.086)
    static let accent = Color(red: 0.26, green: 0.73, blue: 0.99)
    static let accentDeep = Color(red: 0.14, green: 0.50, blue: 0.92)
    static let live = Color(red: 1.00, green: 0.25, blue: 0.34)
    static let amber = Color(red: 1.00, green: 0.69, blue: 0.16)
    static let emerald = Color(red: 0.20, green: 0.84, blue: 0.58)

    static let accentGradient = LinearGradient(
        colors: [accent, accentDeep],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static func glassBorder(highlighted: Bool = false) -> LinearGradient {
        if highlighted {
            return LinearGradient(
                colors: [accent.opacity(0.85), accentDeep.opacity(0.45)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        return LinearGradient(
            colors: [Color.white.opacity(0.16), Color.white.opacity(0.05)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

/// Pure rules for MPV-style window chrome visibility.
enum ChromeVisibility {
    static let idleHideInterval: TimeInterval = 2.4
    /// Keeps the pointer awake near the traffic lights. Nothing else reveals from the top edge,
    /// so pane controls in the top row stay reachable.
    static let topComfortZoneHeight: CGFloat = 40
    static let trafficLightExclusionWidth: CGFloat = 86

    static func showsTrafficLights(
        isFullScreen: Bool,
        isWindowHovered: Bool,
        isImmersive: Bool,
        isPointerIdle: Bool
    ) -> Bool {
        if isFullScreen { return true }
        guard isWindowHovered else { return false }
        if isImmersive && isPointerIdle { return false }
        return true
    }

    static func canAutoHidePointer(
        isPlayingAny: Bool,
        isLocationVisible: Bool,
        isSheetPresented: Bool,
        isNearTopZone: Bool,
        isPointerOverChrome: Bool = false
    ) -> Bool {
        isPlayingAny && !isLocationVisible && !isSheetPresented && !isNearTopZone && !isPointerOverChrome
    }

    /// A pane is "full screen" only when it is the focused pane of a full-screen window.
    static func isPaneFullScreen(isFocused: Bool, isWindowFullScreen: Bool) -> Bool {
        isFocused && isWindowFullScreen
    }

    /// Leaves full screen on collapse only when the app entered it for a pane.
    static func shouldExitFullScreenOnCollapse(enteredForPane: Bool, isWindowFullScreen: Bool) -> Bool {
        enteredForPane && isWindowFullScreen
    }
}

/// Custom multiview emblem echoing the app icon's 2x2 glowing quad geometry.
struct BrandQuadMark: View {
    var size: CGFloat = 18

    var body: some View {
        let cell = (size - 3) / 2
        let radius = max(2, cell * 0.26)
        VStack(spacing: 3) {
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.accentGradient)
                    .frame(width: cell, height: cell)
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.white.opacity(0.24))
                    .frame(width: cell, height: cell)
            }
            HStack(spacing: 3) {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.white.opacity(0.24))
                    .frame(width: cell, height: cell)
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Theme.accentGradient)
                    .frame(width: cell, height: cell)
            }
        }
        .shadow(color: Theme.accent.opacity(0.35), radius: 6, y: 1)
        .accessibilityHidden(true)
    }
}

/// Configures the hosting NSWindow as a borderless MPV-style floating surface with
/// hover-activated traffic lights, zero system gray bar, and background window dragging.
struct WindowChromeConfigurator: NSViewRepresentable {
    @Binding var isWindowHovered: Bool
    @Binding var isNearTopZone: Bool
    @Binding var isPointerIdle: Bool
    let isImmersive: Bool
    let isPlayingAny: Bool
    let isLocationVisible: Bool
    let isSheetPresented: Bool
    let isPointerOverChrome: Bool
    let reduceMotion: Bool

    func makeNSView(context: Context) -> WindowChromeTrackingView {
        let view = WindowChromeTrackingView()
        view.coordinator = context.coordinator
        context.coordinator.trackingView = view
        return view
    }

    func updateNSView(_ view: WindowChromeTrackingView, context: Context) {
        context.coordinator.update(from: self, window: view.window)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: WindowChromeConfigurator
        weak var trackingView: WindowChromeTrackingView?
        private weak var observedWindow: NSWindow?
        private var windowObservers: [NSObjectProtocol] = []
        private var eventMonitor: Any?
        private var hoverPollTimer: Timer?
        private var idleWorkItem: DispatchWorkItem?
        private var lastScreenMouseLocation: NSPoint?
        private var videoDragStartPoint: NSPoint?
        private var videoDragDownEvent: NSEvent?
        private var isFullScreen = false
        private var lastTrafficLightsVisible: Bool?
        private var animationGeneration: UInt64 = 0

        init(parent: WindowChromeConfigurator) {
            self.parent = parent
            super.init()
        }

        deinit {
            idleWorkItem?.cancel()
            hoverPollTimer?.invalidate()
            if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
            windowObservers.forEach(NotificationCenter.default.removeObserver)
        }

        func attach(to window: NSWindow?) {
            guard let window else { return }
            if observedWindow !== window {
                teardownWindowObservers()
                observedWindow = window
                configureWindowAppearance(window)
                installWindowObservers(for: window)
                installEventMonitor()
            }
            refreshPointerState(in: window, triggeredByMotion: false)
        }

        private func canAutoHide(isNearTopZone: Bool? = nil) -> Bool {
            ChromeVisibility.canAutoHidePointer(
                isPlayingAny: parent.isPlayingAny,
                isLocationVisible: parent.isLocationVisible,
                isSheetPresented: parent.isSheetPresented,
                isNearTopZone: isNearTopZone ?? parent.isNearTopZone,
                isPointerOverChrome: parent.isPointerOverChrome
            )
        }

        func update(from newParent: WindowChromeConfigurator, window: NSWindow?) {
            let wasCanIdle = canAutoHide()
            parent = newParent
            guard let window else { return }

            if observedWindow !== window {
                attach(to: window)
                return
            }

            configureWindowAppearance(window)
            let nowCanIdle = canAutoHide()
            if !nowCanIdle {
                cancelIdleTimer()
                if parent.isPointerIdle { parent.isPointerIdle = false }
            } else if !wasCanIdle && parent.isWindowHovered && !parent.isPointerIdle {
                scheduleIdleTimer()
            }
            applyTrafficLightsVisibility(in: window, animated: !parent.reduceMotion)
        }

        private func configureWindowAppearance(_ window: NSWindow) {
            if window.titleVisibility != .hidden { window.titleVisibility = .hidden }
            if !window.titlebarAppearsTransparent { window.titlebarAppearsTransparent = true }
            if window.titlebarSeparatorStyle != .none { window.titlebarSeparatorStyle = .none }
            if !window.styleMask.contains(.fullSizeContentView) {
                window.styleMask.insert(.fullSizeContentView)
            }
            if !window.isMovableByWindowBackground { window.isMovableByWindowBackground = true }
            let targetColor = NSColor(red: 0.024, green: 0.030, blue: 0.046, alpha: 1.0)
            if window.backgroundColor != targetColor { window.backgroundColor = targetColor }
            isFullScreen = window.styleMask.contains(.fullScreen)
        }

        private func installWindowObservers(for window: NSWindow) {
            let center = NotificationCenter.default
            let names: [Notification.Name] = [
                NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification,
                NSWindow.didResizeNotification,
                NSWindow.didMoveNotification,
                NSWindow.willEnterFullScreenNotification,
                NSWindow.didEnterFullScreenNotification,
                NSWindow.didExitFullScreenNotification
            ]
            for name in names {
                let token = center.addObserver(forName: name, object: window, queue: .main) { [weak self, weak window] note in
                    MainActor.assumeIsolated {
                        guard let self, let window else { return }
                        if note.name == NSWindow.willEnterFullScreenNotification || note.name == NSWindow.didEnterFullScreenNotification {
                            self.isFullScreen = true
                        } else {
                            self.isFullScreen = window.styleMask.contains(.fullScreen)
                        }
                        self.configureWindowAppearance(window)
                        self.lastTrafficLightsVisible = nil
                        self.refreshPointerState(in: window, triggeredByMotion: false)
                    }
                }
                windowObservers.append(token)
            }

            for appName in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
                let token = center.addObserver(forName: appName, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let window = self.observedWindow else { return }
                        self.lastTrafficLightsVisible = nil
                        self.refreshPointerState(in: window, triggeredByMotion: false)
                    }
                }
                windowObservers.append(token)
            }
        }

        private func installEventMonitor() {
            guard eventMonitor == nil else { return }
            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [
                    .mouseMoved,
                    .leftMouseDown,
                    .leftMouseDragged,
                    .leftMouseUp,
                    .rightMouseDragged,
                    .mouseEntered,
                    .mouseExited
                ]
            ) { [weak self] event in
                var shouldConsume = false
                MainActor.assumeIsolated {
                    guard let self, let window = self.observedWindow else { return }
                    self.refreshPointerState(in: window, triggeredByMotion: true)
                    if event.window === window {
                        switch event.type {
                        case .leftMouseDown:
                            let hit = window.contentView?.hitTest(event.locationInWindow)
                            if event.clickCount == 2, let player = Self.videoSurface(hit), let onDoubleClick = player.onDoubleClick {
                                self.videoDragStartPoint = nil
                                self.videoDragDownEvent = nil
                                onDoubleClick()
                                shouldConsume = true
                            } else if Self.videoSurface(hit) != nil {
                                self.videoDragStartPoint = event.locationInWindow
                                self.videoDragDownEvent = event
                            } else {
                                self.videoDragStartPoint = nil
                                self.videoDragDownEvent = nil
                            }
                        case .leftMouseDragged:
                            if let start = self.videoDragStartPoint {
                                let delta = hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y)
                                if delta > 3 {
                                    let seed = self.videoDragDownEvent ?? event
                                    self.videoDragStartPoint = nil
                                    self.videoDragDownEvent = nil
                                    window.performDrag(with: seed)
                                    shouldConsume = true
                                }
                            }
                        case .leftMouseUp:
                            self.videoDragStartPoint = nil
                            self.videoDragDownEvent = nil
                        default:
                            break
                        }
                    }
                }
                return shouldConsume ? nil : event
            }
        }

        /// Returns the player under a click when the click lands on video rather than a control.
        private static func videoSurface(_ hitView: NSView?) -> DraggablePlayerView? {
            var current = hitView
            while let view = current {
                if view is NSControl { return nil }
                let typeName = String(describing: type(of: view))
                if typeName.contains("Button")
                    || typeName.contains("Slider")
                    || typeName.contains("Scrubber")
                    || typeName.contains("TextField") {
                    return nil
                }
                if let player = view as? DraggablePlayerView { return player }
                current = view.superview
            }
            return nil
        }

        func refreshPointerState(in window: NSWindow, triggeredByMotion: Bool) {
            let screenMouse = NSEvent.mouseLocation
            let windowRect = NSRect(origin: .zero, size: window.frame.size)
            // mouseLocationOutsideOfEventStream is always in unflipped window coordinates
            // where y = 0 is the bottom edge and y = windowRect.height is the top edge.
            let point = window.mouseLocationOutsideOfEventStream
            let topWindowNumber = NSWindow.windowNumber(at: screenMouse, belowWindowWithWindowNumber: 0)
            let belongsToWindow = topWindowNumber == 0
                || topWindowNumber == window.windowNumber
                || window.sheets.contains(where: { $0.windowNumber == topWindowNumber })
                || (window.childWindows?.contains(where: { $0.windowNumber == topWindowNumber }) ?? false)

            let inside = !window.isMiniaturized
                && window.isVisible
                && windowRect.width > 0
                && windowRect.height > 0
                && windowRect.contains(point)
                && belongsToWindow

            let pointerMoved: Bool
            if let last = lastScreenMouseLocation {
                pointerMoved = hypot(screenMouse.x - last.x, screenMouse.y - last.y) > 0.5
            } else {
                pointerMoved = triggeredByMotion
            }
            lastScreenMouseLocation = screenMouse

            let topDistance = windowRect.height - point.y
            let nearTop = inside
                && topDistance >= 0
                && topDistance <= ChromeVisibility.topComfortZoneHeight
                && point.x <= ChromeVisibility.trafficLightExclusionWidth

            if parent.isWindowHovered != inside {
                parent.isWindowHovered = inside
            }
            if parent.isNearTopZone != nearTop {
                parent.isNearTopZone = nearTop
            }

            updateHoverPollTimer(active: inside)

            if !inside {
                cancelIdleTimer()
                if parent.isPointerIdle { parent.isPointerIdle = false }
            } else if pointerMoved {
                if parent.isPointerIdle { parent.isPointerIdle = false }
                scheduleIdleTimer()
            } else if idleWorkItem == nil && !parent.isPointerIdle && canAutoHide(isNearTopZone: nearTop) {
                scheduleIdleTimer()
            }

            applyTrafficLightsVisibility(in: window, animated: (triggeredByMotion || pointerMoved) && !parent.reduceMotion)
        }

        private func updateHoverPollTimer(active: Bool) {
            if active {
                guard hoverPollTimer == nil else { return }
                hoverPollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let window = self.observedWindow else {
                            self?.hoverPollTimer?.invalidate()
                            self?.hoverPollTimer = nil
                            return
                        }
                        self.refreshPointerState(in: window, triggeredByMotion: false)
                    }
                }
            } else {
                hoverPollTimer?.invalidate()
                hoverPollTimer = nil
            }
        }

        private func cancelIdleTimer() {
            idleWorkItem?.cancel()
            idleWorkItem = nil
        }

        private func scheduleIdleTimer() {
            cancelIdleTimer()
            guard canAutoHide() else { return }

            let item = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let window = self.observedWindow else { return }
                    self.idleWorkItem = nil
                    guard self.canAutoHide() else { return }
                    self.parent.isPointerIdle = true
                    self.applyTrafficLightsVisibility(in: window, animated: !self.parent.reduceMotion)
                }
            }
            idleWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + ChromeVisibility.idleHideInterval, execute: item)
        }

        private func applyTrafficLightsVisibility(in window: NSWindow, animated: Bool) {
            let visible = ChromeVisibility.showsTrafficLights(
                isFullScreen: isFullScreen || window.styleMask.contains(.fullScreen),
                isWindowHovered: parent.isWindowHovered,
                isImmersive: parent.isImmersive,
                isPointerIdle: parent.isPointerIdle
            )
            let buttons: [NSButton] = [
                .closeButton,
                .miniaturizeButton,
                .zoomButton
            ].compactMap { window.standardWindowButton($0) }
            guard !buttons.isEmpty else { return }

            let targetAlpha: CGFloat = visible ? 1.0 : 0.0
            let needsForceSync = buttons.contains {
                $0.isHidden != !visible && (visible || $0.alphaValue > 0.01) || (visible && abs($0.alphaValue - 1.0) > 0.01)
            }
            guard lastTrafficLightsVisible != visible || needsForceSync else { return }
            lastTrafficLightsVisible = visible
            animationGeneration &+= 1
            let generation = animationGeneration

            if visible {
                for button in buttons where button.isHidden {
                    button.alphaValue = 0
                    button.isHidden = false
                }
            }

            if animated {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    for button in buttons {
                        button.animator().alphaValue = targetAlpha
                    }
                } completionHandler: { [weak self] in
                    Task { @MainActor in
                        guard let self, self.animationGeneration == generation, !visible else { return }
                        for button in buttons {
                            button.alphaValue = 0
                            button.isHidden = true
                        }
                    }
                }
            } else {
                for button in buttons {
                    button.alphaValue = targetAlpha
                    button.isHidden = !visible
                }
            }
        }

        private func teardownWindowObservers() {
            windowObservers.forEach(NotificationCenter.default.removeObserver)
            windowObservers.removeAll()
        }
    }
}

final class WindowChromeTrackingView: NSView {
    weak var coordinator: WindowChromeConfigurator.Coordinator?
    private var trackingArea: NSTrackingArea?

    override var mouseDownCanMoveWindow: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.coordinator?.attach(to: self.window)
        }
    }

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

    override func mouseEntered(with event: NSEvent) {
        if let window { coordinator?.refreshPointerState(in: window, triggeredByMotion: true) }
    }

    override func mouseExited(with event: NSEvent) {
        if let window { coordinator?.refreshPointerState(in: window, triggeredByMotion: true) }
    }

    override func mouseMoved(with event: NSEvent) {
        if let window { coordinator?.refreshPointerState(in: window, triggeredByMotion: true) }
    }
}
