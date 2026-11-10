import Foundation
import AppKit
import PDFKit
import SwiftData
import CryptoKit

// Module C — import pipeline (docs/ARCHITECTURE.md §3).
//
// One import pipeline runs at a time (FIFO queue). Reference fetching for a finished paper
// runs on its own serialized lane so the reader becomes usable as soon as text is ready.
// Every state change is saved immediately. Papers deleted mid-import are detected before
// every write and the pipeline stops without recreating their directory.

// MARK: - Errors

enum ImportError: LocalizedError {
    case unrecognized
    case noOpenAccessPDF
    case notAPDF
    case fileTooLarge(Int)
    case unreadableFile
    case missingPDF
    case missingAPIKey
    case pdfTooLong(Int)
    case emptyConversion
    case paperRemoved
    case conversionTooLong
    /// Neither Claude nor local extraction produced text (associated: why Claude didn't).
    case noExtractableText(String?)
    /// Internal: the paper was a duplicate and was folded into the existing one.
    case merged
    /// arXiv's HTML text could not be fetched (network error, timeout, 429/5xx).
    case arxivUnreachable
    /// Reprocess could only have produced lower-fidelity text than the paper already has.
    case wouldDowngrade(String?)

    var errorDescription: String? {
        switch self {
        case .unrecognized:
            return "Enter an arXiv id or link, or a DOI (for example 2401.12345 or 10.1145/3442188.3445922)."
        case .noOpenAccessPDF:
            return "No open-access PDF found — drag the PDF in instead."
        case .notAPDF:
            return "That file is not a PDF."
        case .fileTooLarge(let limit):
            return "The PDF is larger than \(HTTP.formatBytes(limit))."
        case .unreadableFile:
            return "The file could not be read."
        case .missingPDF:
            return "The PDF for this paper is missing."
        case .missingAPIKey:
            return "Add your Anthropic API key in Settings to convert PDFs."
        case .pdfTooLong(let pages):
            return "The PDF has \(pages) pages; at most 600 can be converted."
        case .emptyConversion:
            return "The PDF conversion produced no text."
        case .paperRemoved:
            return "The paper was removed."
        case .conversionTooLong:
            return "The paper is too long to convert in one pass, and Claude stopped before reaching any text."
        case .noExtractableText(let reason):
            let base = "This PDF has no extractable text (it may be a scanned image)."
            guard let reason, !reason.isEmpty else { return base }
            return reason + " " + base
        case .merged:
            return "This paper is already in your library."
        case .arxivUnreachable:
            return "arXiv's HTML text couldn't be fetched right now."
        case .wouldDowngrade(let reason):
            let base = "Reprocess could only produce lower-quality text, so the existing text was kept."
            guard let reason, !reason.isEmpty else { return base }
            return reason + " " + base
        }
    }
}

// MARK: - Input parsing

