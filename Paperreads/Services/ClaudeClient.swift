import Foundation
import PDFKit

// Module B — raw HTTP client for the Anthropic Messages API (see docs/ARCHITECTURE.md §4).
//
// Design notes
// - Every request streams (SSE). The parser rebuilds each content block exactly as the API
//   produced it (text + citations, thinking + signature, redacted_thinking, and any unknown
//   block type copied verbatim from `content_block_start`), so assistant turns can be replayed
//   byte-for-byte in later requests. Nothing is stripped.
// - Request bodies are serialised with `ClaudeJSON`, a deterministic writer (sorted keys, fixed
//   escaping) that can splice pre-serialised JSON (`ClaudeRawJSON`) verbatim. That keeps the
//   frozen system prompt and stored history bytes identical across requests (prompt caching).
// - Cancelling the consuming Task (or dropping the stream) cancels the URLSession request.

// MARK: - Errors

struct ClaudeError: LocalizedError {
    /// HTTP status, when the failure came from a non-200 response.
    let status: Int?
    /// API error type (`overloaded_error`, `authentication_error`, …) or a local kind.
    let type: String?
    /// The API's error message, or a local description.
    let message: String

    init(status: Int? = nil, type: String? = nil, message: String) {
        self.status = status
        self.type = type
        self.message = message
    }

    var errorDescription: String? {
        let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let lead: String?
        switch (status, type) {
        case (401, _), (_, "authentication_error"):
            lead = "Claude rejected the API key. Check it in Settings."
        case (403, _), (_, "permission_error"):
            lead = "This API key doesn't have access to that model or feature."
        case (404, _), (_, "not_found_error"):
            lead = "The requested model wasn't found. Pick another model in Settings."
        case (413, _), (_, "request_too_large"):
            lead = "The request was too large for Claude."
        case (429, _), (_, "rate_limit_error"):
            lead = "Rate limited by the Claude API. Wait a moment and try again."
        case (529, _), (_, "overloaded_error"):
            lead = "Claude is overloaded right now. Try again shortly."
        case (_, "refusal"):
            lead = nil
        case (let s?, _) where s >= 500:
            lead = "The Claude API had a server error (\(s))."
        default:
            lead = nil
        }
        var parts: [String] = []
        if let lead { parts.append(lead) }
        if !detail.isEmpty, detail != lead { parts.append(detail) }
        if parts.isEmpty { parts.append("The Claude request failed.") }
        if let status, lead == nil, type != "refusal" { parts.append("(HTTP \(status))") }
        return parts.joined(separator: " ")
    }

    static let missingKey = ClaudeError(type: "missing_api_key",
                                        message: "Add your Anthropic API key in Settings (⌘,) to use Claude.")
    static let refusal = ClaudeError(type: "refusal",
                                     message: "Claude declined to respond to this request. Try rephrasing the question.")
}

// MARK: - Stream events

enum ClaudeStreamEvent {
    case textDelta(String)
    case thinking                       // a thinking block started (show "Thinking…")
    case done(contentJSON: Data, text: String, stopReason: String?)
}

// MARK: - Deterministic JSON

/// Pre-serialised JSON spliced verbatim into a `ClaudeJSON` output. Used for the frozen system
/// prompt and for stored conversation turns so their bytes never change between requests.
struct ClaudeRawJSON {
    let data: Data
}

/// Deterministic JSON writer: object keys sorted (byte order of UTF-8, same as `.sortedKeys`),
/// no whitespace, slashes unescaped, `ClaudeRawJSON` spliced as-is.
enum ClaudeJSON {
    struct EncodingError: LocalizedError {
        let description: String
        var errorDescription: String? { "Could not encode request: \(description)" }
    }

    static func data(_ value: Any) throws -> Data {
        var out = Data()
        try write(value, into: &out)
        return out
    }

