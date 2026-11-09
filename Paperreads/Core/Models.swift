import Foundation
import SwiftData

// CONTRACT FILE — shared by every module. Do not rename fields or types.
// Relationships are by `paperId` foreign key (no SwiftData relationships) to keep
// the store simple; `PaperStore.delete(_:in:)` removes dependents + files.

enum ReadingStatus: String, CaseIterable, Codable {
    case toRead, reading, done
    var label: String {
        switch self { case .toRead: "To read"; case .reading: "Reading"; case .done: "Done" }
    }
}

/// How the clean-text view was produced.
enum ContentKind: String, Codable {
    case none            // not yet available
    case arxivHTML       // arXiv / ar5iv LaTeXML HTML → cleaned
    case claudeMarkdown  // PDF → Claude → Markdown(+LaTeX) → cleaned
}

enum ImportState: String, Codable {
    case queued, fetching, converting, indexing, ready, failed
    var isBusy: Bool { self == .queued || self == .fetching || self == .converting || self == .indexing }
}

enum ReferencesState: String, Codable {
    case none, fetching, ready, failed, unavailable
}

@Model
final class Paper {
    @Attribute(.unique) var id: UUID
    var title: String
    var authors: [String]
    var year: Int?
    var arxivId: String?
    var doi: String?
    var s2PaperId: String?
    var abstractText: String
    var sourceURL: String?
    var addedAt: Date
    var lastOpenedAt: Date?
    var statusRaw: String
    var tags: [String]
    var paperNotes: String
    var contentKindRaw: String
    var importStateRaw: String
    var importStatusDetail: String?   // human-readable progress / error text
    var hasPDF: Bool
    var referencesStateRaw: String
    // Reading position (optional with defaults → SwiftData lightweight migration of old stores).
    /// data-b of the top-most visible block in the text view.
    var readingBlock: Int? = nil
    /// 0–1 progress through `readingBlock` (keeps the anchor across font-size changes).
    var readingBlockFraction: Double? = nil
    /// 0-based page index last shown in the PDF view.
    var pdfPageIndex: Int? = nil
    /// Last view mode the user chose for this paper: "text" | "pdf".
    var lastViewModeRaw: String? = nil

    init(title: String, sourceURL: String? = nil) {
        self.id = UUID()
        self.title = title
        self.authors = []
        self.year = nil
        self.abstractText = ""
        self.sourceURL = sourceURL
        self.addedAt = Date()
        self.statusRaw = ReadingStatus.toRead.rawValue
        self.tags = []
        self.paperNotes = ""
        self.contentKindRaw = ContentKind.none.rawValue
        self.importStateRaw = ImportState.queued.rawValue
        self.hasPDF = false
        self.referencesStateRaw = ReferencesState.none.rawValue
    }

    var status: ReadingStatus {
        get { ReadingStatus(rawValue: statusRaw) ?? .toRead }
        set { statusRaw = newValue.rawValue }
    }
    var contentKind: ContentKind {
        get { ContentKind(rawValue: contentKindRaw) ?? .none }
        set { contentKindRaw = newValue.rawValue }
    }
    var importState: ImportState {
        get { ImportState(rawValue: importStateRaw) ?? .failed }
        set { importStateRaw = newValue.rawValue }
    }
    var referencesState: ReferencesState {
        get { ReferencesState(rawValue: referencesStateRaw) ?? .none }
        set { referencesStateRaw = newValue.rawValue }
    }
    var authorLine: String {
        switch authors.count {
        case 0: return ""
        case 1...3: return authors.joined(separator: ", ")
        default: return "\(authors[0]) et al."
        }
    }
}

@Model
final class Highlight {
    @Attribute(.unique) var id: UUID
    var paperId: UUID
    var quote: String
    var blockIndex: Int      // data-b of the block containing the start of the quote
    var startOffset: Int     // char offset of quote within that block's textContent
    var note: String
    var createdAt: Date

    init(paperId: UUID, quote: String, blockIndex: Int, startOffset: Int, note: String = "") {
        self.id = UUID()
        self.paperId = paperId
        self.quote = quote
        self.blockIndex = blockIndex
        self.startOffset = startOffset
        self.note = note
        self.createdAt = Date()
    }
}

@Model
final class ReferenceEntry {
    @Attribute(.unique) var id: UUID
    var paperId: UUID
    var ordinal: Int          // 1-based; citation label is "r\(ordinal)"
    var title: String
    var authors: [String]
    var year: Int?
    var arxivId: String?
    var doi: String?
    var s2PaperId: String?
    var abstractText: String?
    var openAccessPDF: String?

    init(paperId: UUID, ordinal: Int, title: String) {
        self.id = UUID()
        self.paperId = paperId
        self.ordinal = ordinal
        self.title = title
        self.authors = []
    }
    var label: String { "r\(ordinal)" }
}

/// One retrievable chunk of a cited paper (abstract today; full text later).
@Model
final class RefChunk {
    @Attribute(.unique) var id: UUID
    var paperId: UUID         // the paper being read (owner of the reference list)
    var referenceId: UUID
    var label: String         // "r3"
    var text: String
    var embedding: Data       // [Float] packed little-endian; empty if unavailable

    init(paperId: UUID, referenceId: UUID, label: String, text: String, embedding: Data) {
        self.id = UUID()
        self.paperId = paperId
        self.referenceId = referenceId
        self.label = label
        self.text = text
        self.embedding = embedding
    }
}

/// One message in a paper's Q&A conversation. The conversation is APPEND-ONLY:
/// `contentJSON` holds the exact API content-block array (including thinking blocks
/// with signatures) and is replayed byte-for-byte on every later request.
@Model
final class ChatTurn {
    @Attribute(.unique) var id: UUID
    var paperId: UUID
    var conversationId: UUID  // "New chat" starts a fresh conversation id
    var seq: Int
    var role: String          // "user" | "assistant"
    var kind: String          // "ask" | "explain"
    var contentJSON: Data     // JSON array of content blocks sent to / received from the API
    var displayText: String   // what the UI shows (user's question / assistant's markdown)
    var createdAt: Date

    init(paperId: UUID, conversationId: UUID, seq: Int, role: String, kind: String, contentJSON: Data, displayText: String) {
        self.id = UUID()
        self.paperId = paperId
        self.conversationId = conversationId
        self.seq = seq
        self.role = role
        self.kind = kind
        self.contentJSON = contentJSON
        self.displayText = displayText
        self.createdAt = Date()
    }
}

/// Selection reported by the reader web view (see docs/ARCHITECTURE.md §JS bridge).
struct ReaderSelection: Codable, Equatable {
    var quote: String
    var blockIndex: Int
    var startOffset: Int
    var contextText: String   // full text of the containing block(s), math as $tex$
}

/// One clean-text block, persisted to blocks.json. `b` matches data-b in content.html.
struct ContentBlock: Codable, Equatable {
    var b: Int
    var section: String
    var text: String          // plain text, math as $tex$ / $$tex$$
}

/// Output of the ingest web processor.
struct IngestResult: Codable {
    var title: String
    var authors: [String]
    var abstract: String
    var html: String          // cleaned HTML with data-b attributes and .m math spans
    var blocks: [ContentBlock]
}

enum SchemaV1 {
    static let models: [any PersistentModel.Type] = [
        Paper.self, Highlight.self, ReferenceEntry.self, RefChunk.self, ChatTurn.self,
    ]
}
