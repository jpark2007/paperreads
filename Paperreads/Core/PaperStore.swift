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
    static func htmlURL(_ id: UUID) -> URL { dir(for: id).appendingPathComponent("content.html") }
    static func blocksURL(_ id: UUID) -> URL { dir(for: id).appendingPathComponent("blocks.json") }
    static func markdownURL(_ id: UUID) -> URL { dir(for: id).appendingPathComponent("source.md") }

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
