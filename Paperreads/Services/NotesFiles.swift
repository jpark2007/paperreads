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
// if the file was edited externally (its hash differs from our last write and the Notes section
// differs from what we wrote) the external text is pulled back into `Paper.paperNotes`.
// The "## Highlights" section is always regenerated; edits outside "## Notes" are kept as a
// conflict copy before being overwritten.
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

    /// The caller adopted a `.pulled` result as `paper.paperNotes`: record the file's Notes
    /// text as the new baseline so the next in-app edit isn't mistaken for a conflict.
    static func confirmPulled(id: UUID, notes: String, url: URL) {
        let folder = self.folder
        IO.queue.async { IO.shared.confirmPulled(id: id, notes: notes, url: url, folder: folder) }
    }

    /// Synchronous flush (app termination). Never pulls; never clobbers an external edit.
    /// `cancelExport` stops a running "Export all" first so the caller (quit) doesn't wait
    /// behind the whole library.
    static func flushSync(_ snapshot: Snapshot, cancelExport: Bool = false) {
        if cancelExport { exportGeneration.bump() }
        let folder = self.folder
        IO.queue.sync { _ = IO.shared.reconcile(snapshot, folder: folder, allowPull: false) }
    }

    /// Bumped to cancel exports started before the bump.
    private final class Generation: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var current: Int { lock.lock(); defer { lock.unlock() }; return value }
        func bump() { lock.lock(); value += 1; lock.unlock() }
    }
    private static let exportGeneration = Generation()

    /// Writes every snapshot; returns (files written or already current, failure messages).
    static func exportAll(_ snapshots: [Snapshot]) async -> (count: Int, failures: [String]) {
        let folder = self.folder
        let generation = exportGeneration.current
        return await withCheckedContinuation { cont in
            IO.queue.async {
                var ok = 0
                var failures: [String] = []
                // One directory listing for the whole export; the index is written once at the end.
                let names = IO.shared.listing(of: folder)
                for s in snapshots {
                    if exportGeneration.current != generation {
                        failures.append("Export cancelled.")
                        break
                    }
                    // Export never pulls: an externally edited file is left alone (.deferred).
                    switch IO.shared.reconcile(s, folder: folder, allowPull: false, names: names, persist: false) {
                    case .failed(let msg): failures.append("\(s.title): \(msg)")
                    default: ok += 1
                    }
                }
                IO.shared.persistIndex()
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
        } else if let container = try? ModelContainer(
            for: Schema(SchemaV1.models),
            configurations: ModelConfiguration(schema: Schema(SchemaV1.models), url: PaperStore.storeURL)) {
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
        // APFS caps a name at 255 UTF-8 bytes; leave room for " [xxxxxxxx].md" and a
        // " conflict <date> N" suffix. Drop whole Characters so clusters are never split.
        while s.utf8.count > 180 { s.removeLast() }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
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
                    out += scalar.value > 0xFFFF
                        ? String(format: "\\U%08X", scalar.value)
                        : String(format: "\\u%04X", scalar.value)
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
        // Match on the trimmed line: the parser trims before matching headings.
        let t = line.drop(while: { $0 == " " || $0 == "\t" })
        if t.hasPrefix("#") || t.hasPrefix(">") || t.hasPrefix("---") { return "\\" + line }
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
        guard let (all, _, notesIdx, stop) = notesBounds(of: markdown) else { return nil }
        var lines = Array(all[(notesIdx + 1)..<stop])
        // Drop the blank line(s) right after the heading that we emit.
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
        return normalizedNotes(lines.joined(separator: "\n"))
    }

    /// Lines of the file, the first line after the front matter, the "## Notes" heading index
    /// and the (exclusive) end of its body.
    private static func notesBounds(of markdown: String) -> ([String], Int, Int, Int)? {
        let text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = text.components(separatedBy: "\n")
        // Skip YAML front matter.
        var start = 0
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") { start = end + 1 }
        guard let notesIdx = lines[start...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## Notes" })
        else { return nil }
        let endIdx = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "## Highlights" })
        let stop = (endIdx.map { $0 > notesIdx ? $0 : lines.count }) ?? lines.count
        return (lines, start, notesIdx, stop)
    }

    /// Hash of everything in the file EXCEPT the Notes body (front matter, title, highlights,
    /// trailing text). Lets reconcile tell an edit outside "## Notes" from a Notes edit.
    static func restHash(of markdown: String) -> String? {
        guard let (lines, _, notesIdx, stop) = notesBounds(of: markdown) else { return nil }
        let rest = lines[...notesIdx] + ["\u{0}"] + lines[stop...]
        return hash(rest.joined(separator: "\n"))
    }

    /// Like `restHash`, but also ignoring the front matter and the H1: the parts that change
    /// with the title. Used to compare a stale pre-rename file with what we last wrote.
    static func bodyHash(of markdown: String) -> String? {
        guard let (lines, start, notesIdx, stop) = notesBounds(of: markdown) else { return nil }
        let pre = lines[start..<notesIdx].filter { !$0.hasPrefix("# ") }
        let rest = pre + ["\u{0}"] + lines[stop...]
        return hash(rest.joined(separator: "\n"))
    }

    static func hash(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - IO (serial queue)

    private final class IO: @unchecked Sendable {
        static let queue = DispatchQueue(label: "com.jonahpark.Paperreads.notesfiles", qos: .utility)
        static let shared = IO()

        struct Entry: Codable, Equatable {
            var folder: String
            var filename: String
            var contentHash: String
            var notesHash: String
            var mtime: Date
            /// `restHash(of:)` of what we last wrote (nil in indexes from older builds).
            var restHash: String?
            /// `bodyHash(of:)` of what we last wrote (nil in indexes from older builds).
            var bodyHash: String?
        }

        // "<paperId>|<folder path>" → entry, so returning to a folder keeps its baseline.
        // (Older indexes are keyed by paperId alone; those entries are still read.)
        private var index: [String: Entry]?   // loaded lazily on the queue
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

        /// Writes the in-memory index (after a batch of `persist: false` reconciles).
        func persistIndex() {
            if let index { saveIndex(index) }
        }

        private func key(_ id: UUID, _ folder: URL) -> String { id.uuidString + "|" + folder.path }

        private func entry(in idx: [String: Entry], id: UUID, folder: URL) -> Entry? {
            if let e = idx[key(id, folder)] { return e }
            return idx[id.uuidString].flatMap { $0.folder == folder.path ? $0 : nil }
        }

        private func setEntry(_ e: Entry, in idx: inout [String: Entry], id: UUID, folder: URL) {
            idx[key(id, folder)] = e
            if idx[id.uuidString]?.folder == folder.path { idx.removeValue(forKey: id.uuidString) }
        }

        func listing(of folder: URL) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }
        }

        private func mtime(_ url: URL) -> Date? {
            (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        }

        private func exists(_ url: URL) -> Bool {
            var isDir: ObjCBool = false
            return fm.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
        }

        /// Locate this paper's existing file in `folder` (index first, then a suffix scan).
        /// `names`: a pre-taken folder listing (export); candidates are re-checked on disk.
        private func existingFile(for s: Snapshot, entry: Entry?, folder: URL, expected: URL,
                                  names: [String]?) -> URL? {
            let suffix = NotesFiles.suffix(for: s.id)
            let names = names ?? listing(of: folder)
            let candidates = names.filter { $0.hasSuffix(suffix) && !$0.hasPrefix(".") }
                .map { folder.appendingPathComponent($0) }
                .filter(exists)
            // Several files carry this paper's id (e.g. an editor re-saved the pre-rename
            // path): use the most recently modified one so its edits aren't ignored.
            if candidates.count > 1 {
                return candidates.max { a, b in
                    let ma = mtime(a) ?? .distantPast, mb = mtime(b) ?? .distantPast
                    if ma != mb { return ma < mb }
                    return a.lastPathComponent != expected.lastPathComponent   // tie → expected
                }
            }
            if exists(expected) { return expected }
            if let e = entry, e.folder == folder.path {
                let u = folder.appendingPathComponent(e.filename)
                if exists(u) { return u }
            }
            return candidates.first
        }

        func confirmPulled(id: UUID, notes: String, url: URL, folder: URL) {
            var idx = loadIndex()
            guard var e = entry(in: idx, id: id, folder: folder),
                  let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8),
                  let n = NotesFiles.notesSection(of: text),
                  n == NotesFiles.normalizedNotes(notes) else { return }
            e.notesHash = NotesFiles.hash(n)
            if url.lastPathComponent != e.filename, exists(folder.appendingPathComponent(e.filename)) {
                // Pulled from a stale duplicate (e.g. an editor re-saved the pre-rename path):
                // keep the baseline of the file we own; only the Notes text is now adopted.
                setEntry(e, in: &idx, id: id, folder: folder)
                saveIndex(idx)
                return
            }
            e.filename = url.lastPathComponent
            e.mtime = mtime(url) ?? e.mtime
            // Only take the whole file as baseline if nothing outside Notes changed too;
            // otherwise the next write still sees (and backs up) that outside edit.
            if let r = e.restHash, NotesFiles.restHash(of: text) == r {
                e.contentHash = NotesFiles.hash(text)
            }
            setEntry(e, in: &idx, id: id, folder: folder)
            saveIndex(idx)
        }

        /// `persist: false` updates the index in memory only (call `persistIndex()` afterwards).
        func reconcile(_ s: Snapshot, folder: URL, allowPull: Bool,
                       names: [String]? = nil, persist: Bool = true) -> Outcome {
            do {
                try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            } catch {
                return .failed("Couldn't create the notes folder (\(error.localizedDescription))")
            }

            var idx = loadIndex()
            // Entries recorded for a different folder don't describe files in this one.
            let entry = self.entry(in: idx, id: s.id, folder: folder)
            let expected = folder.appendingPathComponent(NotesFiles.fileName(for: s))
            let content = NotesFiles.render(s)
            let contentHash = NotesFiles.hash(content)
            let contentRestHash = NotesFiles.restHash(of: content)
            let contentBodyHash = NotesFiles.bodyHash(of: content)
            let currentNotes = NotesFiles.normalizedNotes(s.notes)
            let currentNotesHash = NotesFiles.hash(currentNotes)

            var target = expected
            var backupURL: URL?

            if let existing = existingFile(for: s, entry: entry, folder: folder, expected: expected, names: names) {
                let diskData: Data
                do {
                    diskData = try Data(contentsOf: existing)
                } catch {
                    // Unknown contents (evicted iCloud file, lock, I/O error): never overwrite.
                    return .failed("Couldn't read \(existing.lastPathComponent) (\(error.localizedDescription))")
                }
                let diskText = String(data: diskData, encoding: .utf8)
                let diskHash = diskText.map(NotesFiles.hash)

                // Was the file changed by someone other than us since our last write?
                var externallyChanged = false
                var externalNotes: String?
                // Edited externally in a way we can't parse (e.g. the "## Notes" heading removed):
                // never pull, but never silently overwrite either — keep a copy first.
                var unparseableEdit = false
                // Text outside "## Notes" (front matter, highlights, trailing text) was edited:
                // it is regenerated on write, so keep a copy before overwriting it.
                var outsideEdit = false
                if let diskText {
                    if let e = entry {
                        // The hash alone proves the file isn't what we wrote (mtime can be
                        // preserved/restored by sync tools, Time Machine, cp -p…).
                        if diskHash != e.contentHash, diskHash != contentHash {
                            externalNotes = NotesFiles.notesSection(of: diskText)
                            if let n = externalNotes {
                                if NotesFiles.hash(n) != e.notesHash { externallyChanged = true }
                                if existing.lastPathComponent != e.filename, let b = e.bodyHash {
                                    // A stale pre-rename duplicate: its front matter and H1
                                    // still carry the old title, which is not an edit.
                                    outsideEdit = NotesFiles.bodyHash(of: diskText) != b
                                } else if let r = e.restHash {
                                    outsideEdit = NotesFiles.restHash(of: diskText) != r
                                } else {
                                    // Older index: no record of the rest; a change that isn't
                                    // in Notes must be outside it.
                                    outsideEdit = !externallyChanged
                                }
                            } else {
                                unparseableEdit = true
                            }
                        }
                    } else if let n = NotesFiles.notesSection(of: diskText) {
                        // No record of writing this file (index lost / folder switched): anything
                        // outside Notes that differs from what we'd write would be regenerated,
                        // so treat it as an outside edit and keep a copy first.
                        if n != currentNotes {
                            externalNotes = n
                            externallyChanged = true
                        }
                        if diskHash != contentHash {
                            outsideEdit = NotesFiles.restHash(of: diskText) != contentRestHash
                        }
                    } else if diskHash != contentHash {
                        unparseableEdit = true
                    }
                } else {
                    // Not UTF-8: preserve whatever is there before writing.
                    unparseableEdit = true
                }
                // The app already adopted the external text (a previous `.pulled`): no conflict.
                if externallyChanged, externalNotes == currentNotes { externallyChanged = false }

                if unparseableEdit || (outsideEdit && !externallyChanged) {
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
                        // External editor wins. (An outside-Notes edit is still caught and backed
                        // up by the next write: confirmPulled keeps the old content baseline.)
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
                        // Several files carry this id and the newest one isn't the expected
                        // name: the expected file is about to be overwritten without having
                        // been checked above, so preserve it unless it's what we wrote.
                        let expData: Data
                        do {
                            expData = try Data(contentsOf: expected)
                        } catch {
                            return .failed("Couldn't read \(expected.lastPathComponent) (\(error.localizedDescription))")
                        }
                        let expHash = String(data: expData, encoding: .utf8).map(NotesFiles.hash)
                        let ours = expHash != nil && (expHash == contentHash || expHash == entry?.contentHash)
                        if !ours {
                            let backup = conflictURL(for: expected)
                            do {
                                try fm.copyItem(at: expected, to: backup)
                                if backupURL == nil { backupURL = backup }
                            } catch {
                                return .failed("Couldn't preserve the externally edited file (\(error.localizedDescription))")
                            }
                        }
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
                    let old = self.entry(in: idx, id: s.id, folder: folder)
                    var m = mtime(target) ?? Date()
                    if let old, abs(old.mtime.timeIntervalSince(m)) < 1 { m = old.mtime }   // JSON second precision
                    let e = Entry(folder: folder.path, filename: target.lastPathComponent,
                                  contentHash: contentHash, notesHash: currentNotesHash, mtime: m,
                                  restHash: contentRestHash, bodyHash: contentBodyHash)
                    // Only touch the index when the entry actually changed.
                    if old != e || idx[key(s.id, folder)] == nil {
                        setEntry(e, in: &idx, id: s.id, folder: folder)
                        store(idx, persist: persist)
                    }
                    return .synced(target)
                }
            }

            do {
                try Data(content.utf8).write(to: target, options: .atomic)
            } catch {
                return .failed("Couldn't write \(target.lastPathComponent) (\(error.localizedDescription))")
            }
            setEntry(Entry(folder: folder.path, filename: target.lastPathComponent,
                           contentHash: contentHash, notesHash: currentNotesHash,
                           mtime: mtime(target) ?? Date(), restHash: contentRestHash,
                           bodyHash: contentBodyHash),
                     in: &idx, id: s.id, folder: folder)
            store(idx, persist: persist)
            if let backupURL { return .conflict(url: target, backup: backupURL) }
            return .synced(target)
        }

        private func store(_ idx: [String: Entry], persist: Bool) {
            if persist { saveIndex(idx) } else { index = idx }
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
