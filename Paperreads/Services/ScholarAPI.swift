import Foundation

// Module C — thin async client for the Semantic Scholar Graph API.
// Unauthenticated: requests are spaced out by a shared throttle and HTTP 429 responses
// are retried with exponential backoff (1s, 2s, 4s; at most 3 retries).

struct S2Author: Codable, Equatable {
    var authorId: String?
    var name: String?
}

struct S2ExternalIds: Codable, Equatable {
    var arXiv: String?
    var doi: String?

    enum CodingKeys: String, CodingKey {
        case arXiv = "ArXiv"
        case doi = "DOI"
    }

    init(arXiv: String? = nil, doi: String? = nil) {
        self.arXiv = arXiv
        self.doi = doi
    }

    // The externalIds object mixes strings and integers (CorpusId); decode only what we
    // need and tolerate unexpected value types.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        arXiv = (try? c.decodeIfPresent(String.self, forKey: .arXiv)) ?? nil
        doi = (try? c.decodeIfPresent(String.self, forKey: .doi)) ?? nil
    }
}

struct S2OpenAccessPDF: Codable, Equatable {
    var url: String?
    var status: String?
}

struct S2Paper: Codable, Equatable {
    var paperId: String?
    var title: String?
    var authors: [S2Author]?
    var year: Int?
    var abstract: String?
    var externalIds: S2ExternalIds?
    var openAccessPdf: S2OpenAccessPDF?

    var authorNames: [String] {
        (authors ?? []).compactMap { $0.name?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    var cleanTitle: String? {
        guard let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    var cleanAbstract: String? {
        guard let a = abstract?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty else { return nil }
        return a
    }

    /// Open-access PDF URL upgraded to https (nil if absent or unusable).
    var openAccessPDFURL: URL? {
        guard let raw = openAccessPdf?.url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, var comps = URLComponents(string: raw) else { return nil }
        if comps.scheme?.lowercased() == "http" { comps.scheme = "https" }
        guard let url = comps.url, HTTP.isAllowed(url) else { return nil }
        return url
    }
}

struct S2Reference: Codable {
    var citedPaper: S2Paper?
}

struct S2ReferencePage: Codable {
    var offset: Int?
    var next: Int?
    var data: [S2Reference]?
}

struct S2MatchResult: Codable {
    var paperId: String?
    var title: String?
    var matchScore: Double?
}

struct S2MatchPage: Codable {
    var data: [S2MatchResult]?
}

struct S2PaperMatchPage: Codable {
    var data: [S2Paper]?
}

enum ScholarError: LocalizedError {
    case notFound
    case rateLimited
    case invalidIdentifier
    case decoding

    var errorDescription: String? {
        switch self {
        case .notFound: return "Semantic Scholar has no record of this paper."
        case .rateLimited: return "Semantic Scholar is rate-limiting requests. Try again in a minute."
        case .invalidIdentifier: return "Invalid paper identifier."
        case .decoding: return "Semantic Scholar returned data in an unexpected format."
        }
    }
}

/// Spaces Semantic Scholar requests so the shared unauthenticated quota is not hammered.
private actor ScholarThrottle {
    static let shared = ScholarThrottle()
    private let minimumSpacing: Duration = .milliseconds(1100)
    private var nextSlot: ContinuousClock.Instant = .now

    func waitForTurn() async throws {
        let clock = ContinuousClock()
        let now = clock.now
        let slot = max(now, nextSlot)
        nextSlot = slot + minimumSpacing
        if slot > now { try await clock.sleep(until: slot, tolerance: .milliseconds(50)) }
    }
}

enum ScholarAPI {
    static let base = "https://api.semanticscholar.org/graph/v1"
    static let paperFields = "title,authors,year,abstract,externalIds,openAccessPdf"
    static let maxRetries = 3

    // MARK: Identifiers

    /// "DOI:10.1234/abc"
    static func doiID(_ doi: String) -> String { "DOI:\(doi)" }
    /// "arXiv:2401.12345" (version suffix stripped — S2 indexes the base id).
    static func arxivID(_ id: String) -> String { "arXiv:\(ArxivID.stripVersion(id))" }

    // MARK: Endpoints

    /// GET /paper/{id}?fields=…  Throws `ScholarError.notFound` on 404.
    static func paper(_ identifier: String) async throws -> S2Paper {
        let url = try makeURL(path: "/paper/\(try encodeID(identifier))",
                              query: [URLQueryItem(name: "fields", value: paperFields)])
        let data = try await request(url)
        return try decode(S2Paper.self, from: data)
    }

    /// GET /paper/{id}/references?fields=…&limit=500. Returns cited papers in API order.
    static func references(of identifier: String, limit: Int = 500) async throws -> [S2Paper] {
        let url = try makeURL(path: "/paper/\(try encodeID(identifier))/references",
                              query: [URLQueryItem(name: "fields", value: paperFields),
                                      URLQueryItem(name: "limit", value: String(max(1, min(limit, 1000))))])
        let data = try await request(url)
        let page = try decode(S2ReferencePage.self, from: data)
        return (page.data ?? []).compactMap(\.citedPaper)
    }

    /// GET /paper/search/match?query={title}. Returns nil when S2 has no match.
    static func match(title: String) async throws -> S2MatchResult? {
        let q = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        let url = try makeURL(path: "/paper/search/match",
                              query: [URLQueryItem(name: "query", value: String(q.prefix(300))),
                                      URLQueryItem(name: "fields", value: "title")])
        do {
            let data = try await request(url)
            let page = try decode(S2MatchPage.self, from: data)
            return page.data?.first(where: { ($0.paperId ?? "").isEmpty == false })
        } catch ScholarError.notFound {
            return nil
        }
    }

    /// GET /paper/search/match?query={title} with the full paper fields (externalIds etc.).
    /// Returns nil when S2 has no match. The caller must still compare titles: the endpoint
    /// always returns its best guess.
    static func matchPaper(title: String) async throws -> S2Paper? {
        let q = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        let url = try makeURL(path: "/paper/search/match",
                              query: [URLQueryItem(name: "query", value: String(q.prefix(300))),
                                      URLQueryItem(name: "fields", value: paperFields)])
        do {
            let data = try await request(url)
            let page = try decode(S2PaperMatchPage.self, from: data)
            return page.data?.first(where: { ($0.paperId ?? "").isEmpty == false })
        } catch ScholarError.notFound {
            return nil
        }
    }

    // MARK: Plumbing

    private static func encodeID(_ identifier: String) throws -> String {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 400,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || $0 == " " })
        else { throw ScholarError.invalidIdentifier }
        // Slashes are meaningful inside DOIs / old-style arXiv ids and S2 accepts them raw.
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#%;")
        guard let enc = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) else {
            throw ScholarError.invalidIdentifier
        }
        return enc
    }

