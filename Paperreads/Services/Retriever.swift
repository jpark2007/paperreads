import Foundation
import NaturalLanguage
import SwiftData

// Module C — on-device embeddings and hybrid retrieval over cited-paper chunks.

enum Embedder {
    /// Characters of input embedded (the model is sentence-level).
    static let maxCharacters = 2000

    private static let lock = NSLock()
    private static var cached: NLEmbedding?
    private static var didLoad = false

    /// Loads (once) and returns the English sentence embedding; nil if the OS lacks it.
    /// NLEmbedding is not documented as thread-safe, so every use is serialised by `lock`.
    private static func withModel<T>(_ body: (NLEmbedding?) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        if !didLoad {
            cached = NLEmbedding.sentenceEmbedding(for: .english)
            didLoad = true
        }
        return body(cached)
    }

    static var isAvailable: Bool { withModel { $0 != nil } }

    /// On-device sentence embedding (NaturalLanguage NLEmbedding.sentenceEmbedding(.english)),
    /// L2-normalised, packed as little-endian Float32 Data. Returns empty Data if unavailable.
    static func embed(_ text: String) -> Data {
        let input = prepare(text)
        guard !input.isEmpty else { return Data() }
        let vector: [Double]? = withModel { $0?.vector(for: input) }
        guard let vector, !vector.isEmpty else { return Data() }
        return pack(normalize(vector))
    }

    /// Embeds many texts off the main actor. Output is index-aligned with `texts`.
    static func embedBatch(_ texts: [String]) async -> [Data] {
        let work = Task.detached(priority: .utility) {
            var out: [Data] = []
            out.reserveCapacity(texts.count)
            for t in texts {
                if Task.isCancelled { out.append(Data()); continue }
                out.append(embed(t))
            }
            return out
        }
        // Awaiting a detached task's value does not forward cancellation; do it explicitly.
        return await withTaskCancellationHandler {
            await work.value
        } onCancel: {
            work.cancel()
        }
    }

    // MARK: Packing

    static func prepare(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(collapsed.prefix(maxCharacters))
    }

    static func normalize(_ v: [Double]) -> [Float] {
        let norm = v.reduce(0) { $0 + $1 * $1 }.squareRoot()
        guard norm > 0, norm.isFinite else { return v.map { _ in 0 } }
        return v.map { Float($0 / norm) }
    }

    static func pack(_ v: [Float]) -> Data {
        var data = Data(capacity: v.count * 4)
        for f in v {
            var le = f.bitPattern.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func unpack(_ data: Data) -> [Float] {
        guard !data.isEmpty, data.count % 4 == 0 else { return [] }
        let n = data.count / 4
        return data.withUnsafeBytes { raw -> [Float] in
            (0..<n).map { i in
                Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self)))
            }
        }
    }
}

struct RetrievedChunk {
    let label: String
    let title: String
    let text: String
    let score: Double
}

enum Retriever {
    static let rrfK = 60.0
    private static let bm25K1 = 1.2
    private static let bm25B = 0.75

    /// Hybrid: cosine over embeddings + BM25 over RefChunk.text, fused with reciprocal rank
    /// fusion (k=60). Only chunks where chunk.paperId == paperId. `title` from ReferenceEntry.
    @MainActor
    static func search(paperId: UUID, query: String, k: Int, context: ModelContext) -> [RetrievedChunk] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard k > 0, !q.isEmpty else { return [] }

        let pid = paperId
        let chunks = (try? context.fetch(FetchDescriptor<RefChunk>(predicate: #Predicate { $0.paperId == pid }))) ?? []
        guard !chunks.isEmpty else { return [] }
        let refs = (try? context.fetch(FetchDescriptor<ReferenceEntry>(predicate: #Predicate { $0.paperId == pid }))) ?? []
        var titleByRef: [UUID: String] = [:]
        for r in refs { titleByRef[r.id] = r.title }

        // Dense ranking.
        var denseRank: [Int: Int] = [:]
        let qv = Embedder.unpack(Embedder.embed(q))
        if !qv.isEmpty {
            var scored: [(Int, Float)] = []
            for (i, c) in chunks.enumerated() {
                let v = Embedder.unpack(c.embedding)
                guard v.count == qv.count else { continue }
                var dot: Float = 0
                for j in 0..<v.count { dot += v[j] * qv[j] }
                if dot.isFinite { scored.append((i, dot)) }
            }
            scored.sort { $0.1 > $1.1 }
            for (rank, item) in scored.enumerated() { denseRank[item.0] = rank + 1 }
        }

        // Sparse (BM25) ranking.
        var sparseRank: [Int: Int] = [:]
        let qTerms = Set(tokenize(q))
        if !qTerms.isEmpty {
            let docs = chunks.map { tokenize($0.text) }
            let n = Double(docs.count)
            let avgLen = max(1, Double(docs.reduce(0) { $0 + $1.count }) / n)
            var df: [String: Int] = [:]
            for d in docs { for t in Set(d) where qTerms.contains(t) { df[t, default: 0] += 1 } }
            var scored: [(Int, Double)] = []
            for (i, d) in docs.enumerated() {
                var tf: [String: Int] = [:]
                for t in d where qTerms.contains(t) { tf[t, default: 0] += 1 }
                guard !tf.isEmpty else { continue }
                let len = Double(d.count)
                var s = 0.0
                for (t, f) in tf {
                    let dft = Double(df[t] ?? 0)
                    let idf = log(1 + (n - dft + 0.5) / (dft + 0.5))
                    let ff = Double(f)
                    s += idf * (ff * (bm25K1 + 1)) / (ff + bm25K1 * (1 - bm25B + bm25B * len / avgLen))
                }
                if s > 0 { scored.append((i, s)) }
            }
            scored.sort { $0.1 > $1.1 }
            for (rank, item) in scored.enumerated() { sparseRank[item.0] = rank + 1 }
        }

        // Reciprocal rank fusion.
        var fused: [Int: Double] = [:]
        for (i, r) in denseRank { fused[i, default: 0] += 1 / (rrfK + Double(r)) }
        for (i, r) in sparseRank { fused[i, default: 0] += 1 / (rrfK + Double(r)) }

        let top = fused.sorted { a, b in
            a.value != b.value ? a.value > b.value : a.key < b.key
        }.prefix(k)

        return top.map { (i, score) in
            let c = chunks[i]
            return RetrievedChunk(label: c.label,
                                  title: titleByRef[c.referenceId] ?? "",
                                  text: c.text,
                                  score: score)
        }
    }

    // MARK: Tokenisation

    private static let stopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "has", "have", "how",
        "in", "is", "it", "its", "of", "on", "or", "that", "the", "this", "to", "was", "we",
        "were", "what", "when", "where", "which", "who", "why", "with", "does", "do", "can",
        "our", "their", "these", "those", "into", "than", "then", "there", "they", "about",
    ]

    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        func flush() {
            if current.count > 1, !stopwords.contains(current) { tokens.append(current) }
            current = ""
        }
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber { current.append(ch) } else { flush() }
        }
        flush()
        return tokens
    }
}
