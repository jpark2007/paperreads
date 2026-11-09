import Foundation
import PDFKit
import SwiftData

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

    /// The first "arXiv:XXXX.XXXXX(vN)" anywhere in the text. May be a cited preprint, so the
    /// caller must confirm it (see Importer.detectArxivID / pipeline).
    static func findInText(_ text: String) -> String? {
        find(text, patterns: [#"arXiv:(\d{4}\.\d{4,5})(v\d+)?"#,
                              #"arXiv:([a-z]+(?:-[a-z]+)?(?:\.[A-Z]{2})?/\d{7})(v\d+)?"#])
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

    private static let placeholderPrefix = "Importing "
    nonisolated private static let maxLocalPDFBytes = HTTP.maxPDFBytes
    private static let maxConvertPDFBytes = 32 * 1024 * 1024
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
    /// possibly from a slow volume) runs off the main actor; the Paper is returned at once.
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
                Result { try Importer.copyPDF(from: url, to: dst) }
            }.value
            guard let self else { return }
            self.activeIds.remove(id)
            guard let p = self.paper(id, context) else {
                self.cleanupOrphanDirectory(id, context)
                return
            }
            switch result {
            case .success:
                p.hasPDF = true
                p.importStatusDetail = "Waiting…"
                self.save(context)
                self.enqueue(Job(id: id, context: context))
            case .failure(let error):
                p.importState = .failed
                p.importStatusDetail = error.localizedDescription
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
        paper.importState = .queued
        paper.importStatusDetail = "Waiting…"
        save(context)
        enqueue(Job(id: id, context: context))
    }

    /// Stops any queued or running work for a paper (call before deleting it).
    func cancel(_ paperId: UUID) {
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

    /// On launch: papers left in a busy state by a previous run are marked failed.
    @MainActor
    static func recoverInterrupted(context: ModelContext) {
        guard let papers = try? context.fetch(FetchDescriptor<Paper>()) else { return }
        var changed = false
        for p in papers {
            if p.importState.isBusy {
                p.importState = .failed
                p.importStatusDetail = "Interrupted — Retry"
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
        do {
            try await pipeline(job.id, ctx)
            if paper(job.id, ctx) != nil { enqueueReferences(job) }
        } catch {
            guard let p = paper(job.id, ctx) else {
                cleanupOrphanDirectory(job.id, ctx)
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

        // 1. Resolve.
        if arxivId == nil, let doi = p.doi {
            try update(id, ctx, .fetching, "Looking up DOI…")
            do {
                meta = try await ScholarAPI.paper(ScholarAPI.doiID(doi))
            } catch ScholarError.notFound {
                throw ImportError.noOpenAccessPDF
            }
            p = try require(id, ctx)
            if let m = meta { apply(m, to: p) }
            if let ax = meta?.externalIds?.arXiv?.trimmingCharacters(in: .whitespaces), ArxivID.isValid(ax) {
                arxivId = ax
                p.arxivId = ax
                save(ctx)
            } else if !p.hasPDF {
                guard let pdfURL = meta?.openAccessPDFURL else { throw ImportError.noOpenAccessPDF }
                try update(id, ctx, .fetching, "Downloading PDF…")
                let data = try await downloadPDF(pdfURL)
                try await writePDF(data, id, ctx)
            }
        } else if arxivId == nil, p.hasPDF {
            try update(id, ctx, .fetching, "Reading PDF…")
            let localPDF = PaperStore.pdfURL(id)
            let detected = await Task.detached(priority: .userInitiated) {
                Importer.detectArxivID(in: localPDF)
            }.value
            var found: String?
            if let stamp = detected.stamp {
                found = stamp
            } else if let candidate = detected.candidate {
                // An "arXiv:" mention without the margin stamp may be a cited preprint: only
                // take it when that preprint's title appears on the PDF's first page.
                try update(id, ctx, .fetching, "Checking arXiv id…")
                if let m = try? await ScholarAPI.paper(ScholarAPI.arxivID(candidate)),
                   let t = m.cleanTitle, Self.text(detected.firstPage, containsTitle: t) {
                    found = candidate
                    meta = m
                }
                try Task.checkCancellation()
            }
            p = try require(id, ctx)
            if let found {
                arxivId = found
                p.arxivId = found
                p.sourceURL = "https://arxiv.org/abs/\(found)"
                if let m = meta { apply(m, to: p) }
                save(ctx)
            }
        }

        if let arxivId {
            try await arxivPath(id, arxivId, meta, ctx)
        } else {
            try await pdfPath(id, ctx)
        }
    }

    // 2. arXiv path.
    private func arxivPath(_ id: UUID, _ arxivId: String, _ known: S2Paper?, _ ctx: ModelContext) async throws {
        var meta = known
        if meta == nil {
            try update(id, ctx, .fetching, "Fetching metadata…")
            meta = try? await ScholarAPI.paper(ScholarAPI.arxivID(arxivId))
            try Task.checkCancellation()
            if let m = meta { apply(m, to: try require(id, ctx)); save(ctx) }
        }

        try update(id, ctx, .fetching, "Fetching arXiv text…")
        if let (html, finalURL) = try await fetchArxivHTML(arxivId) {
            try update(id, ctx, .converting, "Preparing clean text…")
            let result = try await WebProcessor.shared.ingestArxivHTML(html, baseURL: finalURL)
            try await finish(id, ctx, result, kind: .arxivHTML)

            // Keep a copy of the PDF for the PDF view (non-fatal).
            if let p = paper(id, ctx), !p.hasPDF {
                if let url = URL(string: "https://arxiv.org/pdf/\(arxivId)"),
                   let data = try? await downloadPDF(url) {
                    try? await writePDF(data, id, ctx)
                }
                try Task.checkCancellation()
            }
            return
        }

        // No LaTeXML HTML: fall back to the PDF.
        if try require(id, ctx).hasPDF == false {
            try update(id, ctx, .fetching, "Downloading PDF…")
            guard let url = URL(string: "https://arxiv.org/pdf/\(arxivId)") else { throw ImportError.missingPDF }
            let data = try await downloadPDF(url)
            try await writePDF(data, id, ctx)
        }
        try await pdfPath(id, ctx)
    }

    /// arxiv.org/html first, then ar5iv. Valid only if the page is LaTeXML output.
    private func fetchArxivHTML(_ arxivId: String) async throws -> (String, URL)? {
        let candidates = ["https://arxiv.org/html/\(arxivId)",
                          "https://ar5iv.labs.arxiv.org/html/\(arxivId)"]
        for c in candidates {
            try Task.checkCancellation()
            guard let url = URL(string: c) else { continue }
            do {
                let (data, response) = try await HTTP.get(url, maxBytes: HTTP.maxHTMLBytes,
                                                          headers: ["Accept": "text/html"])
                guard response.statusCode == 200 else { continue }
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
            } catch {
                continue
            }
        }
        return nil
    }

    // 3. PDF path.
    private func pdfPath(_ id: UUID, _ ctx: ModelContext) async throws {
        let p = try require(id, ctx)
        guard p.hasPDF else { throw ImportError.missingPDF }
        guard AppSettings.shared.effectiveAPIKey != nil else { throw ImportError.missingAPIKey }

        try update(id, ctx, .converting, "Checking PDF…")
        let pdfFile = PaperStore.pdfURL(id)
        let maxBytes = Self.maxConvertPDFBytes
        let maxPages = Self.maxConvertPages
        let (data, pageCount): (Data, Int) = try await Task.detached(priority: .userInitiated) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: pdfFile.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            guard size > 0 else { throw ImportError.missingPDF }
            guard size <= maxBytes else { throw ImportError.fileTooLarge(maxBytes) }
            let d = try Data(contentsOf: pdfFile)
            guard Importer.looksLikePDF(d) else { throw ImportError.notAPDF }
            guard let doc = PDFDocument(data: d) else { throw ImportError.unreadableFile }
            if doc.pageCount > maxPages { throw ImportError.pdfTooLong(doc.pageCount) }
            return (d, doc.pageCount)
        }.value

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
        let mdURL = PaperStore.markdownURL(id)
        let mdCopy = md
        try await Task.detached(priority: .userInitiated) {
            try Data(mdCopy.utf8).write(to: mdURL, options: .atomic)
        }.value

        try update(id, ctx, .converting, "Preparing clean text…")
        let result = try await WebProcessor.shared.ingestMarkdown(md)
        try await finish(id, ctx, result, kind: .claudeMarkdown)
        if !conversion.isComplete, let p = paper(id, ctx) {
            p.importStatusDetail = "Text incomplete — the PDF was too long to convert in one pass."
            save(ctx)
        }
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

    struct DetectedArxiv: Sendable {
        /// Id from the arXiv margin stamp (trusted).
        var stamp: String?
        /// First "arXiv:" id mentioned anywhere (unconfirmed; may be a cited preprint).
        var candidate: String?
        var firstPage: String
    }

    /// Text of the first two pages → arXiv stamp, or an unconfirmed candidate.
    nonisolated static func detectArxivID(in url: URL) -> DetectedArxiv {
        guard let doc = PDFDocument(url: url) else { return DetectedArxiv(firstPage: "") }
        var text = ""
        var first = ""
        for i in 0..<min(2, doc.pageCount) {
            if let s = doc.page(at: i)?.string {
                text += s + "\n"
                if i == 0 { first = s }
            }
        }
        let stamp = ArxivID.findStamp(text)
        return DetectedArxiv(stamp: stamp, candidate: stamp == nil ? ArxivID.findInText(text) : nil,
                             firstPage: first)
    }

    /// Lowercased alphanumeric words.
    nonisolated static func titleWords(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
    }

    /// Whether `title` (≥ 3 words) appears, word for word, in `text` (e.g. a PDF's first page).
    nonisolated static func text(_ text: String, containsTitle title: String) -> Bool {
        let t = titleWords(title)
        guard t.count >= 3 else { return false }
        let hay = " " + titleWords(text).joined(separator: " ") + " "
        return hay.contains(" " + t.joined(separator: " ") + " ")
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
