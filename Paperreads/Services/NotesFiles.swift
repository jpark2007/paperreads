import Foundation
import AppKit
import CryptoKit
import SwiftData

// Mirrors each paper's notes + highlights to a plain Markdown file in a user-visible folder
// (default ~/Paperreads/Notes — deliberately NOT ~/Documents / ~/Desktop / ~/Downloads, which
// are TCC-protected and would re-prompt on every rebuild of this ad-hoc-signed app).
//
// File: "<sanitized title, ≤80 chars> [<first 8 of uuid>].md". The "[xxxxxxxx].md" suffix is the
// stable key: a title change renames the existing file. The "## Notes" section is two-way —
// if the file was edited externally (mtime newer than our last write and the Notes section
// differs from what we wrote) the external text is pulled back into `Paper.paperNotes`.
// The "## Highlights" section is always regenerated.
//
// All disk IO runs on one private serial queue (value snapshots in, value outcomes out), so the
// main actor never blocks except for the explicit synchronous flush at app termination.
// User files are never deleted; the only destructive operation is the rename on title change.

enum NotesFiles {
    // MARK: Folder

    static let folderDefaultsKey = "notesFolderPath"

    static var defaultFolder: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Paperreads", isDirectory: true)
            .appendingPathComponent("Notes", isDirectory: true)
    }

    /// The current notes folder (UserDefaults override, else the default).
    static var folder: URL {
        if let p = UserDefaults.standard.string(forKey: folderDefaultsKey), !p.isEmpty {
            return URL(fileURLWithPath: p, isDirectory: true)
        }
        return defaultFolder
    }

    /// `nil` resets to the default folder.
    static func setFolder(_ url: URL?) {
        if let url {
            UserDefaults.standard.set(url.standardizedFileURL.path, forKey: folderDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: folderDefaultsKey)
        }
        NotificationCenter.default.post(name: folderDidChange, object: nil)
    }

    static let folderDidChange = Notification.Name("NotesFilesFolderDidChange")

    /// "~/Paperreads/Notes" style display path.
    static func displayPath(_ url: URL) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let p = url.standardizedFileURL.path
        if p == home { return "~" }
        if p.hasPrefix(home + "/") { return "~" + p.dropFirst(home.count) }
        return p
    }

    // MARK: Snapshots (Sendable values handed to the IO queue)

    struct HighlightSnapshot: Equatable, Sendable {
        var quote: String
        var note: String
        var blockIndex: Int
        var startOffset: Int
    }

    struct Snapshot: Equatable, Sendable {
        var id: UUID
        var title: String
        var authors: [String]
        var year: Int?
        var arxivId: String?
        var doi: String?
        var status: String
        var tags: [String]
        var notes: String
        var highlights: [HighlightSnapshot]
    }

    @MainActor
    static func snapshot(of paper: Paper, highlights: [Highlight]) -> Snapshot {
        let hs = highlights
            .sorted { ($0.blockIndex, $0.startOffset) < ($1.blockIndex, $1.startOffset) }
            .map { HighlightSnapshot(quote: $0.quote, note: $0.note, blockIndex: $0.blockIndex, startOffset: $0.startOffset) }
        return Snapshot(id: paper.id, title: paper.title, authors: paper.authors, year: paper.year,
                        arxivId: paper.arxivId, doi: paper.doi, status: paper.statusRaw,
                        tags: paper.tags, notes: paper.paperNotes, highlights: hs)
    }

    @MainActor
    static func snapshot(of paper: Paper, in context: ModelContext) -> Snapshot {
        let pid = paper.id
        let hs = (try? context.fetch(FetchDescriptor<Highlight>(predicate: #Predicate<Highlight> { $0.paperId == pid }))) ?? []
        return snapshot(of: paper, highlights: hs)
    }

    // MARK: Outcomes

    enum Outcome: Sendable {
        /// File is current (written now, or already identical).
        case synced(URL)
        /// The file's Notes section was edited outside the app; the caller should adopt `notes`
        /// as `paper.paperNotes` (external editor wins). The file itself was left untouched.
        case pulled(notes: String, url: URL)
        /// Both sides changed since our last write: the external version was preserved as
        /// `backup` before the in-app version was written to `url`.
        case conflict(url: URL, backup: URL)
        /// External edit detected during a flush that cannot pull (app terminating); the file
        /// was left as-is so nothing is lost. It will be pulled the next time the panel appears.
        case deferred(URL)
        case failed(String)

        var url: URL? {
            switch self {
            case .synced(let u), .deferred(let u): return u
            case .pulled(_, let u): return u
            case .conflict(let u, _): return u
            case .failed: return nil
            }
        }
    }

    // MARK: Public API

    /// Debounced/async path: reconcile on the IO queue.
    static func sync(_ snapshot: Snapshot, allowPull: Bool = true) async -> Outcome {
        let folder = self.folder
        return await withCheckedContinuation { cont in
            IO.queue.async {
                cont.resume(returning: IO.shared.reconcile(snapshot, folder: folder, allowPull: allowPull))
            }
        }
    }

    /// Synchronous flush (app termination). Never pulls; never clobbers an external edit.
    static func flushSync(_ snapshot: Snapshot) {
        let folder = self.folder
        IO.queue.sync { _ = IO.shared.reconcile(snapshot, folder: folder, allowPull: false) }
    }

    /// Writes every snapshot; returns (files written or already current, failure messages).
    static func exportAll(_ snapshots: [Snapshot]) async -> (count: Int, failures: [String]) {
        let folder = self.folder
        return await withCheckedContinuation { cont in
            IO.queue.async {
                var ok = 0
                var failures: [String] = []
                for s in snapshots {
                    // Export never pulls: an externally edited file is left alone (.deferred).
                    switch IO.shared.reconcile(s, folder: folder, allowPull: false) {
                    case .failed(let msg): failures.append("\(s.title): \(msg)")
                    default: ok += 1
                    }
                }
                cont.resume(returning: (ok, failures))
            }
        }
    }

    // MARK: Context registry (so Settings → "Export all now" can reach the library)

    @MainActor private static weak var registeredContainer: ModelContainer?

    @MainActor static func register(_ context: ModelContext) {
        registeredContainer = context.container
    }

    /// Snapshots of every paper in the library.
    @MainActor
    static func allSnapshots() -> [Snapshot] {
        let context: ModelContext
        if let c = registeredContainer {
            context = c.mainContext
        } else if let s = AppCommands.shared.session {
            context = s.context
        } else if let container = try? ModelContainer(for: Schema(SchemaV1.models)) {
            context = ModelContext(container)
        } else {
            return []
        }
        let papers = (try? context.fetch(FetchDescriptor<Paper>())) ?? []
        let highlights = (try? context.fetch(FetchDescriptor<Highlight>())) ?? []
        let byPaper = Dictionary(grouping: highlights, by: \.paperId)
        return papers.map { snapshot(of: $0, highlights: byPaper[$0.id] ?? []) }
    }

    // MARK: Pure helpers (file naming, rendering, parsing)

    static func shortId(_ id: UUID) -> String {
        String(id.uuidString.prefix(8)).lowercased()
    }

    static func suffix(for id: UUID) -> String { "[\(shortId(id))].md" }

    static func sanitizedTitle(_ title: String) -> String {
        var s = String(title.unicodeScalars.map { scalar -> Character in
            if scalar == "/" || scalar == ":" || scalar == "\\" { return " " }
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) { return " " }
            return Character(scalar)
        })
        // Collapse runs of whitespace.
        s = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix(".") { s.removeFirst() }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > 80 {
            s = String(s.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Avoid a trailing dot before " [id].md" looking odd / confusing some sync tools.
        while s.hasSuffix(".") { s.removeLast() }
        return s.isEmpty ? "Untitled" : s
    }

    static func fileName(for s: Snapshot) -> String {
        "\(sanitizedTitle(s.title)) \(suffix(for: s.id))"
    }

    static func yamlString(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if CharacterSet.controlCharacters.contains(scalar) {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + "\""
    }

    static func yamlList(_ items: [String]) -> String {
        "[" + items.map(yamlString).joined(separator: ", ") + "]"
    }

    /// Lines of generated (non-user) text that could be mistaken for structure are escaped.
    private static func escapeGeneratedLine(_ line: String) -> String {
        if line.hasPrefix("#") || line.hasPrefix(">") || line.hasPrefix("---") { return "\\" + line }
        return line
    }

    static func normalizedNotes(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "\r\n", with: "\n")
        while t.first == "\n" { t.removeFirst() }
        while let last = t.last, last == "\n" || last == " " || last == "\t" { t.removeLast() }
        return t
    }

    static func render(_ s: Snapshot) -> String {
        var out = "---\n"
        out += "title: \(yamlString(s.title))\n"
        out += "authors: \(yamlList(s.authors))\n"
        if let y = s.year { out += "year: \(y)\n" }
        if let a = s.arxivId, !a.isEmpty { out += "arxiv: \(yamlString(a))\n" }
        if let d = s.doi, !d.isEmpty { out += "doi: \(yamlString(d))\n" }
        out += "status: \(s.status)\n"
        out += "tags: \(yamlList(s.tags))\n"
        out += "paperreads_id: \(s.id.uuidString)\n"
        out += "---\n\n"
        let heading = s.title.split(whereSeparator: \.isNewline).joined(separator: " ")
        out += "# \(heading.isEmpty ? "Untitled" : heading)\n\n"
        out += "## Notes\n\n"
        let notes = normalizedNotes(s.notes)
        if !notes.isEmpty { out += notes + "\n\n" }
        out += "## Highlights\n"
        for h in s.highlights {
            out += "\n"
            let quoteLines = h.quote.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            for line in quoteLines { out += line.isEmpty ? ">\n" : "> \(line)\n" }
            out += "\n"
            let note = normalizedNotes(h.note)
            if note.isEmpty {
                out += "¶\(h.blockIndex)\n"
            } else {
                let lines = note.components(separatedBy: "\n").map(escapeGeneratedLine)
                out += lines.joined(separator: "\n") + " — ¶\(h.blockIndex)\n"
            }
        }
        return out
    }

    /// The text of the "## Notes" section, or nil if the file has no such heading.
    /// The section ends at the LAST "## Highlights" line (generated text never contains one,
    /// so user notes may safely contain their own "## Highlights" heading above it).
    static func notesSection(of markdown: String) -> String? {
        let text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = text.components(separatedBy: "\n")
        // Skip YAML front matter.
        var start = 0
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") { start = end + 1 }
        guard let notesIdx = lines[start...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## Notes" })
        else { return nil }
        let endIdx = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## Highlights" })
        let stop = (endIdx.map { $0 > notesIdx ? $0 : lines.count }) ?? lines.count
        lines = Array(lines[(notesIdx + 1)..<stop])
        // Drop the blank line(s) right after the heading that we emit.
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        return normalizedNotes(lines.joined(separator: "\n"))
    }

    static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - IO (serial queue)

    private final class IO: @unchecked Sendable {
        static let queue = DispatchQueue(label: "com.jonahpark.Paperreads.notesfiles", qos: .utility)
        static let shared = IO()

        struct Entry: Codable {
            var folder: String
            var filename: String
            var contentHash: String
            var notesHash: String
            var mtime: Date
        }

        private var index: [String: Entry]?   // paperId → entry; loaded lazily on the queue
        private let fm = FileManager.default
        private var indexURL: URL { PaperStore.appSupport.appendingPathComponent("notes-index.json") }

        private func loadIndex() -> [String: Entry] {
            if let index { return index }
            var loaded: [String: Entry] = [:]
            if let data = try? Data(contentsOf: indexURL) {
                let dec = JSONDecoder()
                dec.dateDecodingStrategy = .secondsSince1970
                loaded = (try? dec.decode([String: Entry].self, from: data)) ?? [:]
            }
            index = loaded
            return loaded
        }

        private func saveIndex(_ idx: [String: Entry]) {
            index = idx
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .secondsSince1970
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? enc.encode(idx) { try? data.write(to: indexURL, options: .atomic) }
        }

        private func mtime(_ url: URL) -> Date? {
            (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }

        private func exists(_ url: URL) -> Bool {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
        }

        /// Locate this paper's existing file in `folder` (index first, then a suffix scan).
        private func existingFile(for s: Snapshot, entry: Entry?, folder: URL, expected: URL) -> URL? {
            if exists(expected) { return expected }
            if let e = entry, e.folder == folder.path {
                let u = folder.appendingPathComponent(e.filename)
                if exists(u) { return u }
            }
            let suffix = NotesFiles.suffix(for: s.id)
            let names = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []
            if let name = names.filter({ $0.hasSuffix(suffix) && !$0.hasPrefix(".") }).sorted().first {
                return folder.appendingPathComponent(name)
            }
            return nil
        }

        func reconcile(_ s: Snapshot, folder: URL, allowPull: Bool) -> Outcome {
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                return .failed("Couldn't create the notes folder (\(error.localizedDescription))")
            }

            var idx = loadIndex()
            let key = s.id.uuidString
            // Entries recorded for a different folder don't describe files in this one.
            let entry = idx[key].flatMap { $0.folder == folder.path ? $0 : nil }
            let expected = folder.appendingPathComponent(NotesFiles.fileName(for: s))
            let content = NotesFiles.render(s)
            let contentHash = NotesFiles.hash(content)
            let currentNotes = NotesFiles.normalizedNotes(s.notes)
            let currentNotesHash = NotesFiles.hash(currentNotes)

            var target = expected
            var backupURL: URL?

            if let existing = existingFile(for: s, entry: entry, folder: folder, expected: expected) {
                let diskData = try? Data(contentsOf: existing)
                let diskText = diskData.flatMap { String(data: $0, encoding: .utf8) }
                let diskHash = diskText.map(NotesFiles.hash)

                // Was the file changed by someone other than us since our last write?
                var externallyChanged = false
                var externalNotes: String?
                // Edited externally in a way we can't parse (e.g. the "## Notes" heading removed):
                // never pull, but never silently overwrite either — keep a copy first.
                var unparseableEdit = false
                if let diskText {
                    if let e = entry {
                        let newer = (mtime(existing) ?? .distantPast).timeIntervalSince(e.mtime) > 0.5
                        if newer && diskHash != e.contentHash {
                            externalNotes = NotesFiles.notesSection(of: diskText)
                            if let n = externalNotes {
                                if NotesFiles.hash(n) != e.notesHash { externallyChanged = true }
                            } else {
                                unparseableEdit = true
                            }
                        }
                    } else if let n = NotesFiles.notesSection(of: diskText) {
                        // No record of writing this file (index lost / folder switched).
                        if n != currentNotes {
                            externalNotes = n
                            externallyChanged = true
                        }
                    } else if diskHash != contentHash {
                        unparseableEdit = true
                    }
                } else {
                    // Not UTF-8 / unreadable: preserve whatever is there before writing.
                    unparseableEdit = diskData != nil
                }
                // The app already adopted the external text (a previous `.pulled`): no conflict.
                if externallyChanged, externalNotes == currentNotes { externallyChanged = false }

                if unparseableEdit {
                    let backup = conflictURL(for: existing)
                    do {
                        try fm.copyItem(at: existing, to: backup)
                        backupURL = backup
                    } catch {
                        return .failed("Couldn't preserve the externally edited file (\(error.localizedDescription))")
                    }
                } else if externallyChanged, let ext = externalNotes {
                    // Did the in-app notes change since our last write?
                    let appChanged: Bool
                    if let e = entry { appChanged = currentNotesHash != e.notesHash }
                    else { appChanged = !currentNotes.isEmpty }

                    if !appChanged {
                        // External editor wins.
                        if allowPull { return .pulled(notes: ext, url: existing) }
                        return .deferred(existing)
                    }
                    // Both changed: keep the external version as a sibling file, then write ours.
                    let backup = conflictURL(for: existing)
                    do {
                        try fm.copyItem(at: existing, to: backup)
                        backupURL = backup
                    } catch {
                        return .failed("Couldn't preserve the externally edited file (\(error.localizedDescription))")
                    }
                }

                // Rename on title change (the only operation that removes a path we own).
                if existing.lastPathComponent != expected.lastPathComponent {
                    if exists(expected) {
                        target = expected   // leave the old one alone rather than overwrite
                    } else {
                        do {
                            try fm.moveItem(at: existing, to: expected)
                        } catch {
                            target = existing   // keep writing to the old name
                        }
                    }
                }

                // Content unchanged: just make sure the index is current.
                if backupURL == nil, target.path == existing.path || !exists(existing),
                   let diskHash, diskHash == contentHash {
                    let m = mtime(target) ?? Date()
                    idx[key] = Entry(folder: folder.path, filename: target.lastPathComponent,
                                     contentHash: contentHash, notesHash: currentNotesHash, mtime: m)
                    saveIndex(idx)
                    return .synced(target)
                }
            }

            do {
                try Data(content.utf8).write(to: target, options: .atomic)
            } catch {
                return .failed("Couldn't write \(target.lastPathComponent) (\(error.localizedDescription))")
            }
            idx[key] = Entry(folder: folder.path, filename: target.lastPathComponent,
                             contentHash: contentHash, notesHash: currentNotesHash,
                             mtime: mtime(target) ?? Date())
            saveIndex(idx)
            if let backupURL { return .conflict(url: target, backup: backupURL) }
            return .synced(target)
        }

        private func conflictURL(for url: URL) -> URL {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HHmmss"
            let base = url.deletingPathExtension().lastPathComponent
            var candidate = url.deletingLastPathComponent()
                .appendingPathComponent("\(base) conflict \(f.string(from: Date())).md")
            var n = 2
            while fm.fileExists(atPath: candidate.path) {
                candidate = url.deletingLastPathComponent()
                    .appendingPathComponent("\(base) conflict \(f.string(from: Date())) \(n).md")
                n += 1
            }
            return candidate
        }
    }
}
