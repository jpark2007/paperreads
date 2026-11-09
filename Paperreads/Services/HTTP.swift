import Foundation

// Module C — shared network layer.
//
// Every request made by the import pipeline goes through `HTTP.get`, which enforces:
//   • https only (including every redirect hop)
//   • a fixed User-Agent and a 30s request timeout
//   • a hard response-size cap enforced while the body streams in (the download is
//     cancelled the moment it crosses the cap; nothing unbounded is ever buffered)
//   • cooperative Task cancellation (cancelling the Swift Task cancels the URLSessionTask)

enum HTTPError: LocalizedError {
    case insecureURL(String)
    case insecureRedirect(String)
    case status(Int, URL)
    case tooLarge(limit: Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .insecureURL(let u):
            return "Refused to load a non-https address (\(HTTP.redacted(u)))."
        case .insecureRedirect(let u):
            return "The server redirected to a non-https address (\(HTTP.redacted(u)))."
        case .status(let code, let url):
            return "The server at \(url.host ?? "unknown host") answered with HTTP \(code)."
        case .tooLarge(let limit):
            return "The download exceeded the \(HTTP.formatBytes(limit)) size limit."
        case .invalidResponse:
            return "The server sent an invalid response."
        }
    }

    var statusCode: Int? {
        if case .status(let code, _) = self { return code }
        return nil
    }
}

enum HTTP {
    static let userAgent = "Paperreads/0.1 (personal research reader)"

    /// Response size caps (bytes).
    static let maxHTMLBytes = 25 * 1024 * 1024
    static let maxPDFBytes = 60 * 1024 * 1024
    static let maxJSONBytes = 16 * 1024 * 1024
    /// Body bytes kept from an error (non-2xx) response — enough for a diagnostic, no more.
    static let maxErrorBodyBytes = 64 * 1024

    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        config.httpAdditionalHeaders = ["User-Agent": userAgent]
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 4
        config.waitsForConnectivity = false
        config.tlsMinimumSupportedProtocolVersion = .TLSv12
        return URLSession(configuration: config)
    }()

    /// GET `url`, streaming the body and failing as soon as it exceeds `maxBytes`.
    /// Throws `HTTPError.status` for any non-2xx final response.
    static func get(_ url: URL, maxBytes: Int) async throws -> (Data, HTTPURLResponse) {
        try await get(url, maxBytes: maxBytes, headers: [:])
    }

    static func get(_ url: URL, maxBytes: Int, headers: [String: String]) async throws -> (Data, HTTPURLResponse) {
        try validate(url)
        precondition(maxBytes > 0, "maxBytes must be positive")
        try Task.checkCancellation()

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }

        let loader = CappedLoader(maxBytes: maxBytes)
        let task = session.dataTask(with: request)
        task.delegate = loader

        let (data, response) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, HTTPURLResponse), Error>) in
                loader.start(task, continuation: cont)
            }
        } onCancel: {
            task.cancel()
        }

        guard (200..<300).contains(response.statusCode) else {
            throw HTTPError.status(response.statusCode, response.url ?? url)
        }
        return (data, response)
    }

    /// Only absolute https URLs with a host and no embedded credentials are allowed.
    static func validate(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              isPublicHost(host)
        else { throw HTTPError.insecureURL(url.absoluteString) }
    }

    /// Rejects hosts that point into the user's machine or local network: `localhost`,
    /// mDNS `.local`, single-label names, and IP literals in loopback, private, link-local,
    /// CGNAT, multicast or reserved ranges. URLs from untrusted metadata (Semantic Scholar's
    /// openAccessPdf, redirect hops) must not reach internal services.
    static func isPublicHost(_ rawHost: String) -> Bool {
        var host = rawHost.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        while host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty else { return false }

        if host.contains(":") { return isPublicIPv6(host) }
        if let v4 = parseIPv4(host) { return isPublicIPv4(v4) }
        // All-numeric / hex hostnames are odd IPv4 spellings (e.g. 2130706433, 0x7f.1); refuse.
        // No real TLD is numeric, so a numeric/hex last label is always an IP spelling.
        if let last = host.split(separator: ".").last,
           last.allSatisfy({ $0.isASCII && $0.isNumber }) || last.hasPrefix("0x") {
            return false
        }
        if host == "localhost" || host.hasSuffix(".localhost") { return false }
        if host.hasSuffix(".local") || host.hasSuffix(".internal") || host.hasSuffix(".lan")
            || host.hasSuffix(".home.arpa") { return false }
        if !host.contains(".") { return false }       // single-label (intranet) names
        return true
    }

    private static func parseIPv4(_ s: String) -> [UInt8]? {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var out: [UInt8] = []
        for p in parts {
            guard !p.isEmpty, p.count <= 3, p.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let n = UInt8(p) else { return nil }
            out.append(n)
        }
        return out
    }

    private static func isPublicIPv4(_ a: [UInt8]) -> Bool {
        switch (a[0], a[1]) {
        case (0, _), (10, _), (127, _): return false
        case (100, 64...127): return false             // CGNAT
        case (169, 254): return false                  // link-local
        case (172, 16...31): return false
        case (192, 168): return false
        case (192, 0) where a[2] == 0 || a[2] == 2: return false
        case (198, 18...19): return false              // benchmarking
        case (198, 51) where a[2] == 100: return false
        case (203, 0) where a[2] == 113: return false
        default: break
        }
        return a[0] < 224                              // multicast / reserved
    }

    private static func isPublicIPv6(_ s: String) -> Bool {
        var addr = in6_addr()
        let ok = s.withCString { inet_pton(AF_INET6, $0, &addr) } == 1
        guard ok else { return false }
        let b = withUnsafeBytes(of: &addr) { Array($0) }
        if b.allSatisfy({ $0 == 0 }) { return false }                         // ::
        if b[0..<15].allSatisfy({ $0 == 0 }) && b[15] == 1 { return false }   // ::1
        if b[0] == 0xfe && (b[1] & 0xc0) == 0x80 { return false }             // fe80::/10
        if (b[0] & 0xfe) == 0xfc { return false }                             // fc00::/7
        if b[0] == 0xff { return false }                                      // multicast
        // IPv4-mapped / compatible (::ffff:a.b.c.d, ::a.b.c.d) and NAT64 well-known prefix.
        if b[0..<10].allSatisfy({ $0 == 0 }) && ((b[10] == 0xff && b[11] == 0xff) || (b[10] == 0 && b[11] == 0)) {
            return isPublicIPv4(Array(b[12..<16]))
        }
        if b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xff && b[3] == 0x9b {
            return isPublicIPv4(Array(b[12..<16]))
        }
        return true
    }

    static func isAllowed(_ url: URL?) -> Bool {
        guard let url else { return false }
        return (try? validate(url)) != nil
    }

    static func formatBytes(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }

    /// Scheme + host only, for error messages (never echo full untrusted URLs).
    static func redacted(_ s: String) -> String {
        guard let u = URL(string: s) else { return "invalid address" }
        return "\(u.scheme ?? "?")://\(u.host ?? "?")"
    }
}

