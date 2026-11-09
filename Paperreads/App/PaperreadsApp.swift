import SwiftUI
import SwiftData
import AppKit
import SQLite3

/// Opens the library store at `PaperStore.storeURL`, first moving a library left at the
/// unsandboxed default location (`~/Library/Application Support/default.store`, used by
/// earlier builds) into place — only if that store is verifiably ours.
enum LibraryContainer {
    static func make() -> ModelContainer {
        let target = PaperStore.storeURL
        if let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            migrateLegacyStoreIfNeeded(from: base.appendingPathComponent("default.store"), to: target)
        }
        let schema = Schema(SchemaV1.models)
        let config = ModelConfiguration(schema: schema, url: target)
        do {
            return try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("Paperreads could not open its library at \(target.path): \(error)")
        }
    }

    /// The store file names that travel together (SQLite main file, write-ahead log, shared memory).
    private static let suffixes = ["", "-wal", "-shm"]

    /// Moves (never copies) `legacy` and its -wal/-shm to `target` when `target` does not exist
    /// yet and `legacy` is a Paperreads store. Must run before any container opens either file.
    static func migrateLegacyStoreIfNeeded(from legacy: URL, to target: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: target.path) else { return }
        guard fm.fileExists(atPath: legacy.path), isPaperreadsStore(legacy) else { return }
        // Never overwrite stray -wal/-shm files at the target that belong to nothing.
        for suffix in suffixes.dropFirst() {
            let stray = URL(fileURLWithPath: target.path + suffix)
            if fm.fileExists(atPath: stray.path) { try? fm.removeItem(at: stray) }
        }
        var moved: [(from: URL, to: URL)] = []
        for suffix in suffixes {
            let from = URL(fileURLWithPath: legacy.path + suffix)
            let to = URL(fileURLWithPath: target.path + suffix)
            guard fm.fileExists(atPath: from.path) else { continue }
            do {
                try fm.moveItem(at: from, to: to)
                moved.append((from, to))
            } catch {
                // Put back whatever already moved so the old store stays whole.
                for m in moved.reversed() { try? fm.moveItem(at: m.to, to: m.from) }
                NSLog("Paperreads: could not move the library from %@: %@", legacy.path, error.localizedDescription)
                return
            }
        }
        NSLog("Paperreads: moved the library from %@ to %@", legacy.path, target.path)
    }

    /// Read-only check: a Core Data/SwiftData SQLite store whose entities are exactly ours (plus
    /// SwiftData's history tables) and whose ZPAPER table has our columns.
    static func isPaperreadsStore(_ url: URL) -> Bool {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX
        guard sqlite3_open_v2(url.path, &db, flags, nil) == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return false
        }
        defer { sqlite3_close(db) }

        func strings(_ sql: String, column: Int32) -> [String]? {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { return nil }
            defer { sqlite3_finalize(stmt) }
            var out: [String] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { return nil }
                if let c = sqlite3_column_text(stmt, column) { out.append(String(cString: c)) }
            }
            return out
        }

        guard let entities = strings("SELECT Z_NAME FROM Z_PRIMARYKEY", column: 0) else { return false }
        let ours: Set<String> = ["Paper", "Highlight", "ReferenceEntry", "RefChunk", "ChatTurn"]
        let history: Set<String> = ["CHANGE", "TRANSACTION", "TRANSACTIONSTRING"]
        let found = Set(entities)
        guard ours.isSubset(of: found), found.isSubset(of: ours.union(history)) else { return false }

        guard let columns = strings("PRAGMA table_info(ZPAPER)", column: 1) else { return false }
        let required: Set<String> = ["ZID", "ZTITLE", "ZARXIVID", "ZIMPORTSTATERAW", "ZCONTENTKINDRAW",
                                     "ZREFERENCESSTATERAW", "ZHASPDF", "ZPAPERNOTES"]
        return required.isSubset(of: Set(columns))
    }
}

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
    /// Created before any view: a library left at the old default location is moved first.
    private let container: ModelContainer = LibraryContainer.make()

    var body: some Scene {
        // A single main window: AppCommands holds the one open paper session.
        Window("Paperreads", id: "main") {
            RootView()
                .environmentObject(app)
                .frame(minWidth: 1100, minHeight: 700)
                .preferredColorScheme(.light)
                .tint(Theme.accent)
        }
        .modelContainer(container)
        .defaultSize(width: 1400, height: 900)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands { PaperreadsCommands(app: app, prefs: readerPrefs) }

        Settings {
            SettingsView()
                .preferredColorScheme(.light)
                .tint(Theme.accent)
        }
        .modelContainer(container)
    }
}
