import SwiftUI
import SwiftData
import AppKit

@MainActor
final class PaperreadsAppDelegate: NSObject, NSApplicationDelegate {
    private var keyMonitor: Any?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Light appearance only (§1) — also covers AppKit-hosted views (WKWebView, PDFView, menus).
        NSApp.appearance = NSAppearance(named: .aqua)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Reading position is flushed when a window closes (the app then quits) …
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)),
                                               name: NSWindow.willCloseNotification, object: nil)
        // View ▸ Larger Text is ⌘+ in the menu; also accept ⌘= (the same key without Shift).
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods == .command, event.charactersIgnoringModifiers == "=" else { return event }
            // Local monitors run on the main thread. Only act in the main window while the
            // text reader is showing (as the menu item does); otherwise pass the key on.
            // Not the Settings window (SwiftUI names it "com_apple_SwiftUI_Settings_window").
            let inMainWindow = event.window.map { !($0.identifier?.rawValue.contains("Settings") ?? false) } ?? false
            let handled = MainActor.assumeIsolated { () -> Bool in
                let prefs = ReaderPreferences.shared
                guard inMainWindow, AppCommands.shared.canResizeReaderText, prefs.canIncrease else { return false }
                prefs.increase()
                return true
            }
            return handled ? nil : event
        }
    }

    func applicationWillResignActive(_ notification: Notification) {
        AppCommands.shared.flushReadingPositionFetchingLatest()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // … and on quit (synchronous: the last throttled report is what gets saved).
        AppCommands.shared.flushReadingPosition()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    @objc private func windowWillClose(_ notification: Notification) {
        AppCommands.shared.flushReadingPosition()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct PaperreadsApp: App {
    @NSApplicationDelegateAdaptor(PaperreadsAppDelegate.self) private var appDelegate
    @StateObject private var app = AppCommands.shared
    @StateObject private var readerPrefs = ReaderPreferences.shared

    var body: some Scene {
        // A single main window: AppCommands holds the one open paper session.
        Window("Paperreads", id: "main") {
            RootView()
                .environmentObject(app)
                .frame(minWidth: 1100, minHeight: 700)
                .preferredColorScheme(.light)
                .tint(Theme.accent)
        }
        .modelContainer(for: SchemaV1.models)
        .defaultSize(width: 1400, height: 900)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { PaperreadsCommands(app: app, prefs: readerPrefs) }

        Settings {
            SettingsView()
                .preferredColorScheme(.light)
                .tint(Theme.accent)
        }
    }
}