/// arXiv identifier helpers. New style: `YYMM.NNNNN` (4–5 digits), old style:
/// `archive(.SC)?/YYMMNNN`; both with an optional `vN` suffix.
enum ArxivID {
    private static let newStyle = try! NSRegularExpression(
        pattern: #"^(\d{2})(0[1-9]|1[0-2])\.(\d{4,5})(v[1-9]\d{0,3})?$"#)
    private static let oldStyle = try! NSRegularExpression(
        pattern: #"^([a-z]+(?:-[a-z]+)?)(\.[A-Z]{2})?/(\d{2})(0[1-9]|1[0-2])(\d{3})(v[1-9]\d{0,3})?$"#)
    /// Leading id at the start of an arxiv.org path remainder.
    private static let newPrefix = try! NSRegularExpression(
        pattern: #"^(\d{4}\.\d{4,5}(?:v[1-9]\d{0,3})?)(?:$|[/.?#])"#)
    private static let oldPrefix = try! NSRegularExpression(
        pattern: #"^([a-z]+(?:-[a-z]+)?(?:\.[A-Z]{2})?/\d{7}(?:v[1-9]\d{0,3})?)(?:$|[/.?#])"#)

    static func isValid(_ s: String) -> Bool {
        guard s.count <= 40 else { return false }
        let r = NSRange(s.startIndex..., in: s)
        if let m = newStyle.firstMatch(in: s, range: r) {
            // 5-digit sequence numbers only exist from 1501 onwards.
            let seq = (s as NSString).substring(with: m.range(at: 3))
            if seq.count == 5 {
                let yymm = Int((s as NSString).substring(with: m.range(at: 1)) +
                               (s as NSString).substring(with: m.range(at: 2))) ?? 0
                return yymm >= 1501
            }
            return true
        }
        return oldStyle.firstMatch(in: s, range: r) != nil
    }

    static func stripVersion(_ id: String) -> String {
        guard let r = id.range(of: #"v[1-9]\d{0,3}$"#, options: .regularExpression) else { return id }
        return String(id[..<r.lowerBound])
    }

    /// Extracts an id from the path remainder after `/abs/`, `/pdf/` or `/html/`.
    static func fromPathRemainder(_ rest: String) -> String? {
        let r = NSRange(rest.startIndex..., in: rest)
        for re in [newPrefix, oldPrefix] {
            if let m = re.firstMatch(in: rest, range: r), let range = Range(m.range(at: 1), in: rest) {
                let id = String(rest[range])
                return isValid(id) ? id : nil
            }
        }
        return nil
    }

    /// The arXiv margin stamp: "arXiv:2401.12345v2 [cs.CL] 3 Jan 2024". The category token
    /// distinguishes the paper's own id from preprints it merely cites.
    static func findStamp(_ text: String) -> String? {
        find(text, patterns: [#"arXiv:(\d{4}\.\d{4,5})(v\d+)?\s*\[[A-Za-z][A-Za-z.\-]{0,30}\]"#,
                              #"arXiv:([a-z]+(?:-[a-z]+)?(?:\.[A-Z]{2})?/\d{7})(v\d+)?\s*\[[A-Za-z][A-Za-z.\-]{0,30}\]"#])
    }

    /// The full arXiv margin stamp as arXiv prints it: id WITH version, category, and date
    /// ("arXiv:2401.12345v2 [cs.CL] 3 Jan 2024"). References and footnotes in Zotero/Mendeley
    /// style ("arXiv:2106.09685 [cs]") lack the version + date, so this form is safe to trust
    /// anywhere on the page.
    static func findDatedStamp(_ text: String) -> String? {
        let date = #"\s*\d{1,2}\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.?\s+\d{4}"#
        return find(text, patterns: [#"arXiv:(\d{4}\.\d{4,5})(v\d+)\s*\[[A-Za-z][A-Za-z.\-]{0,30}\]"# + date,
                                     #"arXiv:([a-z]+(?:-[a-z]+)?(?:\.[A-Z]{2})?/\d{7})(v\d+)\s*\[[A-Za-z][A-Za-z.\-]{0,30}\]"# + date])
    }

    /// The first "arXiv:XXXX.XXXXX(vN)" anywhere in the text. May be a cited preprint, so the
    /// caller must confirm it (see PDFIdentityResolver).
    static func findInText(_ text: String) -> String? {
        find(text, patterns: [#"arXiv:(\d{4}\.\d{4,5})(v\d+)?"#,
                              #"arXiv:([a-z]+(?:-[a-z]+)?(?:\.[A-Z]{2})?/\d{7})(v\d+)?"#])
    }

    /// Every "arXiv:XXXX.XXXXX(vN)" / "arXiv:archive/NNNNNNN" in the text, in order, deduplicated
    /// by base id (the first spelling wins).
    static func findAllInText(_ text: String) -> [String] {
        var out: [String] = []
        let patterns = [#"arXiv\s*:\s*(\d{4}\.\d{4,5})(v\d+)?"#,
                        #"arXiv\s*:\s*([a-z]+(?:-[a-z]+)?(?:\.[A-Z]{2})?/\d{7})(v\d+)?"#,
                        #"arxiv\.org/(?:abs|pdf)/(\d{4}\.\d{4,5})(v\d+)?"#]
        var hits: [(Int, String)] = []
        let range = NSRange(text.startIndex..., in: text)
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { continue }
            for m in re.matches(in: text, range: range) {
                guard let idR = Range(m.range(at: 1), in: text) else { continue }
                var id = String(text[idR])
                if m.range(at: 2).location != NSNotFound, let vR = Range(m.range(at: 2), in: text) { id += text[vR] }
                if !isValid(id) { id = stripVersion(id) }
                if isValid(id) { hits.append((m.range.location, id)) }
            }
        }
        for (_, id) in hits.sorted(by: { $0.0 < $1.0 })
        where !out.contains(where: { stripVersion($0) == stripVersion(id) }) {
            out.append(id)
        }
        return out
    }

    /// arXiv's DataCite DOI "10.48550/arXiv.2401.12345" → "2401.12345".
    static func fromArxivDOI(_ doi: String) -> String? {
        let lower = doi.lowercased()
        guard lower.hasPrefix("10.48550/arxiv.") else { return nil }
        let id = String(doi.dropFirst("10.48550/arxiv.".count))
        return isValid(id) ? id : nil
    }

    private static func find(_ text: String, patterns: [String]) -> String? {
        for p in patterns {
            guard let re = try? NSRegularExpression(pattern: p, options: [.caseInsensitive]) else { continue }
            let r = NSRange(text.startIndex..., in: text)
            if let m = re.firstMatch(in: text, range: r), let idR = Range(m.range(at: 1), in: text) {
                var id = String(text[idR])
                if m.range(at: 2).location != NSNotFound, let vR = Range(m.range(at: 2), in: text) {
                    id += text[vR]
                }
                if isValid(id) { return id }
                if isValid(stripVersion(id)) { return stripVersion(id) }
            }
        }
        return nil
    }
}

enum DOIParser {
    private static let pattern = try! NSRegularExpression(pattern: #"^10\.\d{4,9}/[^\s]+$"#)

    static func normalize(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.lowercased().hasPrefix("doi:") { s = String(s.dropFirst(4)).trimmingCharacters(in: .whitespaces) }
        while let last = s.last, ".,;".contains(last) { s.removeLast() }
        guard s.count <= 300,
              !s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !s.contains("\""), !s.contains("<"), !s.contains(">"),
              pattern.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
        else { return nil }
        return s
    }
}

enum PaperInput: Equatable {
    case arxiv(String)
    case doi(String)

    private static let arxivHosts: Set<String> = [
        "arxiv.org", "www.arxiv.org", "export.arxiv.org", "browse.arxiv.org",
        "ar5iv.labs.arxiv.org", "ar5iv.org", "www.ar5iv.org",
    ]
    private static let doiHosts: Set<String> = ["doi.org", "dx.doi.org", "www.doi.org"]

    static func parse(_ raw: String) -> PaperInput? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty, s.count <= 2048 else { return nil }
        guard !s.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        if s.hasPrefix("<"), s.hasSuffix(">") { s = String(s.dropFirst().dropLast()) }

        // Bare arXiv id, optionally prefixed "arXiv:".
        var bare = s
        if bare.lowercased().hasPrefix("arxiv:") { bare = String(bare.dropFirst(6)).trimmingCharacters(in: .whitespaces) }
        if ArxivID.isValid(bare) { return .arxiv(bare) }

        // Bare DOI.
        if let doi = DOIParser.normalize(s) { return .doi(doi) }

        // URL forms. Accept http(s) input; we only ever fetch over https ourselves.
        var urlString = s
        if !urlString.contains("://") {
            let lower = urlString.lowercased()
            if arxivHosts.contains(where: { lower.hasPrefix($0 + "/") }) || doiHosts.contains(where: { lower.hasPrefix($0 + "/") }) {
                urlString = "https://" + urlString
            }
        }
        guard let comps = URLComponents(string: urlString),
              let scheme = comps.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = comps.host?.lowercased(), comps.user == nil, comps.password == nil
        else { return nil }

        if arxivHosts.contains(host) {
            let path = comps.percentEncodedPath.removingPercentEncoding ?? comps.percentEncodedPath
            let parts = path.split(separator: "/", omittingEmptySubsequences: true)
            guard parts.count >= 2, ["abs", "pdf", "html", "format", "ps"].contains(parts[0].lowercased()) else { return nil }
            let rest = parts.dropFirst().joined(separator: "/")
            guard let id = ArxivID.fromPathRemainder(rest) else { return nil }
            return .arxiv(id)
        }
        if doiHosts.contains(host) {
            var path = comps.percentEncodedPath.removingPercentEncoding ?? comps.percentEncodedPath
            while path.hasPrefix("/") { path.removeFirst() }
            if let doi = DOIParser.normalize(path) { return .doi(doi) }
        }
        return nil
    }
}

// MARK: - Importer

/// Limits how often streaming progress is persisted (the in-memory value updates live).
@MainActor
private final class SaveThrottle {
    private var last = Date.distantPast
    func shouldSave() -> Bool {
        let now = Date()
        guard now.timeIntervalSince(last) >= 2 else { return false }
        last = now
        return true
    }
}

@MainActor
final class Importer: ObservableObject {
    static let shared = Importer()

    /// Paper ids currently queued or running (import lane).
    @Published private(set) var activeIds: Set<UUID> = []

    private struct Job { let id: UUID; let context: ModelContext }

    private var queue: [Job] = []
    private var current: (id: UUID, task: Task<Void, Never>)?
    private var refQueue: [Job] = []
    private var refCurrent: (id: UUID, task: Task<Void, Never>)?
    /// Papers whose title is only the dropped file's name; replaced by real metadata or by
    /// the title found in the converted text.
    private var provisionalTitles: Set<UUID> = []
    /// Papers being reprocessed: identity is re-checked and saved conversions are not reused.
    private var reprocessing: Set<UUID> = []
    /// What a reprocessed paper had before (text kind, status detail): a failed Reprocess
    /// restores it instead of hiding intact text behind "Import failed", and Reprocess never
    /// replaces text with a lower-fidelity kind.
    private var reprocessPrior: [UUID: (kind: ContentKind, detail: String?, identity: IdentitySnapshot)] = [:]

    /// Identity and metadata of a paper before Reprocess: restored when the Reprocess fails,
    /// so the old text is never shown under another paper's id, title and authors.
    struct IdentitySnapshot {
        var arxivId: String?, sourceURL: String?, doi: String?, s2PaperId: String?
        var title: String, authors: [String], year: Int?, abstractText: String
        var weakIdentity: Bool?

        init(_ p: Paper) {
            arxivId = p.arxivId; sourceURL = p.sourceURL; doi = p.doi; s2PaperId = p.s2PaperId
            title = p.title; authors = p.authors; year = p.year; abstractText = p.abstractText
            weakIdentity = p.weakIdentity
        }

        func restore(to p: Paper) {
            p.arxivId = arxivId; p.sourceURL = sourceURL; p.doi = doi; p.s2PaperId = s2PaperId
            p.title = title; p.authors = authors; p.year = year; p.abstractText = abstractText
            p.weakIdentity = weakIdentity
        }
    }

    /// Short user-facing notice (e.g. "Reprocess failed — kept the existing text").
    var onNotice: ((String) -> Void)?

    /// Called when an import turned out to be a paper already in the library (or when a
    /// redundant failed copy is removed): `from` is about to be deleted, `to` is the paper to
    /// show instead; `message` is a short notice for the user (nil for silent clean-up).
    var onRedirect: ((_ from: UUID, _ to: UUID, _ message: String?) -> Void)?

    /// Status detail of a paper whose text came from local PDF extraction (no Claude).
    static let localExtractionDetail = "Plain-text extraction (equations may be garbled). Reprocess to try Claude again."

    private static let placeholderPrefix = "Importing "
    nonisolated private static let maxLocalPDFBytes = HTTP.maxPDFBytes
    private static let maxConvertPDFBytes = ClaudeClient.maxPDFBytes
    private static let maxConvertPages = 600

    private init() {}

    // MARK: Public API

    /// Accepts arXiv ids ("2401.12345", "2401.12345v2", "hep-th/9901001"), arxiv.org abs/pdf/html
    /// URLs, DOIs ("10.xxxx/..."), doi.org URLs. Creates the Paper immediately (state .queued),
    /// returns it, and runs the pipeline in a Task. Throws ImportError.unrecognized on bad input.
    /// If the same paper is already in the library it is returned (and retried if it failed).
    func importLink(_ input: String, context: ModelContext) throws -> Paper {
        guard let parsed = PaperInput.parse(input) else { throw ImportError.unrecognized }

        if let existing = findExisting(parsed, context: context) {
            if existing.importState == .failed { retry(existing, context: context) }
            return existing
        }

        let paper: Paper
        switch parsed {
        case .arxiv(let id):
            paper = Paper(title: "\(Self.placeholderPrefix)arXiv:\(id)",
                          sourceURL: "https://arxiv.org/abs/\(id)")
            paper.arxivId = id
        case .doi(let doi):
            let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi
            paper = Paper(title: "\(Self.placeholderPrefix)\(doi)",
                          sourceURL: "https://doi.org/\(encoded)")
            paper.doi = doi
        }
        paper.importState = .queued
        paper.importStatusDetail = "Waiting…"
        context.insert(paper)
        save(context)
        enqueue(Job(id: paper.id, context: context))
        return paper
    }

    /// Copies the PDF into the store, creates Paper, runs pipeline. The copy (up to 60 MB,
    /// possibly from a slow volume) and its SHA-256 run off the main actor; the Paper is
    /// returned at once. If the same PDF (by hash) is already in the library, the new Paper is
    /// removed again and `onRedirect` moves the selection to the existing one.
    func importPDF(at url: URL, context: ModelContext) -> Paper {
        let name = url.deletingPathExtension().lastPathComponent
        let paper = Paper(title: name.isEmpty ? "Untitled PDF" : name, sourceURL: nil)
        paper.importState = .queued
        paper.importStatusDetail = "Copying PDF…"
        context.insert(paper)
        save(context)
        let id = paper.id
        provisionalTitles.insert(id)
        activeIds.insert(id)

        let dst = PaperStore.pdfURL(id)
        Task { @MainActor [weak self] in
            let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                Result {
                    try Importer.copyPDF(from: url, to: dst)
                    if let digest = PaperStore.sha256(of: dst) {
                        PaperStore.recordPDFHash(id, sha256: digest.hash, size: digest.size)
                    }
                }
            }.value
            guard let self else { return }
            guard let p = self.paper(id, context) else {
                self.activeIds.remove(id)
                self.cleanupOrphanDirectory(id, context)
                return
            }
            switch result {
            case .success:
                p.hasPDF = true
                p.importStatusDetail = "Checking library…"
                self.save(context)
                // Same PDF already in the library → select that paper instead.
                let merged = (try? await self.resolveDuplicates(id, context)) ?? false
                self.activeIds.remove(id)
                guard !merged, let p = self.paper(id, context) else { return }
                p.importStatusDetail = "Waiting…"
                self.save(context)
                self.enqueue(Job(id: id, context: context))
            case .failure(let error):
                self.activeIds.remove(id)
                p.importState = .failed
                p.importStatusDetail = Self.message(for: error)
                self.save(context)
            }
        }
        return paper
    }

    func retry(_ paper: Paper, context: ModelContext) {
        let id = paper.id
        if activeIds.contains(id) { return }

        // Text is fine; only the reference list needs another try.
        if paper.importState == .ready {
            if paper.referencesState == .failed || paper.referencesState == .none {
                enqueueReferences(Job(id: id, context: context))
            }
            return
        }
        guard paper.arxivId != nil || paper.doi != nil || paper.hasPDF else {
            paper.importState = .failed
            paper.importStatusDetail = ImportError.unrecognized.localizedDescription
            save(context)
            return
        }
        markTitleProvisionalIfUnidentified(paper)
        paper.importState = .queued
        paper.importStatusDetail = "Waiting…"
        save(context)
        enqueue(Job(id: id, context: context))
    }

    /// Whether "Reprocess" can run for this paper now.
    func canReprocess(_ paper: Paper) -> Bool {
        !activeIds.contains(paper.id) && (paper.hasPDF || paper.arxivId != nil || paper.doi != nil)
    }

    /// Reruns the whole pipeline for a ready or failed paper: identity is resolved again
    /// (a PDF's own arXiv stamp/metadata wins over a stored id), the clean text is rebuilt and
    /// a PDF conversion is done afresh (a saved conversion is not reused). Notes, highlights,
    /// tags, status and chats are kept; highlights re-anchor by their quote if blocks moved.
    func reprocess(_ paper: Paper, context: ModelContext) {
        guard canReprocess(paper) else { return }
        let id = paper.id
        refQueue.removeAll { $0.id == id }
        if refCurrent?.id == id { refCurrent?.task.cancel() }
        markTitleProvisionalIfUnidentified(paper)
        reprocessing.insert(id)
        if paper.importState == .ready, paper.contentKind != .none, Self.hasContentFiles(id) {
            reprocessPrior[id] = (paper.contentKind, paper.importStatusDetail, IdentitySnapshot(paper))
        } else {
            reprocessPrior[id] = nil
        }
        paper.importState = .queued
        paper.importStatusDetail = "Waiting…"
        save(context)
        enqueue(Job(id: id, context: context))
    }

    /// A paper with no identifier still carries its file name as title: let the pipeline
    /// replace it (the in-memory provisional set does not survive relaunch).
    private func markTitleProvisionalIfUnidentified(_ p: Paper) {
        if p.arxivId == nil, p.doi == nil, p.s2PaperId == nil { provisionalTitles.insert(p.id) }
    }

    /// Stops any queued or running work for a paper (call before deleting it).
    func cancel(_ paperId: UUID) {
        reprocessing.remove(paperId)
        reprocessPrior[paperId] = nil
        queue.removeAll { $0.id == paperId }
        refQueue.removeAll { $0.id == paperId }
        if current?.id == paperId { current?.task.cancel() }
        if refCurrent?.id == paperId { refCurrent?.task.cancel() }
        activeIds.remove(paperId)
    }

    /// Whether the reference list of a ready paper can be fetched again from the UI.
    func canRetryReferences(_ paper: Paper) -> Bool {
        paper.importState == .ready && !activeIds.contains(paper.id)
            && [.failed, .none, .unavailable].contains(paper.referencesState)
            && refCurrent?.id != paper.id && !refQueue.contains(where: { $0.id == paper.id })
    }

    /// Re-runs only the reference step for a ready paper.
    func retryReferences(_ paper: Paper, context: ModelContext) {
        guard canRetryReferences(paper) else { return }
        enqueueReferences(Job(id: paper.id, context: context))
    }

    /// On launch (after `recoverInterrupted`): the reference queue lives in memory, so papers
    /// whose reference step never ran or was interrupted are queued again.
    func resumeReferences(context: ModelContext) {
        let ready = ImportState.ready.rawValue
        let d = FetchDescriptor<Paper>(predicate: #Predicate { $0.importStateRaw == ready },
                                       sortBy: [SortDescriptor(\.addedAt)])
        guard let papers = try? context.fetch(d) else { return }
        for p in papers where p.referencesState == .none || p.referencesState == .failed {
            enqueueReferences(Job(id: p.id, context: context))
        }
    }

    /// Whether a paper's clean text (content.html + blocks.json) is on disk.
    nonisolated static func hasContentFiles(_ id: UUID) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: PaperStore.htmlURL(id).path) && fm.fileExists(atPath: PaperStore.blocksURL(id).path)
    }

    /// On launch: papers left in a busy state by a previous run are marked failed — except
    /// those that already had text (an interrupted Reprocess), which go back to ready.
    @MainActor
    static func recoverInterrupted(context: ModelContext) {
        guard let papers = try? context.fetch(FetchDescriptor<Paper>()) else { return }
        var changed = false
        for p in papers {
            if p.importState.isBusy {
                if p.contentKind != .none, hasContentFiles(p.id) {
                    p.importState = .ready
                    p.importStatusDetail = nil
                } else {
                    p.importState = .failed
                    p.importStatusDetail = "Interrupted — Retry"
                }
                changed = true
            }
            if p.referencesState == .fetching {
                p.referencesState = .failed
                changed = true
            }
        }
        if changed { try? context.save() }
    }

    // MARK: Queues

    private func enqueue(_ job: Job) {
        guard !activeIds.contains(job.id) else { return }
        activeIds.insert(job.id)
        queue.append(job)
        pump()
    }

    private func pump() {
        guard current == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.run(job)
            self.current = nil
            self.activeIds.remove(job.id)
            self.pump()
        }
        current = (job.id, task)
    }

    private func enqueueReferences(_ job: Job) {
        guard !refQueue.contains(where: { $0.id == job.id }), refCurrent?.id != job.id else { return }
        refQueue.append(job)
        pumpReferences()
    }

    private func pumpReferences() {
        guard refCurrent == nil, !refQueue.isEmpty else { return }
        let job = refQueue.removeFirst()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runReferences(job)
            self.refCurrent = nil
            self.pumpReferences()
        }
        refCurrent = (job.id, task)
    }

    // MARK: Pipeline

    private func run(_ job: Job) async {
        let ctx = job.context
        defer {
            reprocessing.remove(job.id)
            reprocessPrior[job.id] = nil
        }
        do {
            try await pipeline(job.id, ctx)
            if paper(job.id, ctx) != nil { enqueueReferences(job) }
        } catch ImportError.merged {
            // The paper was a duplicate and has been removed in favour of the existing one.
            return
        } catch {
            guard let p = paper(job.id, ctx) else {
                cleanupOrphanDirectory(job.id, ctx)
                return
            }
            // The paper still has its earlier text (a failed or cancelled Reprocess): keep it
            // readable and say why nothing changed.
            if p.contentKind != .none, Self.hasContentFiles(job.id) {
                let prior = reprocessPrior[job.id]
                prior?.identity.restore(to: p)
                if prior != nil { provisionalTitles.remove(job.id) }
                p.importState = .ready
                p.importStatusDetail = prior?.detail
                save(ctx)
                if !(error is CancellationError || Task.isCancelled) {
                    let why = Self.message(for: error)
                    if case ImportError.wouldDowngrade = error {
                        onNotice?(why)
                    } else {
                        onNotice?("Reprocess failed — the existing text was kept. " + why)
                    }
                }
                return
            }
            p.importState = .failed
            if error is CancellationError || Task.isCancelled {
                p.importStatusDetail = "Cancelled — Retry"
            } else {
                p.importStatusDetail = Self.message(for: error)
            }
            save(ctx)
        }
    }

    private func pipeline(_ id: UUID, _ ctx: ModelContext) async throws {
        var p = try require(id, ctx)
        var arxivId = p.arxivId
        var meta: S2Paper?
        var arxivEntry: ArxivEntry?
        var hints: PDFIdentityHints?
        let isReprocess = reprocessing.contains(id)

        // 1. Resolve.
        if arxivId == nil, let doi = p.doi {
            try update(id, ctx, .fetching, "Looking up DOI…")
            do {
                meta = try await ScholarAPI.paper(ScholarAPI.doiID(doi))
            } catch ScholarError.notFound {
                if !p.hasPDF { throw ImportError.noOpenAccessPDF }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Without a local PDF there is nothing else to go on.
                if try require(id, ctx).hasPDF == false { throw error }
            }
            p = try require(id, ctx)
            if let m = meta { apply(m, to: p) }
            if let ax = meta?.externalIds?.arXiv?.trimmingCharacters(in: .whitespaces), ArxivID.isValid(ax) {
                arxivId = ax
                p.arxivId = ax
                save(ctx)
            } else if let ax = ArxivID.fromArxivDOI(doi) {
                arxivId = ax
                p.arxivId = ax
                save(ctx)
            } else if !p.hasPDF {
                guard let pdfURL = meta?.openAccessPDFURL else { throw ImportError.noOpenAccessPDF }
                try update(id, ctx, .fetching, "Downloading PDF…")
                let data = try await downloadPDF(pdfURL)
                try await writePDF(data, id, ctx)
            }
            if try await resolveDuplicates(id, ctx) { throw ImportError.merged }
        } else if arxivId == nil, p.hasPDF {
            // A dropped PDF: identify it before paying for a conversion.
            let found = try await identifyPDF(id, ctx)
            hints = found.hints
            p = try require(id, ctx)
            if let r = found.resolution {
                if let m = r.s2 { apply(m, to: p); meta = m }
                if r.s2?.cleanTitle == nil, let e = r.arxiv { apply(e, to: p) }
                arxivEntry = r.arxiv
                if p.doi == nil, let d = r.doi.flatMap(DOIParser.normalize) { p.doi = d }
                if let ax = r.arxivId {
                    arxivId = ax
                    p.arxivId = ax
                    p.sourceURL = "https://arxiv.org/abs/\(ax)"
                }
                // Only the PDF's own stamp/metadata is strong enough to fold it into an
                // existing paper; a mention or a title search may be a different document.
                // Persisted, so a later Retry/Reprocess cannot merge on it either.
                p.weakIdentity = r.isStrong ? nil : true
            }
            if let h = hints { applyPDFHints(h, to: p) }
            save(ctx)
            if try await resolveDuplicates(id, ctx) { throw ImportError.merged }
        } else if isReprocess, arxivId != nil, p.hasPDF {
            // Re-check a stored id against the PDF's own trusted arXiv id (metadata / stamp).
            try update(id, ctx, .fetching, "Reading PDF…")
            let localPDF = PaperStore.pdfURL(id)
            let h = await Task.detached(priority: .userInitiated) {
                PDFIdentity.hints(for: localPDF, fileStem: nil)
            }.value
            hints = h
            if h.stampArxiv != nil {
                // The PDF's own stamp is strong evidence.
                p = try require(id, ctx)
                p.weakIdentity = nil
            }
            if let stamp = h.stampArxiv, let current = arxivId,
               ArxivID.stripVersion(stamp) != ArxivID.stripVersion(current) {
                p = try require(id, ctx)
                arxivId = stamp
                p.arxivId = stamp
                p.sourceURL = "https://arxiv.org/abs/\(stamp)"
                save(ctx)
                if try await resolveDuplicates(id, ctx) { throw ImportError.merged }
            }
        }

        if let arxivId {
            try await arxivPath(id, arxivId, meta, arxivEntry, hints, ctx)
        } else {
            try await pdfPath(id, ctx, hints: hints)
        }
    }

    /// Reads the PDF's identity hints off the main actor and resolves them over the network.
    private func identifyPDF(_ id: UUID, _ ctx: ModelContext) async throws
        -> (hints: PDFIdentityHints, resolution: PDFIdentityResolution?) {
        try update(id, ctx, .fetching, "Reading PDF…")
        let localPDF = PaperStore.pdfURL(id)
        let stem = provisionalTitles.contains(id) ? try require(id, ctx).title : nil
        let hints = await Task.detached(priority: .userInitiated) {
            PDFIdentity.hints(for: localPDF, fileStem: stem)
        }.value
        try Task.checkCancellation()
        guard hints.readable else { throw ImportError.unreadableFile }
        try update(id, ctx, .fetching, "Identifying paper…")
        let resolution = try await PDFIdentityResolver.resolve(hints) { [weak self] detail in
            await MainActor.run {
                guard let self, let p = self.paper(id, ctx), p.importState == .fetching else { return }
                p.importStatusDetail = detail
                self.save(ctx)
            }
        }
        try Task.checkCancellation()
        return (hints, resolution)
    }

    /// Title/authors from the PDF itself, for papers no metadata service recognised. Replaces
    /// only a provisional (file-name) title.
    private func applyPDFHints(_ h: PDFIdentityHints, to p: Paper) {
        if provisionalTitles.contains(p.id) || isPlaceholderTitle(p), let t = h.titleGuess {
            p.title = Self.clean(t, max: 500)
            provisionalTitles.remove(p.id)
        }
        if p.authors.isEmpty, !h.metadataAuthors.isEmpty {
            p.authors = h.metadataAuthors.prefix(200).map { Self.clean($0, max: 200) }
        }
    }

    // 2. arXiv path.
    private func arxivPath(_ id: UUID, _ arxivId: String, _ known: S2Paper?, _ knownEntry: ArxivEntry?,
                           _ hints: PDFIdentityHints?, _ ctx: ModelContext) async throws {
        var meta = known
        if meta == nil {
            try update(id, ctx, .fetching, "Fetching metadata…")
            meta = try? await ScholarAPI.paper(ScholarAPI.arxivID(arxivId))
            try Task.checkCancellation()
            if let m = meta {
                apply(m, to: try require(id, ctx))
                save(ctx)
            } else {
                // Semantic Scholar unavailable (rate limit, not indexed yet): use arXiv's own
                // metadata so the title is never the file name.
                var entry = knownEntry
                if entry == nil { entry = try? await ArxivAPI.entry(id: arxivId) }
                try Task.checkCancellation()
                if let e = entry {
                    apply(e, to: try require(id, ctx))
                    save(ctx)
                }
            }
            if try await resolveDuplicates(id, ctx) { throw ImportError.merged }
        }

        try update(id, ctx, .fetching, "Fetching arXiv text…")
        // Reprocess of a paper that already has arXiv HTML text: anything the PDF route could
        // produce is worse, so a failed HTML fetch/ingest keeps the existing text.
        let keepHTML = reprocessing.contains(id) && reprocessPrior[id]?.kind == .arxivHTML
        let fetched: (String, URL)?
        do {
            fetched = try await fetchArxivHTML(arxivId)
        } catch ImportError.arxivUnreachable {
            // Offline / timeout / 429 / 5xx is not "this paper has no HTML": never downgrade
            // existing text because of it. A new import still falls back to the PDF.
            if reprocessPrior[id] != nil { throw ImportError.arxivUnreachable }
            fetched = nil
        }
        if let (html, finalURL) = fetched {
            try update(id, ctx, .converting, "Preparing clean text…")
            let result: IngestResult?
            do {
                result = try await WebProcessor.shared.ingestArxivHTML(html, baseURL: finalURL)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The HTML route failed (timeout, script error, crashed web process): the PDF
                // route below can still produce readable text, so fall through to it.
                try Task.checkCancellation()
                result = nil
            }
            if let result {
                try await finish(id, ctx, result, kind: .arxivHTML)

                // Keep a copy of the PDF for the PDF view (non-fatal). A dropped PDF is kept.
                if let p = paper(id, ctx), !p.hasPDF {
                    if let url = URL(string: "https://arxiv.org/pdf/\(arxivId)"),
                       let data = try? await downloadPDF(url) {
                        try? await writePDF(data, id, ctx)
                    }
                    try Task.checkCancellation()
                }
                return
            }
        }

        if keepHTML {
            throw ImportError.wouldDowngrade("arXiv's HTML text for this paper couldn't be processed.")
        }

        // No usable LaTeXML HTML: fall back to the PDF.
        if try require(id, ctx).hasPDF == false {
            try update(id, ctx, .fetching, "Downloading PDF…")
            guard let url = URL(string: "https://arxiv.org/pdf/\(arxivId)") else { throw ImportError.missingPDF }
            let data = try await downloadPDF(url)
            try await writePDF(data, id, ctx)
        }
        try await pdfPath(id, ctx, hints: hints)
    }

    /// arxiv.org/html first, then ar5iv. Valid only if the page is LaTeXML output.
    private func fetchArxivHTML(_ arxivId: String) async throws -> (String, URL)? {
        let candidates = ["https://arxiv.org/html/\(arxivId)",
                          "https://ar5iv.labs.arxiv.org/html/\(arxivId)"]
        // Set when a candidate could not answer (transport error, 408/429/5xx) rather than
        // answering "no LaTeXML HTML here".
        var transient = false
        for c in candidates {
            try Task.checkCancellation()
            guard let url = URL(string: c) else { continue }
            do {
                // HTTP.get throws HTTPError.status for every non-2xx answer.
                let (data, response) = try await HTTP.get(url, maxBytes: HTTP.maxHTMLBytes,
                                                          headers: ["Accept": "text/html"])
                let finalURL = response.url ?? url
                guard HTTP.isAllowed(finalURL) else { continue }
                // Decoding and scanning up to 25 MB stays off the main actor.
                let html: String? = await Task.detached(priority: .userInitiated) {
                    let s = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
                    return s.contains("ltx_document") ? s : nil
                }.value
                guard let html else { continue }
                return (html, finalURL)
            } catch is CancellationError {
                throw CancellationError()
            } catch let e as HTTPError {
                switch e {
                case .status(let code, _):
                    // 404/410 and other 4xx: this host has no HTML for the paper.
                    if [408, 425, 429].contains(code) || code >= 500 { transient = true }
                case .invalidResponse:
                    transient = true
                case .insecureURL, .insecureRedirect, .tooLarge:
                    break   // a definite answer: nothing usable here
                }
                continue
            } catch {
                // Transport failure (offline, timeout, DNS, TLS).
                transient = true
                continue
            }
        }
        if transient { throw ImportError.arxivUnreachable }
        return nil
    }

    // 3. PDF path: Claude conversion, else local extraction.
    private func pdfPath(_ id: UUID, _ ctx: ModelContext, hints: PDFIdentityHints?) async throws {
        let p = try require(id, ctx)
        if reprocessing.contains(id), reprocessPrior[id]?.kind == .arxivHTML {
            throw ImportError.wouldDowngrade(nil)
        }
        guard p.hasPDF else { throw ImportError.missingPDF }

        try update(id, ctx, .converting, "Checking PDF…")
        let pdfFile = PaperStore.pdfURL(id)
        let maxBytes = Self.maxConvertPDFBytes
        let maxPages = Self.maxConvertPages
        // Validate and hash the file; the bytes are only loaded when Claude can take them.
        let (data, size, pageCount, pdfHash): (Data?, Int, Int, String) = try await Task.detached(priority: .userInitiated) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: pdfFile.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0 else { throw ImportError.missingPDF }
            guard let handle = try? FileHandle(forReadingFrom: pdfFile) else { throw ImportError.unreadableFile }
            let head = (try? handle.read(upToCount: 1024)) ?? Data()
            try? handle.close()
            guard Importer.looksLikePDF(head) else { throw ImportError.notAPDF }
            guard let doc = PDFDocument(url: pdfFile) else { throw ImportError.unreadableFile }
            let d: Data? = size <= maxBytes && doc.pageCount <= maxPages ? try Data(contentsOf: pdfFile) : nil
            let hash = d.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
                ?? PaperStore.sha256(of: pdfFile)?.hash ?? ""
            return (d, size, doc.pageCount, hash)
        }.value

        // A conversion already paid for this exact PDF (e.g. a later step failed, or the app quit
        // while preparing text) is reused instead of converting again — except on Reprocess.
        let fresh = reprocessing.contains(id)
        var saved: (markdown: String, isComplete: Bool)?
        if !pdfHash.isEmpty {
            saved = await Task.detached(priority: .userInitiated) {
                PaperStore.readSavedConversion(id, pdfSize: size, pdfSHA256: pdfHash)
            }.value
        }
        try Task.checkCancellation()

        var converted: (markdown: String, isComplete: Bool)? = fresh ? nil : saved
        var claudeProblem: String?
        if converted == nil {
            if AppSettings.shared.effectiveAPIKey == nil {
                claudeProblem = "No Anthropic API key is set, so Claude could not convert the PDF."
            } else if size > maxBytes {
                claudeProblem = "The PDF is larger than \(HTTP.formatBytes(maxBytes)), the most Claude can take."
            } else if pageCount > maxPages {
                claudeProblem = "The PDF has \(pageCount) pages; Claude converts at most \(maxPages)."
            } else if let data {
                do {
                    converted = try await convert(id, ctx, data: data, pageCount: pageCount, pdfHash: pdfHash)
                } catch is CancellationError {
                    throw CancellationError()
                } catch ImportError.paperRemoved {
                    throw ImportError.paperRemoved
                } catch {
                    try Task.checkCancellation()
                    claudeProblem = Self.conversionProblem(error)
                }
            }
        }

        // Reprocess asked Claude again and it failed: keep the earlier Claude conversion rather
        // than dropping to plain-text extraction.
        if converted == nil, fresh, let saved { converted = saved }

        if let converted {
            try update(id, ctx, .converting, "Preparing clean text…")
            let result = try await WebProcessor.shared.ingestMarkdown(converted.markdown)
            try await finish(id, ctx, result, kind: .claudeMarkdown)
            if !converted.isComplete, let p = paper(id, ctx) {
                p.importStatusDetail = "Text incomplete — the PDF was too long to convert in one pass."
                save(ctx)
            }
            return
        }
        try await localExtraction(id, ctx, hints: hints, problem: claudeProblem)
    }

    /// Offline fallback: PDFKit text → simple Markdown → the normal Markdown ingest.
    private func localExtraction(_ id: UUID, _ ctx: ModelContext, hints: PDFIdentityHints?,
                                 problem: String?) async throws {
        // Reprocess of a paper with better text (arXiv HTML or a Claude conversion): plain
        // PDFKit text would replace it with garbled equations. Keep what is there.
        if reprocessing.contains(id), let prior = reprocessPrior[id],
           prior.kind == .arxivHTML || prior.detail != Self.localExtractionDetail {
            throw ImportError.wouldDowngrade(problem)
        }
        try update(id, ctx, .converting, "Extracting text from the PDF…")
        let p = try require(id, ctx)
        let knownTitle = provisionalTitles.contains(id) || isPlaceholderTitle(p) ? hints?.titleGuess : p.title
        var note = "**Plain-text extraction.** "
        if let problem { note += PDFTextExtractor.escapeInline(problem) + " " }
        note += "This text was extracted from the PDF without Claude, so equations, tables and " +
                "symbols may be garbled — the PDF view shows the original. Use Paper ▸ Reprocess to try Claude again."
        let pdfFile = PaperStore.pdfURL(id)
        let noteText = note
        let output = await Task.detached(priority: .userInitiated) {
            PDFTextExtractor.markdown(from: pdfFile, title: knownTitle, note: noteText)
        }.value
        try Task.checkCancellation()
        guard let output, output.textCharacters >= 200 else {
            throw ImportError.noExtractableText(problem)
        }
        try update(id, ctx, .converting, "Preparing clean text…")
        let result = try await WebProcessor.shared.ingestMarkdown(output.markdown)
        try await finish(id, ctx, result, kind: .claudeMarkdown)
        if let p = paper(id, ctx) {
            p.importStatusDetail = Self.localExtractionDetail
            save(ctx)
        }
    }

    /// Why Claude could not convert, in import wording (never the chat's).
    private static func conversionProblem(_ error: Error) -> String {
        if let e = error as? ClaudeError, e.isRefusal {
            var s = "Claude declined to convert this PDF"
            if let c = e.refusalCategory, !c.isEmpty { s += " (refusal category: \(c))" }
            return s + "."
        }
        if let e = error as? ImportError {
            switch e {
            case .emptyConversion, .conversionTooLong: return "Claude's conversion produced no text."
            default: break
            }
        }
        return "Claude could not convert the PDF: " + message(for: error)
    }

    /// Runs the paid Claude conversion and saves source.md + its sidecar for reuse on retry.
    private func convert(_ id: UUID, _ ctx: ModelContext, data: Data, pageCount: Int,
                         pdfHash: String) async throws -> (String, Bool) {
        try update(id, ctx, .converting, "Converting PDF with Claude…")
        let throttle = SaveThrottle()
        let conversion = try await ClaudeClient().convertPDF(pdfData: data, pageCount: pageCount) { [weak self] progress in
            guard let self, let p = self.paper(id, ctx), p.importState == .converting else { return }
            p.importStatusDetail = "Converting PDF with Claude… \(progress.formatted()) characters"
            if throttle.shouldSave() { self.save(ctx) }
        }
        try Task.checkCancellation()
        var md = conversion.markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !md.isEmpty else {
            throw conversion.isComplete ? ImportError.emptyConversion : ImportError.conversionTooLong
        }
        if !conversion.isComplete {
            // Keep what was paid for, but never present it as the whole paper: the marker is a
            // visible block in the reader and part of the chat's paper text.
            md += "\n\n> **Conversion incomplete.** Claude stopped before the end of the PDF " +
                  "(the paper is too long to convert in one pass). Everything after this point " +
                  "— later sections, appendices and references — is missing from this text; " +
                  "use the PDF view for it.\n"
        }

        _ = try require(id, ctx)
        let mdCopy = md
        let info = PaperStore.SourceConversionInfo(pdfSize: data.count, pdfSHA256: pdfHash,
                                                   isComplete: conversion.isComplete)
        try await Task.detached(priority: .userInitiated) {
            try PaperStore.writeSavedConversion(id, markdown: mdCopy, info: info)
        }.value
        return (md, conversion.isComplete)
    }

    // 4. Save content → ready.
    private func finish(_ id: UUID, _ ctx: ModelContext, _ result: IngestResult, kind: ContentKind) async throws {
        try Task.checkCancellation()
        try update(id, ctx, .indexing, "Saving…")
        // Writing content.html / encoding blocks.json can be many MB: keep it off main.
        try await Task.detached(priority: .userInitiated) {
            try PaperStore.writeContent(result, for: id)
        }.value
        let p = try require(id, ctx)

        let titleIsProvisional = isPlaceholderTitle(p) || provisionalTitles.contains(id)
            || (p.arxivId == nil && p.doi == nil && p.s2PaperId == nil && p.contentKind == .none)
        if titleIsProvisional, !result.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            p.title = Self.clean(result.title, max: 500)
            provisionalTitles.remove(id)
        }
        if p.authors.isEmpty, !result.authors.isEmpty {
            p.authors = result.authors.map { Self.clean($0, max: 200) }.filter { !$0.isEmpty }.prefix(200).map { $0 }
        }
        if p.abstractText.isEmpty, !result.abstract.isEmpty {
            p.abstractText = Self.clean(result.abstract, max: 20_000)
        }
        p.contentKind = kind
        p.importState = .ready
        p.importStatusDetail = nil
        if isPlaceholderTitle(p) {
            p.title = p.arxivId.map { "arXiv:\($0)" } ?? p.doi ?? "Untitled paper"
        }
        save(ctx)
    }

    // 5. References.
    private func runReferences(_ job: Job) async {
        let id = job.id, ctx = job.context
        guard let p = paper(id, ctx) else { return }
        p.referencesState = .fetching
        save(ctx)

        do {
            let state = try await fetchReferences(id, ctx)
            guard let p = paper(id, ctx) else { return }
            p.referencesState = state
            save(ctx)
        } catch {
            guard let p = paper(id, ctx) else { return }
            p.referencesState = .failed
            save(ctx)
        }
    }

    private func fetchReferences(_ id: UUID, _ ctx: ModelContext) async throws -> ReferencesState {
        var p = try require(id, ctx)
        var identifier: String?
        if let s2 = p.s2PaperId, !s2.isEmpty { identifier = s2 }
        else if let ax = p.arxivId { identifier = ScholarAPI.arxivID(ax) }
        else if let doi = p.doi { identifier = ScholarAPI.doiID(doi) }
        else if !isPlaceholderTitle(p), !provisionalTitles.contains(id),
                let m = try await ScholarAPI.match(title: p.title), let pid = m.paperId,
                let matched = m.title, Self.titlesMatch(p.title, matched) {
            // Only accept the search hit when its title really is this paper's title;
            // otherwise an unrelated paper's references would be injected into chat.
            p = try require(id, ctx)
            p.s2PaperId = pid
            save(ctx)
            identifier = pid
        }
        guard let identifier else { return .unavailable }

        let cited: [S2Paper]
        do {
            cited = try await ScholarAPI.references(of: identifier)
        } catch ScholarError.notFound {
            return .unavailable
        }
        try Task.checkCancellation()

        // Build rows as plain values; embed off the main actor; insert on main.
        struct Row { let title: String; let authors: [String]; let year: Int?; let arxiv: String?
                     let doi: String?; let s2: String?; let abstract: String?; let pdf: String? }
        let rows: [Row] = cited.compactMap { c in
            guard let t = c.cleanTitle else { return nil }
            return Row(title: Self.clean(t, max: 500),
                       authors: Array(c.authorNames.prefix(50)),
                       year: c.year,
                       arxiv: c.externalIds?.arXiv,
                       doi: c.externalIds?.doi,
                       s2: c.paperId,
                       abstract: c.cleanAbstract.map { Self.clean($0, max: 20_000) },
                       pdf: c.openAccessPDFURL?.absoluteString)
        }
        guard !rows.isEmpty else {
            try replaceReferences(id, ctx, entries: [], chunks: [])
            return .unavailable
        }

        var entries: [ReferenceEntry] = []
        var toEmbed: [(entryIndex: Int, text: String)] = []
        for (i, r) in rows.enumerated() {
            let e = ReferenceEntry(paperId: id, ordinal: i + 1, title: r.title)
            e.authors = r.authors
            e.year = r.year
            e.arxivId = r.arxiv
            e.doi = r.doi
            e.s2PaperId = r.s2
            e.abstractText = r.abstract
            e.openAccessPDF = r.pdf
            entries.append(e)
            if let a = r.abstract, !a.isEmpty { toEmbed.append((i, "\(r.title). \(a)")) }
        }

        let vectors = await Embedder.embedBatch(toEmbed.map(\.text))
        try Task.checkCancellation()

        var chunks: [RefChunk] = []
        for (k, item) in toEmbed.enumerated() {
            let e = entries[item.entryIndex]
            chunks.append(RefChunk(paperId: id, referenceId: e.id, label: e.label,
                                   text: item.text, embedding: k < vectors.count ? vectors[k] : Data()))
        }
        try replaceReferences(id, ctx, entries: entries, chunks: chunks)
        return .ready
    }

    private func replaceReferences(_ id: UUID, _ ctx: ModelContext, entries: [ReferenceEntry], chunks: [RefChunk]) throws {
        _ = try require(id, ctx)
        let pid = id
        try ctx.delete(model: RefChunk.self, where: #Predicate { $0.paperId == pid })
        try ctx.delete(model: ReferenceEntry.self, where: #Predicate { $0.paperId == pid })
        for e in entries { ctx.insert(e) }
        for c in chunks { ctx.insert(c) }
        save(ctx)
    }

    // MARK: Helpers — state

    private func paper(_ id: UUID, _ ctx: ModelContext) -> Paper? {
        var d = FetchDescriptor<Paper>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        guard let p = try? ctx.fetch(d).first, !p.isDeleted else { return nil }
        return p
    }

    private func require(_ id: UUID, _ ctx: ModelContext) throws -> Paper {
        try Task.checkCancellation()
        guard let p = paper(id, ctx) else { throw ImportError.paperRemoved }
        return p
    }

    private func update(_ id: UUID, _ ctx: ModelContext, _ state: ImportState, _ detail: String) throws {
        let p = try require(id, ctx)
        p.importState = state
        p.importStatusDetail = detail
        save(ctx)
    }

    private func save(_ ctx: ModelContext) {
        do { try ctx.save() } catch {
            NSLog("Paperreads: failed to save import state: %@", error.localizedDescription)
        }
    }

    private func apply(_ m: S2Paper, to p: Paper) {
        if let t = m.cleanTitle {
            p.title = Self.clean(t, max: 500)
            provisionalTitles.remove(p.id)
        }
        let names = m.authorNames
        if !names.isEmpty { p.authors = Array(names.prefix(200)).map { Self.clean($0, max: 200) } }
        if let y = m.year, (1600...2200).contains(y) { p.year = y }
        if let a = m.cleanAbstract { p.abstractText = Self.clean(a, max: 20_000) }
        if let s2 = m.paperId, !s2.isEmpty { p.s2PaperId = s2 }
        if p.doi == nil, let doi = m.externalIds?.doi, let n = DOIParser.normalize(doi) { p.doi = n }
    }

    private func apply(_ e: ArxivEntry, to p: Paper) {
        let t = e.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty {
            p.title = Self.clean(t, max: 500)
            provisionalTitles.remove(p.id)
        }
        if !e.authors.isEmpty { p.authors = Array(e.authors.prefix(200)).map { Self.clean($0, max: 200) } }
        if let y = e.year { p.year = y }
        if p.abstractText.isEmpty, !e.summary.isEmpty { p.abstractText = Self.clean(e.summary, max: 20_000) }
        if p.doi == nil, let d = e.doi { p.doi = d }
    }

    // MARK: Helpers — duplicates

    /// Notes, tags, a reading status, highlights or a chat: things a merge must never discard.
    private func hasUserData(_ p: Paper, _ ctx: ModelContext) -> Bool {
        if !p.paperNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !p.tags.isEmpty
            || p.status != .toRead { return true }
        let pid = p.id
        let highlights = (try? ctx.fetchCount(FetchDescriptor<Highlight>(predicate: #Predicate { $0.paperId == pid }))) ?? 0
        if highlights > 0 { return true }
        let turns = (try? ctx.fetchCount(FetchDescriptor<ChatTurn>(predicate: #Predicate { $0.paperId == pid }))) ?? 0
        return turns > 0
    }

    /// Other papers that are the same work: same arXiv id (any version), same DOI, or the
    /// byte-identical PDF (SHA-256, cached in a sidecar next to each original.pdf).
    private func duplicates(of id: UUID, _ ctx: ModelContext) async throws -> [Paper] {
        let p = try require(id, ctx)
        let weak = p.weakIdentity == true
        let base = weak ? nil : p.arxivId.map(ArxivID.stripVersion)
        let doi = weak ? nil : p.doi?.lowercased()
        let others = ((try? ctx.fetch(FetchDescriptor<Paper>())) ?? []).filter { $0.id != id && !$0.isDeleted }
        var found: [UUID] = others.filter { o in
            if let base, let a = o.arxivId, ArxivID.stripVersion(a) == base { return true }
            if let doi, let d = o.doi, d.lowercased() == doi { return true }
            return false
        }.map(\.id)
        if p.hasPDF {
            let candidates = others.filter { $0.hasPDF && !found.contains($0.id) }.map(\.id)
            if !candidates.isEmpty {
                let matches: [UUID] = await Task.detached(priority: .userInitiated) {
                    guard let mine = PaperStore.pdfSHA256(id) else { return [] }
                    return candidates.filter { PaperStore.pdfSHA256($0) == mine }
                }.value
                found += matches
            }
        }
        try Task.checkCancellation()
        return found.compactMap { paper($0, ctx) }
    }

    /// Folds duplicates together. If an existing copy is worth keeping (it has text, user data,
    /// or work in flight) and this paper has nothing of its own yet, this paper is removed and
    /// the selection redirected (returns true). Redundant failed copies with nothing in them
    /// are removed in favour of this one. Papers holding user data are never deleted.
    private func resolveDuplicates(_ id: UUID, _ ctx: ModelContext) async throws -> Bool {
        let dups = try await duplicates(of: id, ctx)
        guard !dups.isEmpty else { return false }
        let p = try require(id, ctx)
        let mergeable = p.contentKind == .none && !hasUserData(p, ctx)
        let keepers = dups.filter {
            $0.contentKind != .none || $0.importState == .ready || hasUserData($0, ctx) || activeIds.contains($0.id)
        }
        if !keepers.isEmpty {
            guard mergeable else { return false }
            // Prefer a paper with text, then user data, then the oldest.
            let keep = keepers.sorted { a, b in
                let ra = (a.importState == .ready ? 2 : 0) + (hasUserData(a, ctx) ? 1 : 0)
                let rb = (b.importState == .ready ? 2 : 0) + (hasUserData(b, ctx) ? 1 : 0)
                return ra != rb ? ra > rb : a.addedAt < b.addedAt
            }[0]
            return await merge(p, into: keep, ctx)
        }
        for d in dups {
            let did = d.id
            onRedirect?(did, id, nil)
            queue.removeAll { $0.id == did }
            refQueue.removeAll { $0.id == did }
            provisionalTitles.remove(did)
            PaperStore.delete(d, in: ctx)
        }
        return false
    }

    /// Removes `p` (a fresh duplicate with no user data) in favour of `keep`, handing over its
    /// PDF and identifiers when `keep` lacks them, and retrying `keep` if it had failed.
    /// Returns false (and leaves `p` intact) if `keep` vanished meanwhile.
    private func merge(_ p: Paper, into keep: Paper, _ ctx: ModelContext) async -> Bool {
        let from = p.id, to = keep.id
        if p.hasPDF, !keep.hasPDF {
            let src = PaperStore.pdfURL(from), dst = PaperStore.pdfURL(to)
            let moved: Bool = await Task.detached(priority: .utility) {
                do {
                    if FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.removeItem(at: dst) }
                    try FileManager.default.moveItem(at: src, to: dst)
                    if let digest = PaperStore.sha256(of: dst) {
                        PaperStore.recordPDFHash(to, sha256: digest.hash, size: digest.size)
                    }
                    return true
                } catch {
                    return false
                }
            }.value
            if moved {
                if let k = paper(to, ctx) {
                    k.hasPDF = true
                } else {
                    // `keep` was deleted during the move: give the PDF back to `p`.
                    let back: Bool = await Task.detached(priority: .utility) {
                        guard !FileManager.default.fileExists(atPath: src.path) else { return true }
                        try? FileManager.default.createDirectory(at: src.deletingLastPathComponent(),
                                                                 withIntermediateDirectories: true)
                        return (try? FileManager.default.moveItem(at: dst, to: src)) != nil
                    }.value
                    if !back, let me = paper(from, ctx) { me.hasPDF = false; save(ctx) }
                }
            }
        }
        guard let keep = paper(to, ctx), let p = paper(from, ctx) else { return false }
        if keep.arxivId == nil, let a = p.arxivId { keep.arxivId = a }
        if keep.doi == nil, let d = p.doi { keep.doi = d }
        onRedirect?(from, to, "This paper is already in your library.")
        queue.removeAll { $0.id == from }
        refQueue.removeAll { $0.id == from }
        provisionalTitles.remove(from)
        reprocessing.remove(from)
        PaperStore.delete(p, in: ctx)
        save(ctx)
        if keep.importState == .failed, !activeIds.contains(to) { retry(keep, context: ctx) }
        return true
    }

    private func isPlaceholderTitle(_ p: Paper) -> Bool {
        p.title.hasPrefix(Self.placeholderPrefix) || p.title.isEmpty
    }

    private func findExisting(_ input: PaperInput, context: ModelContext) -> Paper? {
        switch input {
        case .arxiv(let id):
            let base = ArxivID.stripVersion(id)
            let all = (try? context.fetch(FetchDescriptor<Paper>(predicate: #Predicate { $0.arxivId != nil }))) ?? []
            return all.first { p in
                guard let a = p.arxivId else { return false }
                // Same paper if the base ids match and neither side pins a different version.
                return ArxivID.stripVersion(a) == base && (a == id || a == base || id == base)
            }
        case .doi(let doi):
            let lower = doi.lowercased()
            let all = (try? context.fetch(FetchDescriptor<Paper>(predicate: #Predicate { $0.doi != nil }))) ?? []
            return all.first { $0.doi?.lowercased() == lower }
        }
    }

    private func cleanupOrphanDirectory(_ id: UUID, _ ctx: ModelContext) {
        guard paper(id, ctx) == nil else { return }
        let dir = PaperStore.appSupport.appendingPathComponent("papers", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    static func message(for error: Error) -> String {
        if let e = error as? LocalizedError, let d = e.errorDescription { return d }
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost: return "You appear to be offline."
            case .timedOut: return "The request timed out."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed: return "Couldn't reach the server."
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
                return "A secure connection couldn't be established."
            default: break
            }
        }
        return error.localizedDescription
    }

    nonisolated static func clean(_ s: String, max: Int) -> String {
        let collapsed = s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(collapsed.prefix(max))
    }

    // MARK: Helpers — files

    private func downloadPDF(_ url: URL) async throws -> Data {
        let (data, _) = try await HTTP.get(url, maxBytes: HTTP.maxPDFBytes,
                                           headers: ["Accept": "application/pdf"])
        guard Self.looksLikePDF(data) else { throw ImportError.notAPDF }
        return data
    }

    private func writePDF(_ data: Data, _ id: UUID, _ ctx: ModelContext) async throws {
        _ = try require(id, ctx)
        let dst = PaperStore.pdfURL(id)
        try await Task.detached(priority: .utility) {
            try data.write(to: dst, options: .atomic)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            PaperStore.recordPDFHash(id, sha256: hash, size: data.count)
        }.value
        let p = try require(id, ctx)
        p.hasPDF = true
        save(ctx)
    }

    nonisolated private static func copyPDF(from src: URL, to dst: URL) throws {
        guard src.isFileURL else { throw ImportError.unreadableFile }
        let scoped = src.startAccessingSecurityScopedResource()
        defer { if scoped { src.stopAccessingSecurityScopedResource() } }

        let values = try? src.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values?.isRegularFile == true else { throw ImportError.unreadableFile }
        let size = values?.fileSize ?? 0
        guard size > 0 else { throw ImportError.unreadableFile }
        guard size <= Self.maxLocalPDFBytes else { throw ImportError.fileTooLarge(Self.maxLocalPDFBytes) }

        guard let handle = try? FileHandle(forReadingFrom: src) else { throw ImportError.unreadableFile }
        let head = (try? handle.read(upToCount: 1024)) ?? Data()
        try? handle.close()
        guard Self.looksLikePDF(head) else { throw ImportError.notAPDF }

        if FileManager.default.fileExists(atPath: dst.path) { try FileManager.default.removeItem(at: dst) }
        try FileManager.default.copyItem(at: src, to: dst)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dst.path)
    }

    /// "%PDF-" within the first 1024 bytes (the spec allows leading junk).
    nonisolated static func looksLikePDF(_ data: Data) -> Bool {
        let head = data.prefix(1024)
        return head.range(of: Data("%PDF-".utf8)) != nil
    }

    /// Lowercased alphanumeric words.
    nonisolated static func titleWords(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
    }


    /// Normalised title equality, tolerating small differences (punctuation, a word or two).
    nonisolated static func titlesMatch(_ a: String, _ b: String) -> Bool {
        let wa = titleWords(a), wb = titleWords(b)
        guard !wa.isEmpty, !wb.isEmpty else { return false }
        if wa == wb { return true }
        let sa = Set(wa), sb = Set(wb)
        let jaccard = Double(sa.intersection(sb).count) / Double(sa.union(sb).count)
        return min(wa.count, wb.count) >= 3 && jaccard >= 0.85
    }
}

// MARK: - PDF analysis (pure: Foundation + PDFKit only, safe off the main actor)

/// Title comparison used to accept a search hit as "this PDF".
enum TitleMatch {
    /// A hit is accepted only at or above this similarity.
    static let acceptThreshold = 0.9

    /// Lowercased alphanumeric words, diacritics folded.
    static func words(_ s: String) -> [String] {
        s.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .split(whereSeparator: { !($0.isLetter || $0.isNumber) })
            .map(String.init)
    }

    /// 0…1: Levenshtein ratio over the titles' alphanumeric characters with all spacing
    /// removed — PDF text often loses or adds spaces ("Provingand ImprovingthePlatonic").
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(words(a).joined()), y = Array(words(b).joined())
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        if x == y { return 1 }
        let longest = max(x.count, y.count)
        guard longest <= 1000 else { return 0 }
        // The distance is at least the length difference; skip the DP when that alone fails.
        if Double(abs(x.count - y.count)) / Double(longest) > 1 - acceptThreshold + 0.05 {
            return 1 - Double(abs(x.count - y.count)) / Double(longest)
        }
        var prev = Array(0...y.count)
        var cur = [Int](repeating: 0, count: y.count + 1)
        for i in 1...x.count {
            cur[0] = i
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return 1 - Double(prev[y.count]) / Double(longest)
    }

    static func matches(_ a: String, _ b: String) -> Bool {
        similarity(a, b) >= acceptThreshold && versionTokens(a) == versionTokens(b) && !swapsShortWord(a, b)
    }

    /// Whether the titles differ in a short word ("A Survey on X" vs "A Survey of X",
    /// "… for Y" vs "… in Y", "A Survey" vs "The Survey"): a different title, not a typo. Only
    /// decidable when both titles split into the same number of words (PDF text that lost its
    /// spaces is left to the similarity ratio).
    static func swapsShortWord(_ a: String, _ b: String) -> Bool {
        let x = words(a), y = words(b)
        if x.count == y.count {
            return zip(x, y).contains { $0 != $1 && min($0.count, $1.count) <= 3 }
        }
        // A short word added or dropped ("…: Survey" vs "…: A Survey").
        let (long, short) = x.count > y.count ? (x, y) : (y, x)
        guard long.count == short.count + 1 else { return false }
        for i in 0..<long.count where long[i].count <= 3 {
            var rest = long
            rest.remove(at: i)
            if rest == short { return true }
        }
        return false
    }

    private static let romans: Set<String> = ["ii", "iii", "iv", "vi", "vii", "viii", "ix", "xi", "xii"]

    /// Digit runs and roman numerals (II…XII) in a title, in order: what tells sibling papers
    /// apart ("Qwen2.5" → ["2", "5"], "Gemma 3" → ["3"], "Part II" → ["ii"]).
    static func versionTokens(_ s: String) -> [String] {
        var out: [String] = []
        for w in words(s) {
            if romans.contains(w) { out.append(w); continue }
            var run = ""
            for ch in w {
                if ch.isNumber { run.append(ch) } else if !run.isEmpty { out.append(run); run = "" }
            }
            if !run.isEmpty { out.append(run) }
        }
        return out.map { $0.count > 1 && $0.hasPrefix("0") ? String($0.drop(while: { $0 == "0" })) : $0 }
    }
}

/// One text line of a PDF page with its font sizes (from `PDFPage.attributedString`).
struct PDFLine: Sendable {
    var text: String
    /// Size covering most of the line's non-space characters.
    var size: Double
    /// Largest size on the line (small-caps headings have a large first letter only).
    var maxSize: Double
    /// Set in capitals throughout (small caps are already folded to lower case in `text`).
    var allCaps = false
}

enum PDFLayout {
    /// Lines of a page in PDFKit's reading order, empty lines dropped.
    static func lines(of page: PDFPage) -> [PDFLine] {
        guard let attr = page.attributedString, attr.length > 0 else {
            return (page.string ?? "").components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { PDFLine(text: normalizeGlyphs($0), size: 0, maxSize: 0) }
        }
        let ns = attr.string as NSString
        var out: [PDFLine] = []
        var parts: [(text: Substring, size: Double)] = []
        var counts: [Double: Int] = [:]
        var maxSize = 0.0

        func flush() {
            let raw = parts.map(\.text).joined()
            let t = raw.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty {
                let dominant = counts.max { a, b in a.value == b.value ? a.key < b.key : a.value < b.value }?.key ?? 0
                var text = t
                var caps = false
                // Small caps set in capitals ("1 I" at 12 pt + "NTRODUCTION" at 9.6 pt): the
                // smaller capitals stand for lower-case letters.
                let letters = t.filter(\.isLetter)
                if letters.count >= 3, letters == letters.uppercased() { caps = true }
                if caps, maxSize >= dominant * 1.1, t.count <= 150 {
                    text = parts.map { $0.size < maxSize * 0.9 ? $0.text.lowercased() : String($0.text) }
                        .joined().trimmingCharacters(in: .whitespaces)
                }
                out.append(PDFLine(text: normalizeGlyphs(text), size: dominant, maxSize: maxSize, allCaps: caps))
            }
            parts = []
            counts = [:]
            maxSize = 0
        }

        attr.enumerateAttribute(.font, in: NSRange(location: 0, length: attr.length)) { value, range, _ in
            let size = (value as? NSFont).map { Double($0.pointSize) } ?? 0
            let key = (size * 2).rounded() / 2
            let piece = ns.substring(with: range).replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            var first = true
            for part in piece.split(separator: "\n", omittingEmptySubsequences: false) {
                if !first { flush() }
                first = false
                parts.append((part, size))
                let visible = part.reduce(0) { $0 + ($1.isWhitespace ? 0 : 1) }
                if visible > 0 {
                    counts[key, default: 0] += visible
                    maxSize = max(maxSize, size)
                }
            }
        }
        flush()
        return out
    }

    /// Most common line size, weighted by characters (the body text size).
    static func bodySize(_ lines: [PDFLine]) -> Double {
        var weight: [Double: Int] = [:]
        for l in lines where l.size > 0 { weight[l.size, default: 0] += l.text.count }
        return weight.max { a, b in a.value == b.value ? a.key > b.key : a.value < b.value }?.key ?? 0
    }

    /// Ligatures and other presentation forms PDFKit passes through.
    static func normalizeGlyphs(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { (0xFB00...0xFB06).contains($0.value) || $0.value == 0x00A0 }) else { return s }
        return s.replacingOccurrences(of: "\u{FB00}", with: "ff")
            .replacingOccurrences(of: "\u{FB01}", with: "fi")
            .replacingOccurrences(of: "\u{FB02}", with: "fl")
            .replacingOccurrences(of: "\u{FB03}", with: "ffi")
            .replacingOccurrences(of: "\u{FB04}", with: "ffl")
            .replacingOccurrences(of: "\u{FB05}", with: "st")
            .replacingOccurrences(of: "\u{FB06}", with: "st")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    /// Joins two wrapped lines, removing a line-break hyphen ("repre-" + "sentation").
    static func join(_ a: String, _ b: String) -> String {
        guard !a.isEmpty else { return b }
        guard !b.isEmpty else { return a }
        if a.hasSuffix("-"), !a.hasSuffix("--") {
            let before = a.dropLast().last
            if before?.isLetter == true, b.first?.isLowercase == true { return String(a.dropLast()) + b }
            return a + b
        }
        return a + " " + b
    }

    /// The largest-font run of lines near the top of page 1 (the title), with the indices of
    /// the lines it spans. Nil when nothing stands out from the body text.
    static func title(in lines: [PDFLine]) -> (text: String, lines: Range<Int>)? {
        let body = bodySize(lines)
        guard body > 0 else { return nil }
        let head = Array(lines.prefix(30))
        func eligible(_ l: PDFLine) -> Bool {
            let letters = l.text.reduce(0) { $0 + ($1.isLetter ? 1 : 0) }
            return letters >= 2 && l.size > 0
                && l.text.range(of: "arxiv:", options: .caseInsensitive) == nil
                && !isPageFurniture(l.text)
        }
        guard let top = head.filter(eligible).map(\.size).max(), top >= body * 1.15,
              let start = head.firstIndex(where: { eligible($0) && $0.size >= top * 0.85 }) else { return nil }
        var end = start
        var text = ""
        while end < head.count, end - start < 4, eligible(head[end]), head[end].size >= top * 0.85 {
            text = join(text, head[end].text)
            end += 1
        }
        let clean = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard TitleMatch.words(clean).count >= 2, clean.count <= 300 else { return nil }
        return (clean, start..<end)
    }

    private static let pageNumber = try! NSRegularExpression(
        pattern: #"^(?:page\s+)?[-–—]?\s*(?:\d{1,4}|[ivxlc]{1,7})\s*[-–—]?(?:\s*(?:of|/)\s*\d{1,4})?$"#,
        options: [.caseInsensitive])

    /// Page numbers ("12", "- 12 -", "Page 3 of 20", "iv").
    static func isPageFurniture(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard t.count <= 20 else { return false }
        return pageNumber.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
    }
}

/// What a dropped PDF says about its own identity (first two pages + document metadata).
struct PDFIdentityHints: Sendable {
    var readable = false
    var pageCount = 0
    /// Trusted: the `arXivID` metadata arXiv adds, or the arXiv margin stamp.
    var stampArxiv: String?
    /// Other "arXiv:" ids on the first two pages, header/margin lines first. Unconfirmed: they
    /// may be cited preprints.
    var arxivCandidates: [String] = []
    /// The PDF's own DOI metadata (describes the file itself).
    var metadataDOI: String?
    /// DOIs in the text of the first two pages, in order. Unconfirmed.
    var textDOIs: [String] = []
    /// Document-info Title, only when it looks like a real title.
    var metadataTitle: String?
    var metadataAuthors: [String] = []
    /// Largest-font text near the top of page 1.
    var layoutTitle: String?
    /// Plain text of page 1 (for "does the candidate's title appear here" checks).
    var firstPage = ""

    /// Title to search for: meaningful metadata first, else the layout title.
    var titleGuess: String? { metadataTitle ?? layoutTitle }
}

enum PDFIdentity {
    private static let doiPattern = try! NSRegularExpression(
        pattern: #"\b10\.\d{4,9}/[^\s"<>{}]+"#, options: [])

    static func hints(for url: URL, fileStem: String?) -> PDFIdentityHints {
        var h = PDFIdentityHints()
        guard let doc = PDFDocument(url: url) else { return h }
        h.readable = true
        h.pageCount = doc.pageCount

        // Document metadata. arXiv's own PDFs carry arXivID / DOI keys.
        for (key, value) in doc.documentAttributes ?? [:] {
            guard let k = (key as? String)?.lowercased(), let v = value as? String else { continue }
            switch k {
            case "arxivid", "arxiv":
                if case .arxiv(let id)? = PaperInput.parse(v) { h.stampArxiv = id }
            case "doi":
                if case .doi(let doi)? = PaperInput.parse(v) { h.metadataDOI = doi }
            case "title":
                h.metadataTitle = meaningfulTitle(v, fileStem: fileStem)
            case "author":
                h.metadataAuthors = v.split(whereSeparator: { $0 == ";" || $0 == "\n" })
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && $0.count <= 200 }
            default:
                break
            }
        }
        if h.stampArxiv == nil, let doi = h.metadataDOI, let ax = ArxivID.fromArxivDOI(doi) {
            h.stampArxiv = ax
        }

        var text = ""
        var headerText = ""
        var marginStamp: String?
        for i in 0..<min(2, doc.pageCount) {
            guard let page = doc.page(at: i) else { continue }
            let s = page.string ?? ""
            text += s + "\n"
            if i == 0 { h.firstPage = s }
            let lines = PDFLayout.lines(of: page)
            if i == 0, h.layoutTitle == nil { h.layoutTitle = PDFLayout.title(in: lines)?.text }
            // Header/margin: the first and last few lines, and anything set much larger than
            // the body (arXiv's rotated margin stamp is 20 pt).
            let body = PDFLayout.bodySize(lines)
            for (j, l) in lines.enumerated()
            where j < 4 || j >= lines.count - 4 || (body > 0 && l.size >= body * 1.5) {
                headerText += l.text + "\n"
                // arXiv's margin stamp: a short line on page 1 set much larger than the body.
                if i == 0, marginStamp == nil, body > 0, l.size >= body * 1.5, l.text.count <= 80 {
                    marginStamp = ArxivID.findStamp(l.text)
                }
            }
        }
        // Trusted only in its margin-stamp form; any other "arXiv:… [cs]" on pages 1–2 may be a
        // cited preprint and stays an unconfirmed candidate.
        if h.stampArxiv == nil { h.stampArxiv = marginStamp ?? ArxivID.findDatedStamp(text) }

        var candidates = ArxivID.findAllInText(headerText)
        for id in ArxivID.findAllInText(text) where !candidates.contains(id) { candidates.append(id) }

        var dois: [String] = []
        let range = NSRange(text.startIndex..., in: text)
        for m in doiPattern.matches(in: text, range: range).prefix(20) {
            guard let r = Range(m.range, in: text) else { continue }
            var raw = String(text[r])
            while let last = raw.last, ".,;:)]}'".contains(last) { raw.removeLast() }
            guard let doi = DOIParser.normalize(raw),
                  !dois.contains(where: { $0.caseInsensitiveCompare(doi) == .orderedSame }) else { continue }
            if let ax = ArxivID.fromArxivDOI(doi) {
                if !candidates.contains(ax) { candidates.append(ax) }
            } else {
                dois.append(doi)
            }
        }
        h.textDOIs = Array(dois.prefix(5))
        if let stamp = h.stampArxiv {
            candidates.removeAll { ArxivID.stripVersion($0) == ArxivID.stripVersion(stamp) }
        }
        h.arxivCandidates = Array(candidates.prefix(5))
        return h
    }

    /// A document-info Title worth searching for (not "Microsoft Word - draft3.docx", a file
    /// name, or a one-word placeholder).
    static func meaningfulTitle(_ raw: String, fileStem: String?) -> String? {
        let t = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let lower = t.lowercased()
        guard t.count >= 8, t.count <= 300, TitleMatch.words(t).count >= 3 else { return nil }
        let junk = ["microsoft word", "untitled", "title of", "paper title", "your title", "insert title"]
        if junk.contains(where: { lower.hasPrefix($0) }) { return nil }
        if lower.range(of: #"\.(pdf|tex|dvi|ps|docx?|odt|rtf|pages)$"#, options: .regularExpression) != nil { return nil }
        if !t.contains(" ") { return nil }
        if let stem = fileStem, TitleMatch.words(stem) == TitleMatch.words(t) { return nil }
        return t
    }
}

/// Local, offline PDF → Markdown (no Claude): PDFKit text per page with running headers,
/// footers and page numbers dropped, line-break hyphens removed, lines joined into paragraphs
/// and headings detected from font sizes. Equations come out as plain (often garbled) text.
enum PDFTextExtractor {
    struct Output: Sendable {
        var markdown: String
        /// Characters of body text extracted (excluding the title and the note).
        var textCharacters: Int
        var pages: Int
        var headings: Int
        var paragraphs: Int
    }

    private static let captionStart = try! NSRegularExpression(
        pattern: #"^(Figure|Fig\.|Table|Algorithm|Listing)\s*([A-Z]?\d+(?:\.\d+)?[a-z]?)\s*[.:|]\s*"#)
    private static let numbered = try! NSRegularExpression(
        pattern: #"^((?:\d{1,2}|[A-Z])(?:\.\d{1,2})*)\.?\s+\S"#)
    private static let knownHeading = try! NSRegularExpression(
        pattern: #"^(abstract|introduction|background|related work|preliminaries|method(s|ology)?|experiments?|results|discussion|limitations|conclusions?|references|bibliography|acknowledg(e)?ments?|appendix|appendices|supplementary material)\b"#,
        options: [.caseInsensitive])
    private static let bullet = try! NSRegularExpression(pattern: #"^[•◦▪∙·●○■□–]\s+"#)

    static func markdown(from url: URL, title: String?, note: String?) -> Output? {
        guard let doc = PDFDocument(url: url) else { return nil }
        return markdown(from: doc, title: title, note: note)
    }

    static func markdown(from doc: PDFDocument, title: String?, note: String?) -> Output? {
        let pageCount = min(doc.pageCount, 2000)
        guard pageCount > 0 else { return nil }
        var pages: [[PDFLine]] = (0..<pageCount).map { i in
            doc.page(at: i).map(PDFLayout.lines(of:)) ?? []
        }
        let body = PDFLayout.bodySize(pages.flatMap { $0 })

        // Running headers / footers: the same text (digits ignored) among the first or last
        // three lines of many pages.
        func furnitureKey(_ s: String) -> String {
            s.lowercased().replacingOccurrences(of: #"\d+"#, with: "#", options: .regularExpression)
                .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        }
        let edge = 3
        var edgeCounts: [String: Int] = [:]
        for lines in pages {
            var seen = Set<String>()
            for (j, l) in lines.enumerated() where j < edge || j >= lines.count - edge {
                let k = furnitureKey(l.text)
                if !k.isEmpty, seen.insert(k).inserted { edgeCounts[k, default: 0] += 1 }
            }
        }
        let repeatThreshold = max(3, Int((Double(pageCount) * 0.3).rounded(.up)))
        for p in pages.indices {
            let lines = pages[p]
            pages[p] = lines.enumerated().compactMap { j, l in
                let atEdge = j < edge || j >= lines.count - edge
                if atEdge {
                    if PDFLayout.isPageFurniture(l.text) { return nil }
                    if pageCount >= 4, (edgeCounts[furnitureKey(l.text)] ?? 0) >= repeatThreshold { return nil }
                }
                // The arXiv margin stamp, wherever PDFKit places it in the reading order.
                if l.text.count <= 80, ArxivID.findStamp(l.text) != nil { return nil }
                // Figure-internal labels (axis ticks, legends): short lines in a small font.
                if body > 0, l.size > 0, l.maxSize < body * 0.9, l.text.count < 40, !isCaption(l.text) { return nil }
                return l
            }
        }

        // Title: given (from metadata) or the largest text on page 1. Its lines are removed.
        var docTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let found = PDFLayout.title(in: pages[0]) {
            if docTitle == nil || docTitle!.isEmpty { docTitle = found.text }
            if docTitle.map({ TitleMatch.similarity($0, found.text) >= 0.6 }) == true {
                pages[0].removeSubrange(found.lines)
            }
        }

        let shownTitle = (docTitle?.isEmpty == false ? docTitle! : "Untitled paper")

        var blocks: [Block] = []
        var para = ""
        var paraKind: ParaKind = .text
        var lastLine: PDFLine?
        var lastWasHeadingLine = false
        var seenHeading = false

        func flushPara() {
            let t = para.trimmingCharacters(in: .whitespaces)
            para = ""
            defer { paraKind = .text }
            guard !t.isEmpty else { return }
            // Body text interrupted by a figure, footnote or page break resumes mid-sentence
            // (lower-case start): append it to the unfinished paragraph it belongs to.
            if paraKind == .text, let first = t.first, first.isLowercase,
               let k = blocks.indices.reversed().prefix(6).first(where: { blocks[$0].isOpenText }),
               !blocks[k...].contains(where: \.isHeading) {
                blocks[k].append(t)
                return
            }
            // Isolated scraps after the front matter: figure labels, stray numbers.
            if paraKind == .text, seenHeading, isScrap(t) { return }
            blocks.append(.paragraph(paraKind, t))
        }

        for (pageIndex, lines) in pages.enumerated() {
            let bodyLens = lines.filter { body == 0 || abs($0.size - body) <= 0.75 }.map(\.text.count).sorted()
            let typical = bodyLens.isEmpty ? 80 : bodyLens[min(bodyLens.count - 1, Int(Double(bodyLens.count) * 0.8))]
            for line in lines {
                let t = line.text
                var level = headingLevel(line, body: body)
                // Front matter (authors, affiliations) is often set larger than the body: on
                // page 1, before the first real section, only numbered or known headings count.
                if level != nil, pageIndex == 0, !seenHeading, !isSectionHeading(t) { level = nil }
                if let level {
                    if lastWasHeadingLine, case .heading(let lv, let prev)? = blocks.last,
                       numbered.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) == nil,
                       let lastLine, abs(lastLine.size - line.size) < 0.6, prev.count < 160 {
                        // A heading wrapped onto a second line.
                        blocks[blocks.count - 1] = .heading(lv, prev + " " + headingText(t))
                    } else {
                        flushPara()
                        blocks.append(.heading(level, headingText(t)))
                        seenHeading = true
                    }
                    lastWasHeadingLine = true
                    lastLine = line
                    continue
                }
                let startsCaption = isCaption(t)
                let startsBullet = bullet.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
                let captionEnds = paraKind == .caption && (para.last.map { ".!?".contains($0) } ?? false)
                    && t.first?.isLowercase == true
                if para.isEmpty {
                    paraKind = startsCaption ? .caption : (startsBullet ? .bullet : .text)
                    para = startsBullet ? stripBullet(t) : t
                } else if startsCaption || startsBullet || captionEnds
                            || shouldBreak(after: lastLine, before: line, typical: typical, body: body) {
                    flushPara()
                    paraKind = startsCaption ? .caption : (startsBullet ? .bullet : .text)
                    para = startsBullet ? stripBullet(t) : t
                } else {
                    para = PDFLayout.join(para, t)
                }
                lastWasHeadingLine = false
                lastLine = line
            }
            // Page break: the open paragraph is closed; if it ended mid-sentence, the next
            // page's lower-case continuation is appended to it again by flushPara.
            flushPara()
        }
        flushPara()

        var out: [String] = ["# " + escapeInline(shownTitle)]
        if let note, !note.isEmpty { out.append("> " + note) }
        var textChars = 0, headings = 0, paragraphs = 0
        for b in blocks {
            switch b {
            case .heading(let level, let text):
                headings += 1
                out.append(String(repeating: "#", count: level) + " " + escapeInline(text))
            case .paragraph(let kind, let text):
                paragraphs += 1
                textChars += text.count
                out.append(render(text, kind: kind))
            }
        }
        return Output(markdown: out.joined(separator: "\n\n") + "\n", textCharacters: textChars,
                      pages: pageCount, headings: headings, paragraphs: paragraphs)
    }

    private enum Block {
        case heading(Int, String)
        case paragraph(ParaKind, String)

        var isHeading: Bool { if case .heading = self { return true } else { return false } }

        /// A body paragraph that stopped mid-sentence.
        var isOpenText: Bool {
            guard case .paragraph(.text, let t) = self, let last = t.last else { return false }
            return !".!?:;”\")]".contains(last)
        }

        mutating func append(_ more: String) {
            if case .paragraph(let k, let t) = self { self = .paragraph(k, PDFLayout.join(t, more)) }
        }
    }

    /// Short fragments with no sentence shape (axis labels, legend words, stray numbers).
    private static func isScrap(_ t: String) -> Bool {
        guard t.count < 25 else { return false }
        if t.contains(":") || t.contains("<") { return false }
        if let last = t.last, ".!?".contains(last) { return false }
        return t.split(whereSeparator: { $0.isWhitespace }).count <= 3
    }

    private enum ParaKind { case text, caption, bullet }

    /// "3 Results", "A.1 Proofs", "Abstract", "References" …
    private static func isSectionHeading(_ t: String) -> Bool {
        let r = NSRange(t.startIndex..., in: t)
        if knownHeading.firstMatch(in: t, range: r) != nil { return true }
        guard let m = numbered.firstMatch(in: t, range: r), let nr = Range(m.range(at: 1), in: t) else { return false }
        return t[nr].first?.isNumber == true
    }

    private static func isCaption(_ s: String) -> Bool {
        captionStart.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    private static func stripBullet(_ s: String) -> String {
        bullet.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "")
    }

    private static func shouldBreak(after prev: PDFLine?, before line: PDFLine, typical: Int, body: Double) -> Bool {
        guard let prev else { return false }
        // A change of text size (body → footnote, caption → body).
        if prev.size > 0, line.size > 0, abs(prev.size - line.size) >= 1.0 { return true }
        let p = prev.text
        let short = Double(p.count) < Double(typical) * 0.75
        if short, let last = p.last, ".!?:”\")".contains(last) { return true }
        // Very short lines (author lists, affiliations, list items) stand alone.
        if Double(p.count) < Double(typical) * 0.45, p.count < 60 { return true }
        return false
    }

    /// Heading level (2…4) for a line that looks like a section heading, else nil.
    private static func headingLevel(_ l: PDFLine, body: Double) -> Int? {
        let t = l.text.trimmingCharacters(in: .whitespaces)
        let words = t.split(whereSeparator: { $0.isWhitespace }).count
        let letters = t.reduce(0) { $0 + ($1.isLetter ? 1 : 0) }
        guard t.count >= 2, t.count <= 100, letters >= 2, words <= 14, body > 0 else { return nil }
        if let last = t.last, ",;".contains(last) { return nil }
        if t.hasSuffix("."), words > 6 { return nil }
        if isCaption(t) { return nil }
        let range = NSRange(t.startIndex..., in: t)
        let numMatch = numbered.firstMatch(in: t, range: range)
        let isKnown = knownHeading.firstMatch(in: t, range: range) != nil && words <= 4
        let allCaps = l.allCaps
        let dominantLarger = l.size >= body * 1.12
        let anyLarger = l.maxSize >= body * 1.12
        // A single capital letter as the "number" ("A Study of…") only counts in a larger font.
        var number: String?
        if let m = numMatch, let r = Range(m.range(at: 1), in: t) {
            let n = String(t[r])
            if n.count > 1 || n.first?.isNumber == true || dominantLarger || anyLarger { number = n }
        }

        let isHeading: Bool
        if dominantLarger {
            isHeading = true
        } else if anyLarger {
            isHeading = number != nil || isKnown || allCaps
        } else {
            // Body-sized: only an exact known heading word, or a numbered all-caps line.
            isHeading = (isKnown && words <= 2 && (allCaps || t.first?.isUppercase == true) && !t.hasSuffix("."))
                || (number != nil && allCaps && words <= 8)
        }
        guard isHeading else { return nil }
        if let number {
            let depth = number.split(separator: ".").count
            return min(4, depth + 1)
        }
        return 2
    }

    /// All-caps headings ("1 INTRODUCTION") in title case.
    private static func headingText(_ s: String) -> String {
        let letters = s.filter(\.isLetter)
        guard letters.count >= 4, letters == letters.uppercased() else { return s }
        return s.split(separator: " ", omittingEmptySubsequences: true).map { w -> String in
            let word = String(w)
            guard word.contains(where: \.isLetter) else { return word }
            return word.prefix(1).uppercased() + word.dropFirst().lowercased()
        }.joined(separator: " ")
    }

    private static func render(_ t: String, kind: ParaKind) -> String {
        switch kind {
        case .caption:
            let r = NSRange(t.startIndex..., in: t)
            if let m = captionStart.firstMatch(in: t, range: r),
               let labelR = Range(m.range(at: 1), in: t), let numR = Range(m.range(at: 2), in: t),
               let all = Range(m.range, in: t) {
                let label = t[labelR] == "Fig." ? "Figure" : String(t[labelR])
                return "> **\(label) \(t[numR]).** " + escapeInline(String(t[all.upperBound...]))
            }
            return "> " + escapeInline(t)
        case .bullet:
            return "- " + escapeInline(t)
        case .text:
            return escapeBlockStart(escapeInline(t))
        }
    }

    /// Escapes Markdown syntax in extracted text. `[` is left alone: `\[` is a display-math
    /// delimiter for the ingest step.
    static func escapeInline(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count + 8)
        for ch in s {
            switch ch {
            case "\\", "$", "*", "_", "`", "<", "~", "|":
                out.append("\\")
                out.append(ch)
            default:
                if let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1,
                   CharacterSet.controlCharacters.contains(scalar) {
                    out.append(" ")
                } else {
                    out.append(ch)
                }
            }
        }
        return out
    }

    /// A paragraph must not start a heading, quote, list or rule by accident.
    private static func escapeBlockStart(_ s: String) -> String {
        if let first = s.first, "#>+-=".contains(first) { return "\\" + s }
        if let r = s.range(of: #"^\d{1,9}[.)](?=\s)"#, options: .regularExpression) {
            var t = s
            t.insert("\\", at: s.index(before: r.upperBound))
            return t
        }
        return s
    }
}

extension TitleMatch {
    /// Whether `title` (≥ 3 words) appears in `text` (e.g. a PDF's first page) — word for word,
    /// or, for PDFs whose text lost its spaces, as a run of the same letters and digits.
    static func text(_ text: String, containsTitle title: String) -> Bool {
        let t = words(title)
        guard t.count >= 3 else { return false }
        let hayWords = words(text)
        if (" " + hayWords.joined(separator: " ") + " ").contains(" " + t.joined(separator: " ") + " ") { return true }
        let compactTitle = t.joined()
        return compactTitle.count >= 15 && hayWords.joined().contains(compactTitle)
    }
}

/// How a dropped PDF was identified.
struct PDFIdentityResolution: Sendable {
    enum Source: String, Sendable { case stamp, arxivMention, doi, title }
    var arxivId: String?
    var doi: String?
    var s2: S2Paper?
    var arxiv: ArxivEntry?
    var source: Source
    /// The PDF's own metadata DOI (not one found in the text).
    var trustedDOI = false

    /// Identity the PDF states about itself (arXiv metadata / margin stamp, its own DOI
    /// metadata): strong enough to fold it into an existing library paper.
    var isStrong: Bool { source == .stamp || (source == .doi && trustedDOI) }
}

/// Identifies a dropped PDF before anything is paid for: (a) arXiv metadata / margin stamp,
/// or an "arXiv:" mention confirmed by its title; (b) a DOI → Semantic Scholar → arXiv id;
/// (c) the title (document info or largest text on page 1) → Semantic Scholar title match and
/// the arXiv API, accepted only at ≥ 0.9 normalised-title similarity. Network failures at any
/// step just move on to the next one.
enum PDFIdentityResolver {
    static func resolve(_ h: PDFIdentityHints,
                        status: @escaping @Sendable (String) async -> Void) async throws -> PDFIdentityResolution? {
        // (a) The PDF's own arXiv id.
        if let id = h.stampArxiv {
            return PDFIdentityResolution(arxivId: id, doi: h.metadataDOI, source: .stamp)
        }
        for candidate in h.arxivCandidates.prefix(3) {
            try Task.checkCancellation()
            await status("Checking arXiv id…")
            let s2 = try? await ScholarAPI.paper(ScholarAPI.arxivID(candidate))
            try Task.checkCancellation()
            var entry: ArxivEntry?
            var title = s2?.cleanTitle
            if title == nil {
                entry = try? await ArxivAPI.entry(id: candidate)
                title = entry?.title
            }
            if let title, confirms(title, h) {
                return PDFIdentityResolution(arxivId: candidate, doi: s2?.externalIds?.doi, s2: s2,
                                             arxiv: entry, source: .arxivMention)
            }
        }

        // (b) DOI: the PDF's own metadata DOI is trusted; DOIs in the text may be citations, so
        // their title must match this PDF.
        var dois: [String] = []
        if let d = h.metadataDOI { dois.append(d) }
        for d in h.textDOIs where !dois.contains(where: { $0.caseInsensitiveCompare(d) == .orderedSame }) { dois.append(d) }
        for doi in dois.prefix(3) {
            try Task.checkCancellation()
            await status("Looking up DOI…")
            guard let m = try? await ScholarAPI.paper(ScholarAPI.doiID(doi)) else { continue }
            try Task.checkCancellation()
            let trusted = doi == h.metadataDOI
            guard trusted || (m.cleanTitle.map { confirms($0, h) } ?? false) else { continue }
            return PDFIdentityResolution(arxivId: validArxiv(m.externalIds?.arXiv), doi: doi, s2: m, source: .doi,
                                         trustedDOI: trusted)
        }

        // (c) Title search.
        guard let title = h.titleGuess else { return nil }
        try Task.checkCancellation()
        await status("Searching for the title…")
        var s2Hit: S2Paper?
        if let m = try? await ScholarAPI.matchPaper(title: title), let t = m.cleanTitle, titleHitAccepted(t, title, hitAuthors: m.authorNames, h) {
            if let ax = validArxiv(m.externalIds?.arXiv) {
                return PDFIdentityResolution(arxivId: ax, doi: m.externalIds?.doi.flatMap(DOIParser.normalize),
                                             s2: m, source: .title)
            }
            s2Hit = m
        }
        try Task.checkCancellation()
        await status("Searching arXiv for the title…")
        if let entries = try? await ArxivAPI.search(title: title),
           let e = entries.sorted(by: { TitleMatch.similarity($0.title, title) > TitleMatch.similarity($1.title, title) })
               .first(where: { titleHitAccepted($0.title, title, hitAuthors: $0.authors, h) }) {
            return PDFIdentityResolution(arxivId: ArxivID.stripVersion(e.id),
                                         doi: s2Hit?.externalIds?.doi.flatMap(DOIParser.normalize) ?? e.doi,
                                         s2: s2Hit, arxiv: e, source: .title)
        }
        if let s2Hit {
            return PDFIdentityResolution(arxivId: nil, doi: s2Hit.externalIds?.doi.flatMap(DOIParser.normalize),
                                         s2: s2Hit, source: .title)
        }
        return nil
    }

    /// A looked-up title (of an arXiv id / DOI mentioned in the text) belongs to this PDF if it
    /// matches the PDF's own title. Appearing somewhere on page 1 is not enough when the PDF
    /// has a title of its own: "Notes on X", a review of X, or a reference list all print X.
    static func confirms(_ title: String, _ h: PDFIdentityHints) -> Bool {
        let own = [h.metadataTitle, h.layoutTitle].compactMap { $0 }
        if own.contains(where: { TitleMatch.matches($0, title) }) { return true }
        if own.isEmpty { return TitleMatch.text(h.firstPage, containsTitle: title) }
        return false
    }

    /// A title-search hit is this PDF: the hit's title is printed on page 1 word for word and
    /// matches the searched title, or matches it very closely. Version numbers must agree
    /// ("Qwen3" ≠ "Qwen2", "Part II" ≠ "Part I") — see TitleMatch.matches.
    /// The hit's authors must also agree with the PDF: a title alone does not identify a paper
    /// (surveys and position papers often share near-identical titles).
    static func titleHitAccepted(_ hit: String, _ searched: String, hitAuthors: [String],
                                 _ h: PDFIdentityHints) -> Bool {
        guard TitleMatch.matches(hit, searched) else { return false }
        guard TitleMatch.text(h.firstPage, containsTitle: hit)
                || TitleMatch.similarity(hit, searched) >= 0.95 else { return false }
        switch authorsAgree(hitAuthors, h) {
        case true?: return true
        case false?: return false
        case nil:
            // Nothing to compare (no author list on either side): only an exact title printed
            // on page 1 is enough.
            return TitleMatch.similarity(hit, searched) == 1 && TitleMatch.text(h.firstPage, containsTitle: hit)
        }
    }

    /// true: a surname of the hit's authors appears in the PDF's author metadata or in the
    /// header of page 1 (before the abstract, so cited names do not count); false: the PDF
    /// has author information and none matches; nil: nothing to compare.
    static func authorsAgree(_ hitAuthors: [String], _ h: PDFIdentityHints) -> Bool? {
        let surnames = Set(hitAuthors.prefix(50).compactMap(surname))
        guard !surnames.isEmpty else { return nil }
        let metaWords = Set(h.metadataAuthors.flatMap { TitleMatch.words($0) })
        let header = pageHeader(h.firstPage)
        let headerWords = Set(TitleMatch.words(header))
        let headerCompact = headerWords.isEmpty ? "" : TitleMatch.words(header).joined()
        guard !metaWords.isEmpty || !headerWords.isEmpty else { return nil }
        for s in surnames {
            if metaWords.contains(s) || headerWords.contains(s) { return true }
            // Text that lost its spaces ("WayneXinZhao").
            if s.count >= 4, headerCompact.contains(s) { return true }
        }
        return false
    }

    /// Lowercased, folded family name: "Zhao, Wayne Xin" → "zhao", "Wayne Xin Zhao" → "zhao".
    static func surname(_ name: String) -> String? {
        let family = name.contains(",") ? String(name.split(separator: ",")[0]) : name
        let w = TitleMatch.words(family)
        guard let last = w.last, last.count >= 2 else { return nil }
        return last
    }

    /// Page-1 text up to the abstract / introduction (where titles and author names sit).
    static func pageHeader(_ page: String) -> String {
        let lower = page.lowercased()
        var end = lower.endIndex
        for marker in ["abstract", "introduction"] {
            if let r = lower.range(of: marker), r.lowerBound < end { end = r.lowerBound }
        }
        let cut = lower.distance(from: lower.startIndex, to: end)
        return String(page.prefix(min(cut, 3000)))
    }

    private static func validArxiv(_ raw: String?) -> String? {
        guard let id = raw?.trimmingCharacters(in: .whitespaces), ArxivID.isValid(id) else { return nil }
        return id
    }
}
