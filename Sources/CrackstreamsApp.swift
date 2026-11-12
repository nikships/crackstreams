import AppKit
import SwiftUI

@main
struct CrackstreamsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = StreamStore()
    @StateObject private var updater = AppUpdater()

    var body: some Scene {
        WindowGroup("Crackstreams") {
            ContentView(store: store)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1180, height: 800)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updater: updater)
            }
            CommandGroup(replacing: .newItem) {
                Button("New Stream…") {
                    NotificationCenter.default.post(name: .showStreamLocation, object: nil)
                }
                .keyboardShortcut("l", modifiers: .command)
                Button("Browse Streams…") {
                    NotificationCenter.default.post(name: .showStreamBrowser, object: nil)
                }
                .keyboardShortcut("b", modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        do {
            try HLSProxy.shared.start()
        } catch {
            DispatchQueue.main.async {
                let alert = NSAlert(error: error)
                alert.messageText = "Crackstreams could not start"
                alert.informativeText = "The local playback service is unavailable. The app will now quit."
                alert.addButton(withTitle: "Quit")
                alert.runModal()
                NSApplication.shared.terminate(nil)
            }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
