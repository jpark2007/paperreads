import SwiftUI
import SwiftData
import AppKit

final class PaperreadsAppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Light appearance only (§1) — also covers AppKit-hosted views (WKWebView, PDFView, menus).
        NSApp.appearance = NSAppearance(named: .aqua)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct PaperreadsApp: App {
    @NSApplicationDelegateAdaptor(PaperreadsAppDelegate.self) private var appDelegate
    @StateObject private var app = AppCommands.shared

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
        .commands { PaperreadsCommands(app: app) }

        Settings {
            SettingsView()
                .preferredColorScheme(.light)
                .tint(Theme.accent)
        }
    }
}