    private static func write(_ value: Any, into out: inout Data) throws {
        switch value {
        case let raw as ClaudeRawJSON:
            out.append(raw.data)
        case let s as String:
            out.append(try fragment(s))
        case let dict as [String: Any]:
            out.append(UInt8(ascii: "{"))
            // Sort by UTF-8 bytes so ordering is locale independent and stable.
            let keys = dict.keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
            for (i, key) in keys.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                out.append(try fragment(key))
                out.append(UInt8(ascii: ":"))
                try write(dict[key]!, into: &out)
            }
            out.append(UInt8(ascii: "}"))
        case let array as [Any]:
            out.append(UInt8(ascii: "["))
            for (i, element) in array.enumerated() {
                if i > 0 { out.append(UInt8(ascii: ",")) }
                try write(element, into: &out)
            }
            out.append(UInt8(ascii: "]"))
        case is NSNull:
            out.append(contentsOf: Array("null".utf8))
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                out.append(contentsOf: Array((n.boolValue ? "true" : "false").utf8))
            } else {
                if let d = n as? Double, !d.isFinite {
                    throw EncodingError(description: "non-finite number")
                }
                out.append(try fragment(n))
            }
        default:
            throw EncodingError(description: "unsupported value of type \(type(of: value))")
        }
    }

    private static func fragment(_ value: Any) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: value,
                                              options: [.fragmentsAllowed, .withoutEscapingSlashes])
        } catch {
            throw EncodingError(description: error.localizedDescription)
        }
    }
}

// MARK: - SSE parsing

/// One server-sent event.
struct SSEEvent {
    var event: String?
    var data: String
}

/// Line-oriented SSE parser (fed LF-split lines by `consume`). Blank separator lines are not relied on,
/// so an event is dispatched when (a) a blank line arrives, (b) a new `event:`
/// field starts while data is pending, or (c) the accumulated `data:` payload is already a
/// complete JSON document. Multi-line `data:` fields are joined with "\n" per the SSE spec.
struct SSEParser {
    private var eventName: String?
    private var dataLines: [String] = []

    mutating func feed(_ rawLine: String) -> [SSEEvent] {
        var line = rawLine
        if line.hasSuffix("\r") { line.removeLast() }
        var emitted: [SSEEvent] = []

        if line.isEmpty {
            if let e = flush() { emitted.append(e) }
            return emitted
        }
        if line.hasPrefix(":") { return emitted }        // comment / keep-alive

        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = Substring(line)
            value = ""
        }

        switch field {
        case "event":
            if !dataLines.isEmpty, let e = flush() { emitted.append(e) }
            eventName = String(value)
        case "data":
            dataLines.append(String(value))
            if isCompleteJSON(dataLines.joined(separator: "\n")), let e = flush() {
                emitted.append(e)
            }
        default:
            break                                        // id:, retry:, unknown fields
        }
        return emitted
    }

    /// Dispatches anything still pending (call at end of stream).
    mutating func finish() -> SSEEvent? { flush() }

    private mutating func flush() -> SSEEvent? {
        defer { eventName = nil; dataLines.removeAll(keepingCapacity: true) }
        guard !dataLines.isEmpty || eventName != nil else { return nil }
        return SSEEvent(event: eventName, data: dataLines.joined(separator: "\n"))
    }

    private func isCompleteJSON(_ s: String) -> Bool {
        guard let first = s.first(where: { !$0.isWhitespace }), first == "{" || first == "[" else { return false }
        return (try? JSONSerialization.jsonObject(with: Data(s.utf8))) != nil
    }
}

// MARK: - Message reconstruction

/// Applies Messages-API stream events and rebuilds the final content-block array.
struct MessageAccumulator {
    enum Step {
        case none
        case text(String)
        case thinkingStarted
        case finished
    }

    private(set) var blocks: [Int: [String: Any]] = [:]
    private var partialJSON: [Int: String] = [:]
    private(set) var stopReason: String?
    private(set) var stopSequence: Any?
    private(set) var finished = false
    private(set) var sawMessageStart = false

