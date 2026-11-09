import Foundation
import SwiftData

// CONTRACT FILE — on-disk layout for paper content. All file IO goes through here.
//
// ~/Library/Application Support/Paperreads/
//   config.json                    (0600, see AppSettings)
//   papers/<uuid>/original.pdf
//   papers/<uuid>/content.html     cleaned HTML (data-b blocks, .m math spans)
//   papers/<uuid>/blocks.json      [ContentBlock]
//   papers/<uuid>/source.md        Claude markdown (claudeMarkdown papers only)
//   papers/<uuid>/source.json      SourceConversionInfo for source.md (reuse on retry)

enum PaperStore {
    static let appSupport: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("Paperreads", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir
    }()

    static func dir(for id: UUID) -> URL {
        let d = appSupport.appendingPathComponent("papers", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func pdfURL(_ id: UUID) -> URL { dir(for: id).appendingPathComponent("original.pdf") }
    /// Same path as `pdfURL` without creating the directory (cheap enough for view bodies).
    static func pdfURLForReading(_ id: UUID) -> URL {
        appSupport.appendingPathComponent("papers", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent("original.pdf")
    }
    static func htmlURL(_ id: UUID) -> URL { dir(for: id).appendingPathComponent("content.html") }
    static func blocksURL(_ id: UUID) -> URL { dir(for: id).appendingPathComponent("blocks.json") }
    static func markdownURL(_ id: UUID) -> URL { dir(for: id).appendingPathComponent("source.md") }

    static func markdownInfoURL(_ id: UUID) -> URL { dir(for: id).appendingPathComponent("source.json") }

    /// Identifies the PDF a saved `source.md` was converted from, so a retry can reuse the
    /// paid conversion instead of running it again.
    struct SourceConversionInfo: Codable, Sendable {
        var pdfSize: Int
        var pdfSHA256: String
        var isComplete: Bool
    }

    /// Saved Markdown for this exact PDF (matching size and hash), or nil.
    static func readSavedConversion(_ id: UUID, pdfSize: Int, pdfSHA256: String) -> (markdown: String, isComplete: Bool)? {
        guard let infoData = try? Data(contentsOf: markdownInfoURL(id)),
              let info = try? JSONDecoder().decode(SourceConversionInfo.self, from: infoData),
              info.pdfSize == pdfSize, info.pdfSHA256 == pdfSHA256,
              let md = try? String(contentsOf: markdownURL(id), encoding: .utf8),
              !md.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return (md, info.isComplete)
    }

    /// Writes source.md, then its sidecar (the sidecar is only valid once the Markdown is on disk).
    static func writeSavedConversion(_ id: UUID, markdown: String, info: SourceConversionInfo) throws {
        try? FileManager.default.removeItem(at: markdownInfoURL(id))
        try Data(markdown.utf8).write(to: markdownURL(id), options: .atomic)
        try JSONEncoder().encode(info).write(to: markdownInfoURL(id), options: .atomic)
    }

    static func writeContent(_ result: IngestResult, for id: UUID) throws {
        try Data(result.html.utf8).write(to: htmlURL(id), options: .atomic)
        try JSONEncoder().encode(result.blocks).write(to: blocksURL(id), options: .atomic)
    }

    static func readHTML(_ id: UUID) -> String? {
        try? String(contentsOf: htmlURL(id), encoding: .utf8)
    }

    static func readBlocks(_ id: UUID) -> [ContentBlock] {
        guard let data = try? Data(contentsOf: blocksURL(id)) else { return [] }
        return (try? JSONDecoder().decode([ContentBlock].self, from: data)) ?? []
    }

    /// Deletes a paper, every dependent row, and its directory.
    @MainActor
    static func delete(_ paper: Paper, in context: ModelContext) {
        let pid = paper.id
        try? context.delete(model: Highlight.self, where: #Predicate { $0.paperId == pid })
        try? context.delete(model: ReferenceEntry.self, where: #Predicate { $0.paperId == pid })
        try? context.delete(model: RefChunk.self, where: #Predicate { $0.paperId == pid })
        try? context.delete(model: ChatTurn.self, where: #Predicate { $0.paperId == pid })
        context.delete(paper)
        try? context.save()
        try? FileManager.default.removeItem(at: dir(for: pid))
    }
}