    private static func makeURL(path: String, query: [URLQueryItem]) throws -> URL {
        guard var comps = URLComponents(string: base) else { throw HTTPError.invalidResponse }
        comps.percentEncodedPath += path
        comps.queryItems = query
        guard let url = comps.url else { throw ScholarError.invalidIdentifier }
        return url
    }

    private static func request(_ url: URL) async throws -> Data {
        var attempt = 0
        while true {
            try await ScholarThrottle.shared.waitForTurn()
            do {
                let (data, _) = try await HTTP.get(url, maxBytes: HTTP.maxJSONBytes,
                                                   headers: ["Accept": "application/json"])
                return data
            } catch let error as HTTPError {
                switch error.statusCode {
                case 404?:
                    throw ScholarError.notFound
                case 429?:
                    guard attempt < maxRetries else { throw ScholarError.rateLimited }
                    let delay = Duration.seconds(1 << attempt)   // 1s, 2s, 4s
                    attempt += 1
                    try await Task.sleep(for: delay)
                default:
                    throw error
                }
            }
        }
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw ScholarError.decoding }
    }
}


// MARK: - arXiv API

/// One entry of the arXiv Atom API (`export.arxiv.org/api/query`).
struct ArxivEntry: Equatable, Sendable {
    /// Versioned id, e.g. "2511.18397v1" or "hep-th/9901001v2".
    var id: String
    var title: String
    var authors: [String]
    var year: Int?
    var summary: String
    var doi: String?
}

/// Thin client for the arXiv query API, used to identify dropped PDFs by title and to fill
/// metadata when Semantic Scholar is unavailable. arXiv asks clients to leave 3 s between calls.
enum ArxivAPI {
    static let base = "https://export.arxiv.org/api/query"

    /// Title search: an exact phrase query first, then (if that finds nothing) all title words.
    static func search(title: String, maxResults: Int = 3) async throws -> [ArxivEntry] {
        let words = TitleMatch.words(title).filter { $0.count > 1 || $0.first?.isNumber == true }
        guard words.count >= 2 else { return [] }
        let limited = Array(words.prefix(24))
        let phrase = "ti:\"" + limited.joined(separator: " ") + "\""
        let hits = try await query(phrase, maxResults: maxResults)
        if !hits.isEmpty { return hits }
        // Stop words and punctuation can defeat a phrase query; fall back to an AND of the
        // longest distinctive words.
        let distinctive = Array(Set(limited.filter { $0.count >= 4 })).sorted { $0.count > $1.count }.prefix(10)
        guard distinctive.count >= 2 else { return [] }
        return try await query(distinctive.map { "ti:\($0)" }.joined(separator: " AND "), maxResults: maxResults)
    }

