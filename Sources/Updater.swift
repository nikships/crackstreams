import Combine
import Sparkle
import SwiftUI

/// Owns Sparkle's standard updater. Debug builds never start it, so a development build is
/// not offered the published release as an update.
@MainActor
final class AppUpdater: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    private let controller: SPUStandardUpdaterController

    init() {
        #if DEBUG
        let startsUpdater = false
        #else
        let startsUpdater = true
        #endif
        controller = SPUStandardUpdaterController(startingUpdater: startsUpdater,
                                                  updaterDelegate: nil,
                                                  userDriverDelegate: nil)
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)
    }

    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }
}

struct CheckForUpdatesButton: View {
    @ObservedObject var updater: AppUpdater

    var body: some View {
        Button("Check for Updates…", action: updater.checkForUpdates)
            .disabled(!updater.canCheckForUpdates)
    }
}
