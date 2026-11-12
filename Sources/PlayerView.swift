import AppKit
import AVKit
import SwiftUI

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer?

    func makeNSView(context: Context) -> AVPlayerView {
        let view = DraggablePlayerView()
        view.controlsStyle = .floating
        view.showsFullScreenToggleButton = true
        view.showsSharingServiceButton = false
        view.showsTimecodes = false
        view.allowsVideoFrameAnalysis = false
        view.videoGravity = .resizeAspect
        view.allowsPictureInPicturePlayback = true
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

final class DraggablePlayerView: AVPlayerView {
    override var mouseDownCanMoveWindow: Bool { true }
}
