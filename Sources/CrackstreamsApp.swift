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
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1280, height: 720)
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton(updater: updater)
            }
            CommandGroup(replacing: .newItem) {
                Button("Browse Streams…") {
                    NotificationCenter.default.post(name: .showStreamBrowser, object: nil)
                }
                .keyboardShortcut("b", modifiers: .command)
            }
            CommandMenu("Multiview") {
                Button("Show All Four Panes") {
                    store.focusedSlotID = nil
                }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(store.focusedSlotID == nil)

                Divider()

                ForEach(0..<StreamStore.maximumStreams, id: \.self) { index in
                    Button("Expand Pane \(index + 1)") {
                        store.toggleFocus(store.slots[index])
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .disabled(store.slots[index].isEmpty)
                }

                Divider()

                ForEach(0..<StreamStore.maximumStreams, id: \.self) { index in
                    Button("Solo Audio on Pane \(index + 1)") {
                        store.soloAudio(store.slots[index])
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: [.command, .option])
                    .disabled(store.slots[index].isEmpty)
                }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
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