    /// Metadata for one id (version optional). Nil if arXiv has no such paper.
    static func entry(id: String) async throws -> ArxivEntry? {
        guard ArxivID.isValid(id) else { return nil }
        guard var comps = URLComponents(string: base) else { return nil }
        comps.queryItems = [URLQueryItem(name: "id_list", value: id),
                            URLQueryItem(name: "max_results", value: "1")]
        guard let url = comps.url else { return nil }
        let entries = try await fetch(url)
        let wanted = ArxivID.stripVersion(id)
        return entries.first { ArxivID.stripVersion($0.id) == wanted }
    }

    private static func query(_ searchQuery: String, maxResults: Int) async throws -> [ArxivEntry] {
        guard var comps = URLComponents(string: base) else { return [] }
        comps.queryItems = [URLQueryItem(name: "search_query", value: searchQuery),
                            URLQueryItem(name: "start", value: "0"),
                            URLQueryItem(name: "max_results", value: String(max(1, min(maxResults, 10))))]
        // URLComponents leaves "+" unescaped, which arXiv would read as a space; ids and words
        // never contain one, but be strict anyway.
        comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        guard let url = comps.url else { return [] }
        return try await fetch(url)
    }

    private static func fetch(_ url: URL) async throws -> [ArxivEntry] {
        try await ArxivThrottle.shared.waitForTurn()
        let (data, _) = try await HTTP.get(url, maxBytes: HTTP.maxJSONBytes,
                                           headers: ["Accept": "application/atom+xml"])
        return parse(data)
    }

    /// Parses an Atom feed. Entries without a valid arXiv id (e.g. the API's error entry) are dropped.
    static func parse(_ data: Data) -> [ArxivEntry] {
        let delegate = ArxivAtomParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        _ = parser.parse()
        return delegate.entries
    }
}

/// Spaces arXiv API requests (arXiv's terms ask for one request every 3 seconds).
private actor ArxivThrottle {
    static let shared = ArxivThrottle()
    private let minimumSpacing: Duration = .seconds(3)
    private var nextSlot: ContinuousClock.Instant = .now

    func waitForTurn() async throws {
        let clock = ContinuousClock()
        let now = clock.now
        let slot = max(now, nextSlot)
        nextSlot = slot + minimumSpacing
        if slot > now { try await clock.sleep(until: slot, tolerance: .milliseconds(100)) }
    }
}

private final class ArxivAtomParser: NSObject, XMLParserDelegate {
    private static let atom = "http://www.w3.org/2005/Atom"
    private static let arxivNS = "http://arxiv.org/schemas/atom"

    private(set) var entries: [ArxivEntry] = []
    private var inEntry = false
    private var inAuthor = false
    private var text = ""
    private var id = "", title = "", summary = "", published = "", doi = ""
    private var authors: [String] = []
    private var authorName = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        switch (namespaceURI, elementName) {
        case (Self.atom?, "entry"):
            inEntry = true
            id = ""; title = ""; summary = ""; published = ""; doi = ""; authors = []
        case (Self.atom?, "author") where inEntry:
            inAuthor = true
            authorName = ""
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inEntry, text.utf16.count < 200_000 { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        guard inEntry else { return }
        let value = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        switch (namespaceURI, elementName) {
        case (Self.atom?, "id"): id = value
        case (Self.atom?, "title"): title = value
        case (Self.atom?, "summary"): summary = value
        case (Self.atom?, "published"): published = value
        case (Self.atom?, "name") where inAuthor: authorName = value
        case (Self.atom?, "author"):
            if !authorName.isEmpty { authors.append(authorName) }
            inAuthor = false
        case (Self.arxivNS?, "doi"): doi = value
        case (Self.atom?, "entry"):
            inEntry = false
            if let parsed = Self.arxivID(fromAbsURL: id), !title.isEmpty {
                let year = Int(published.prefix(4)).flatMap { (1900...2200).contains($0) ? $0 : nil }
                entries.append(ArxivEntry(id: parsed, title: title, authors: authors, year: year,
                                          summary: summary, doi: doi.isEmpty ? nil : DOIParser.normalize(doi)))
            }
        default:
            break
        }
        text = ""
    }

    /// "http://arxiv.org/abs/2511.18397v1" → "2511.18397v1".
    private static func arxivID(fromAbsURL s: String) -> String? {
        guard let r = s.range(of: "/abs/") else { return nil }
        let rest = String(s[r.upperBound...])
        return ArxivID.fromPathRemainder(rest)
    }
}