/// Per-task delegate that accumulates a response body under a size cap and resumes a
/// continuation exactly once. URLSession delivers delegate callbacks on its serial
/// delegate queue; the lock additionally guards against the cancel path.
private final class CappedLoader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maxBytes: Int
    private let lock = NSLock()
    private var buffer = Data()
    private var response: HTTPURLResponse?
    private var continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>?
    private var pendingError: Error?
    private var isErrorResponse = false

    init(maxBytes: Int) { self.maxBytes = maxBytes }

    func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>) {
        lock.lock()
        self.continuation = continuation
        lock.unlock()
        task.resume()
    }

    private func finish(_ result: Result<(Data, HTTPURLResponse), Error>) {
        lock.lock()
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume(with: result)
    }

    private func abort(_ task: URLSessionTask, with error: Error) {
        lock.lock()
        if pendingError == nil { pendingError = error }
        lock.unlock()
        task.cancel()
    }

    // MARK: URLSessionTaskDelegate

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard HTTP.isAllowed(request.url) else {
            abort(task, with: HTTPError.insecureRedirect(request.url?.absoluteString ?? ""))
            completionHandler(nil)
            return
        }
        var next = request
        next.setValue(HTTP.userAgent, forHTTPHeaderField: "User-Agent")
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let pending = pendingError
        let resp = response
        let data = buffer
        buffer = Data()
        lock.unlock()

        if let pending {
            finish(.failure(pending))
        } else if let error {
            if (error as? URLError)?.code == .cancelled {
                finish(.failure(CancellationError()))
            } else {
                finish(.failure(error))
            }
        } else if let resp {
            finish(.success((data, resp)))
        } else {
            finish(.failure(HTTPError.invalidResponse))
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            abort(dataTask, with: HTTPError.invalidResponse)
            completionHandler(.cancel)
            return
        }
        if let final = http.url, !HTTP.isAllowed(final) {
            abort(dataTask, with: HTTPError.insecureRedirect(final.absoluteString))
            completionHandler(.cancel)
            return
        }
        let isError = !(200..<300).contains(http.statusCode)
        let cap = isError ? min(maxBytes, HTTP.maxErrorBodyBytes) : maxBytes
        if !isError, http.expectedContentLength > 0, http.expectedContentLength > Int64(maxBytes) {
            abort(dataTask, with: HTTPError.tooLarge(limit: maxBytes))
            completionHandler(.cancel)
            return
        }
        lock.lock()
        self.response = http
        self.isErrorResponse = isError
        if http.expectedContentLength > 0 {
            buffer.reserveCapacity(Int(min(http.expectedContentLength, Int64(cap))))
        }
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let isError = isErrorResponse
        let cap = isError ? min(maxBytes, HTTP.maxErrorBodyBytes) : maxBytes
        let remaining = cap - buffer.count
        if data.count <= remaining {
            buffer.append(data)
            lock.unlock()
            return
        }
        if isError {
            // Keep a truncated error body; stop downloading the rest.
            if remaining > 0 { buffer.append(data.prefix(remaining)) }
            let resp = response
            let kept = buffer
            buffer = Data()
            lock.unlock()
            if let resp {
                // Deliver the (truncated) error response now; the caller turns it into HTTPError.status.
                finish(.success((kept, resp)))
            }
            dataTask.cancel()
            return
        }
        lock.unlock()
        abort(dataTask, with: HTTPError.tooLarge(limit: maxBytes))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    willCacheResponse proposedResponse: CachedURLResponse,
                    completionHandler: @escaping (CachedURLResponse?) -> Void) {
        completionHandler(nil)
    }
}
