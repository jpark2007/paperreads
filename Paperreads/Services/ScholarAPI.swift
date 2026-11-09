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