    mutating func apply(_ event: SSEEvent) throws -> Step {
        let trimmed = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "[DONE]" { return .none }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any] else {
            // A payload that is not valid JSON means the event was corrupted in transit or framing;
            // dropping it would silently lose a delta (and break a thinking signature), so fail.
            if event.event == "ping" { return .none }
            throw ClaudeError(type: "stream_error",
                              message: event.event == "error"
                                ? String(trimmed.prefix(500))
                                : "Claude's response stream was malformed. Please try again.")
        }
        let type = (obj["type"] as? String) ?? event.event ?? ""

        switch type {
        case "ping":
            return .none

        case "error":
            let err = obj["error"] as? [String: Any]
            throw ClaudeError(type: err?["type"] as? String ?? "stream_error",
                              message: err?["message"] as? String ?? "The response stream reported an error.")

        case "message_start":
            sawMessageStart = true
            // Seed with any blocks the message already carries (normally none).
            if let msg = obj["message"] as? [String: Any], let content = msg["content"] as? [[String: Any]] {
                for (i, block) in content.enumerated() { blocks[i] = block }
            }
            return .none

        case "content_block_start":
            guard let index = intValue(obj["index"]),
                  let block = obj["content_block"] as? [String: Any] else { return .none }
            // Copied verbatim — this is how unknown block types survive unchanged.
            blocks[index] = block
            let blockType = block["type"] as? String
            if blockType == "thinking" || blockType == "redacted_thinking" { return .thinkingStarted }
            if blockType == "text", let t = block["text"] as? String, !t.isEmpty { return .text(t) }
            return .none

        case "content_block_delta":
            guard let index = intValue(obj["index"]),
                  let delta = obj["delta"] as? [String: Any] else { return .none }
            var block = blocks[index] ?? [:]
            var step: Step = .none
            switch delta["type"] as? String {
            case "text_delta":
                let t = delta["text"] as? String ?? ""
                block["text"] = ((block["text"] as? String) ?? "") + t
                if !t.isEmpty { step = .text(t) }
            case "thinking_delta":
                block["thinking"] = ((block["thinking"] as? String) ?? "") + (delta["thinking"] as? String ?? "")
            case "signature_delta":
                block["signature"] = ((block["signature"] as? String) ?? "") + (delta["signature"] as? String ?? "")
            case "citations_delta":
                var citations = (block["citations"] as? [Any]) ?? []
                if let c = delta["citation"] { citations.append(c) }
                block["citations"] = citations
            case "input_json_delta":
                partialJSON[index, default: ""] += delta["partial_json"] as? String ?? ""
            default:
                // Unknown delta: append string fields to matching string fields, set the rest.
                for (key, value) in delta where key != "type" {
                    if let s = value as? String, let existing = block[key] as? String {
                        block[key] = existing + s
                    } else {
                        block[key] = value
                    }
                }
            }
            blocks[index] = block
            return step

        case "content_block_stop":
            if let index = intValue(obj["index"]), let json = partialJSON.removeValue(forKey: index),
               !json.isEmpty, var block = blocks[index] {
                if let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed]) {
                    block["input"] = parsed
                }
                blocks[index] = block
            }
            return .none

        case "message_delta":
            if let delta = obj["delta"] as? [String: Any] {
                if let r = delta["stop_reason"] as? String { stopReason = r }
                if let s = delta["stop_sequence"], !(s is NSNull) { stopSequence = s }
            }
            return .none

        case "message_stop":
            finished = true
            return .finished

        default:
            return .none
        }
    }

    /// Content blocks in index order.
    var orderedBlocks: [[String: Any]] {
        blocks.keys.sorted().compactMap { blocks[$0] }
    }

    /// Concatenated text of all text blocks.
    var text: String {
        orderedBlocks.filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
    }

    private func intValue(_ any: Any?) -> Int? {
        if let n = any as? NSNumber { return n.intValue }
        return any as? Int
    }
}

// MARK: - Client

struct ClaudeClient {
    static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    static let apiVersion = "2026-10-21"
    static let betaHeader = "server-side-fallback-2026-07-01"
    static let userAgent = "Paperreads/0.1 (personal research reader)"

