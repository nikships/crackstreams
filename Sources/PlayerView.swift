import AppKit
import AVKit
import SwiftUI

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer?
    var onDoubleClick: () -> Void = {}

    func makeNSView(context: Context) -> DraggablePlayerView {
        let view = DraggablePlayerView()
        // Pane chrome in ContentView owns every control, so AVKit's own bar never competes with it.
        view.controlsStyle = .none
        view.showsFullScreenToggleButton = false
        view.showsSharingServiceButton = false
        view.showsTimecodes = false
        view.allowsVideoFrameAnalysis = false
        view.videoGravity = .resizeAspect
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ view: DraggablePlayerView, context: Context) {
        if view.player !== player { view.player = player }
        view.onDoubleClick = onDoubleClick
    }
}

final class DraggablePlayerView: AVPlayerView {
    /// Invoked by the window's event monitor, which sees clicks before AVKit's internal subviews do.
    var onDoubleClick: (() -> Void)?

    override var mouseDownCanMoveWindow: Bool { true }
}