    /// The Messages API caps the whole request at 32 MB. The PDF travels as base64 (4/3 its size)
    /// next to the prompt, so the raw limit is what still fits after encoding plus 64 KB overhead
    /// (about 23.9 MB).
    static let maxRequestBytes = 32 * 1024 * 1024
    static let requestOverheadBytes = 64 * 1024
    static let maxPDFBytes = (maxRequestBytes - requestOverheadBytes) / 4 * 3

    static func base64Size(_ rawBytes: Int) -> Int { (rawBytes + 2) / 3 * 4 }
    static let maxPDFPages = 600

    /// Dedicated session: 600s idle timeout (long thinking pauses), no caching, no cookies.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 600
        config.timeoutIntervalForResource = 60 * 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["User-Agent": ClaudeClient.userAgent]
        return URLSession(configuration: config)
    }()

    /// Retries (before any bytes are streamed) for transient statuses.
    private static let retryableStatuses: Set<Int> = [408, 429, 500, 502, 503, 504, 529]
    private static let maxRetries = 2
    private static let maxErrorBodyBytes = 64 * 1024

    init() {}

    /// Streams one Messages request. `body` is the JSON object minus model/stream/fallbacks,
    /// which the client adds.
    func stream(body: [String: Any]) -> AsyncThrowingStream<ClaudeStreamEvent, Error> {
        let box = BodyBox(body: body)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await Self.run(body: box.body, continuation: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.normalize(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// PDF → Markdown conversion (document block, base64). effort low, max_tokens 64000.
    /// `isComplete` is false when the model stopped early (max_tokens or context window), so
    /// the caller never presents a cut-off conversion as the whole paper. Pass `pageCount`
    /// when the caller already parsed the PDF, to skip a second PDFKit parse.
    func convertPDF(pdfData: Data, pageCount: Int? = nil,
                    onProgress: @escaping @MainActor (Int) -> Void) async throws -> PDFConversion {
        guard !pdfData.isEmpty else {
            throw ClaudeError(type: "invalid_pdf", message: "The PDF is empty.")
        }
        guard Self.base64Size(pdfData.count) + Self.requestOverheadBytes <= Self.maxRequestBytes else {
            let mb = Double(pdfData.count) / 1_048_576
            let limit = Double(Self.maxPDFBytes) / 1_048_576
            throw ClaudeError(type: "pdf_too_large",
                              message: String(format: "This PDF is %.1f MB; at most %.1f MB can be sent to Claude (the 32 MB request limit includes base64 encoding).", mb, limit))
        }
        let pages: Int
        if let pageCount {
            pages = pageCount
        } else {
            guard let doc = PDFDocument(data: pdfData) else {
                throw ClaudeError(type: "invalid_pdf", message: "The file isn't a readable PDF.")
            }
            pages = doc.pageCount
        }
        if pages > Self.maxPDFPages {
            throw ClaudeError(type: "pdf_too_long",
                              message: "This PDF has \(pages) pages; Claude accepts up to \(Self.maxPDFPages).")
        }

        let body: [String: Any] = [
            "max_tokens": 64000,
            "output_config": ["effort": "low"],
            "messages": [[
                "role": "user",
                "content": [
                    [
                        "type": "document",
                        "source": [
                            "type": "base64",
                            "media_type": "application/pdf",
                            "data": pdfData.base64EncodedString(),
                        ],
                    ],
                    ["type": "text", "text": Self.pdfConversionPrompt],
                ],
            ]],
        ]

        var received = 0
        var lastReported = 0
        var lastReportTime = Date.distantPast
        await onProgress(0)
        for try await event in stream(body: body) {
            try Task.checkCancellation()
            switch event {
            case .textDelta(let t):
                received += t.count
                let now = Date()
                if received - lastReported >= 400 || now.timeIntervalSince(lastReportTime) >= 0.25 {
                    lastReported = received
                    lastReportTime = now
                    await onProgress(received)
                }
            case .thinking:
                break
            case .done(_, let text, let stopReason):
                if stopReason == "refusal" { throw ClaudeError.refusal }
                await onProgress(text.count)
                let complete = stopReason == nil || stopReason == "end_turn" || stopReason == "stop_sequence"
                let markdown = Self.unwrapMarkdown(text)
                guard !markdown.isEmpty || !complete else {
                    throw ClaudeError(type: "empty_conversion",
                                      message: "Claude returned no text for this PDF.")
                }
                return PDFConversion(markdown: markdown, stopReason: stopReason, isComplete: complete)
            }
        }
        throw ClaudeError(type: "stream_incomplete",
                          message: "The connection to Claude ended before the conversion finished.")
    }

    // MARK: Private

    private final class BodyBox: @unchecked Sendable {
        let body: [String: Any]
        init(body: [String: Any]) { self.body = body }
    }

    static let pdfConversionPrompt = """
    Convert this entire research paper to Markdown. Output only the Markdown — no preamble, no \
    commentary, no code fences around the whole document.

    Rules:
    - Start with the paper title as a single `# ` heading. Use `## ` for sections and `### ` for \
    subsections, keeping the paper's own numbering in the heading text.
    - Reproduce the full text faithfully, in reading order, without summarising or skipping \
    anything. Merge hyphenated line breaks and rejoin paragraphs split across columns or pages.
    - Write every equation as LaTeX: `$…$` for inline math and `$$…$$` on its own lines for \
    display math. Put equation numbers inside the display math as `\\tag{n}`.
    - Write tables as Markdown tables (keep the caption as a line directly above the table).
    - For each figure write `> **Figure n.** caption` where the figure appears; do not describe \
    images beyond their caption.
    - Omit running headers, footers, page numbers, and line numbers.
    - Keep the abstract under a `## Abstract` heading.
    - Keep the references section as a numbered list under `## References`, one entry per item, \
    in the original order.
    - Keep appendices, using the same heading rules.
    """

    private static func run(body: [String: Any],
                            continuation: AsyncThrowingStream<ClaudeStreamEvent, Error>.Continuation) async throws {
        let (apiKey, model) = await MainActor.run {
            (AppSettings.shared.effectiveAPIKey, AppSettings.shared.model)
        }
        guard let apiKey else { throw ClaudeError.missingKey }

        var full = body
        // Enforce the API contract regardless of what the caller passed.
        for forbidden in ["temperature", "top_p", "top_k", "thinking", "model", "stream", "fallbacks"] {
            full.removeValue(forKey: forbidden)
        }
        full["model"] = model
        full["stream"] = true
        full["fallbacks"] = "default"
        let bodyData = try ClaudeJSON.data(full)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 600
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue("text/event-stream", forHTTPHeaderField: "accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = bodyData

        var attempt = 0
        while true {
            try Task.checkCancellation()
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ClaudeError(type: "invalid_response", message: "Unexpected response from the Claude API.")
            }
            if http.statusCode == 200 {
                try await consume(bytes, continuation: continuation)
                return
            }
            let errorBody = await readLimited(bytes, limit: maxErrorBodyBytes)
            let error = apiError(status: http.statusCode, body: errorBody)
            if retryableStatuses.contains(http.statusCode), attempt < maxRetries {
                attempt += 1
                try await Task.sleep(nanoseconds: retryDelay(http, attempt: attempt))
                continue
            }
            throw error
        }
    }

    private static func consume(_ bytes: URLSession.AsyncBytes,
                                continuation: AsyncThrowingStream<ClaudeStreamEvent, Error>.Continuation) async throws {
        var parser = SSEParser()
        var acc = MessageAccumulator()

        func handle(_ event: SSEEvent) throws -> Bool {
            switch try acc.apply(event) {
            case .none:
                return false
            case .text(let t):
                continuation.yield(.textDelta(t))
                return false
            case .thinkingStarted:
                continuation.yield(.thinking)
                return false
            case .finished:
                return true
            }
        }

        // Split on LF only (stripping a trailing CR), as the SSE spec defines line terminators.
        // `AsyncBytes.lines` also breaks on U+0085/U+2028/U+2029, which JSON allows raw inside
        // strings, and would split (and silently corrupt) a delta that contains one.
        var finished = false
        var lineBuffer: [UInt8] = []
        lineBuffer.reserveCapacity(4096)
        byteLoop: for try await byte in bytes {
            guard byte == 0x0A else { lineBuffer.append(byte); continue }
            try Task.checkCancellation()
            if lineBuffer.last == 0x0D { lineBuffer.removeLast() }
            let line = String(decoding: lineBuffer, as: UTF8.self)
            lineBuffer.removeAll(keepingCapacity: true)
            for event in parser.feed(line) {
                if try handle(event) { finished = true; break byteLoop }
            }
        }
        if !finished, !lineBuffer.isEmpty {
            if lineBuffer.last == 0x0D { lineBuffer.removeLast() }
            for event in parser.feed(String(decoding: lineBuffer, as: UTF8.self)) {
                if try handle(event) { finished = true; break }
            }
        }
        if !finished, let tail = parser.finish() {
            finished = try handle(tail)
        }
        try Task.checkCancellation()

        guard finished || (acc.sawMessageStart && acc.stopReason != nil) else {
            throw ClaudeError(type: "stream_incomplete",
                              message: "The connection to Claude ended before the response finished.")
        }

        let content = try ClaudeJSON.data(acc.orderedBlocks)
        continuation.yield(.done(contentJSON: content, text: acc.text, stopReason: acc.stopReason))
    }

    private static func readLimited(_ bytes: URLSession.AsyncBytes, limit: Int) async -> Data {
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count >= limit { break }
            }
        } catch {}
        return data
    }

    private static func apiError(status: Int, body: Data) -> ClaudeError {
        if let obj = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
           let err = obj["error"] as? [String: Any] {
            return ClaudeError(status: status,
                               type: err["type"] as? String,
                               message: err["message"] as? String ?? "")
        }
        let text = String(decoding: body.prefix(500), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ClaudeError(status: status, type: nil,
                           message: text.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: status) : text)
    }

    private static func retryDelay(_ response: HTTPURLResponse, attempt: Int) -> UInt64 {
        var seconds = pow(2.0, Double(attempt - 1))           // 1s, 2s
        if let header = response.value(forHTTPHeaderField: "retry-after"),
           let value = Double(header.trimmingCharacters(in: .whitespaces)), value >= 0 {
            seconds = value
        }
        seconds = min(max(seconds, 0.5), 20)
        return UInt64(seconds * 1_000_000_000)
    }

    private static func normalize(_ error: Error) -> Error {
        if error is CancellationError { return error }
        if let url = error as? URLError {
            switch url.code {
            case .cancelled:
                return CancellationError()
            case .notConnectedToInternet, .networkConnectionLost:
                return ClaudeError(type: "network", message: "No connection to the Claude API. Check your network and try again.")
            case .timedOut:
                return ClaudeError(type: "timeout", message: "The Claude request timed out.")
            default:
                return ClaudeError(type: "network", message: url.localizedDescription)
            }
        }
        return error
    }

    /// Removes a single fence the model may have wrapped around the whole document.
    static func unwrapMarkdown(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            var lines = s.components(separatedBy: "\n")
            if lines.count >= 2, lines.last?.trimmingCharacters(in: .whitespaces) == "```" {
                lines.removeFirst()
                lines.removeLast()
                s = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            } else if lines.count >= 2, !lines.dropFirst().contains(where: { $0.hasPrefix("```") }) {
                // Opening fence of a whole-document block that was cut off before closing.
                lines.removeFirst()
                s = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return s
    }
}

/// Result of `ClaudeClient.convertPDF`.
struct PDFConversion: Sendable {
    let markdown: String
    let stopReason: String?
    /// False when Claude stopped before the end (e.g. `max_tokens`, `model_context_window_exceeded`).
    let isComplete: Bool
}
