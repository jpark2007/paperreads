// ingest-check — regression harness for Paperreads' arXiv HTML ingest (Web/ingest.js).
//
// Loads the app's real Web/ingest.html in an offscreen WKWebView, feeds it arXiv / ar5iv
// LaTeXML HTML, runs `Ingest.fromArxivHTML`, and measures COVERAGE: for every source
// paragraph (.ltx_p, .ltx_para without .ltx_p), figcaption, table cell, footnote, bibliography
// item, heading, list item and listing line with >= 6 words of non-math text, it checks that the
// word sequence appears in the text of the tagged output blocks.
//
// Usage:
//   ingest-check --web <Paperreads/Web> --cache <dir> [options] <arxiv-id | file.html>...
// Options:
//   --min <0..1>        fail (exit 1) when any paper's coverage is below this (default 0.98)
//   --missing <n>       print at most n missing snippets per paper (default 25; 0 = none)
//   --dump <dir>        write <id>.html (ingest output) and <id>.blocks.json there
//   --json <file>       write the full machine-readable report
//   --render <dir>      also load reader.html with the result and write PNG snapshots
//   --shots <n>         evenly spaced snapshots when rendering (default 4)
//   --focus <css>       when rendering, also snapshot the first --focus-count matches of <css>
//   --focus-count <n>   (default 3)
//   --base <url>        base URL for a local .html input (default https://arxiv.org/html/<name>)
//   --refetch           ignore the cache for arXiv ids
//
// Never launches a visible app: NSApplication runs with the .prohibited activation policy and
// the web views live in a borderless, never-ordered-in window.

import AppKit
import WebKit

// MARK: - Arguments

struct Options {
    var web: URL?
    var cache: URL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("ingest-cache")
    var minCoverage = 0.98
    var maxMissing = 25
    var dump: URL?
    var json: URL?
    var render: URL?
    var shots = 4
    var focus: String?
    var focusCount = 3
    var base: String?
    var refetch = false
    var inputs: [String] = []
}

func usage(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("ingest-check: \(msg)\n".utf8))
    exit(2)
}

func parseOptions() -> Options {
    var o = Options()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    func value(_ flag: String) -> String {
        guard let v = it.next() else { usage("\(flag) needs a value") }
        return v
    }
    while let a = it.next() {
        switch a {
        case "--web": o.web = URL(fileURLWithPath: value(a))
        case "--cache": o.cache = URL(fileURLWithPath: value(a))
        case "--min": o.minCoverage = Double(value(a)) ?? o.minCoverage
        case "--missing": o.maxMissing = Int(value(a)) ?? o.maxMissing
        case "--dump": o.dump = URL(fileURLWithPath: value(a))
        case "--json": o.json = URL(fileURLWithPath: value(a))
        case "--render": o.render = URL(fileURLWithPath: value(a))
        case "--shots": o.shots = max(0, Int(value(a)) ?? o.shots)
        case "--focus": o.focus = value(a)
        case "--focus-count": o.focusCount = max(0, Int(value(a)) ?? o.focusCount)
        case "--base": o.base = value(a)
        case "--refetch": o.refetch = true
        case "-h", "--help": usage("see the header of tools/ingest-check/main.swift")
        default:
            if a.hasPrefix("--") { usage("unknown option \(a)") }
            o.inputs.append(a)
        }
    }
    guard let web = o.web else { usage("--web <Paperreads/Web> is required") }
    guard FileManager.default.fileExists(atPath: web.appendingPathComponent("ingest.html").path) else {
        usage("no ingest.html in \(web.path)")
    }
    if o.inputs.isEmpty { usage("give at least one arXiv id or .html file") }
    return o
}

// MARK: - Fetching (cached)

struct Source {
    let name: String       // id or file stem, used for file names
    let html: String
    let baseURL: String
    let origin: String     // where it came from (for the report)
}

enum FetchError: Error, CustomStringConvertible {
    case noHTML(String)
    var description: String {
        switch self { case .noHTML(let s): return s }
    }
}

func safeName(_ s: String) -> String {
    String(s.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? $0 : "_" })
}

func fetch(_ url: URL) async throws -> (String, URL) {
    var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
    req.setValue("Paperreads-ingest-check/0.1 (regression harness; cached, a few requests per run)", forHTTPHeaderField: "User-Agent")
    let (data, resp) = try await URLSession.shared.data(for: req)
    guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
        throw FetchError.noHTML("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1) for \(url.absoluteString)")
    }
    let text = String(decoding: data, as: UTF8.self)
    return (text, http.url ?? url)
}

func loadSource(_ input: String, _ o: Options) async throws -> Source {
    let fm = FileManager.default
    if input.hasSuffix(".html") || input.hasSuffix(".htm") || fm.fileExists(atPath: input) {
        let url = URL(fileURLWithPath: input)
        let html = try String(contentsOf: url, encoding: .utf8)
        let stem = url.deletingPathExtension().lastPathComponent
        return Source(name: safeName(stem), html: html,
                      baseURL: o.base ?? "https://arxiv.org/html/\(stem)", origin: url.path)
    }
    try fm.createDirectory(at: o.cache, withIntermediateDirectories: true)
    let name = safeName(input)
    let htmlFile = o.cache.appendingPathComponent("\(name).html")
    let urlFile = o.cache.appendingPathComponent("\(name).url")
    if !o.refetch, let html = try? String(contentsOf: htmlFile, encoding: .utf8),
       let base = try? String(contentsOf: urlFile, encoding: .utf8) {
        return Source(name: name, html: html, baseURL: base.trimmingCharacters(in: .whitespacesAndNewlines),
                      origin: "cache:\(base.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    var errors: [String] = []
    for candidate in ["https://arxiv.org/html/\(input)", "https://ar5iv.labs.arxiv.org/html/\(input)"] {
        guard let url = URL(string: candidate) else { continue }
        do {
            let (html, final) = try await fetch(url)
            guard html.contains("ltx_document") else {
                errors.append("\(candidate): no ltx_document")
                continue
            }
            try html.write(to: htmlFile, atomically: true, encoding: .utf8)
            try final.absoluteString.write(to: urlFile, atomically: true, encoding: .utf8)
            return Source(name: name, html: html, baseURL: final.absoluteString, origin: final.absoluteString)
        } catch {
            errors.append("\(candidate): \(error)")
        }
    }
    throw FetchError.noHTML("no LaTeXML HTML for \(input) (\(errors.joined(separator: "; ")))")
}

// MARK: - Web views

final class NavDelegate: NSObject, WKNavigationDelegate {
    var continuation: CheckedContinuation<Void, Error>?
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) { continuation?.resume(); continuation = nil }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { continuation?.resume(throwing: e); continuation = nil }
    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
        continuation?.resume(throwing: e); continuation = nil
    }
}

final class Sink: NSObject, WKScriptMessageHandler {
    func userContentController(_ u: WKUserContentController, didReceive m: WKScriptMessage) {}
}

@MainActor
final class Page {
    let view: WKWebView
    let window: NSWindow
    let nav = NavDelegate()

    init(handlers: [String], size: NSSize) {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        let ucc = WKUserContentController()
        handlers.forEach { ucc.add(Sink(), name: $0) }
        cfg.userContentController = ucc
        view = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: cfg)
        window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.navigationDelegate = nav
    }

    func load(file: URL, readAccess: URL) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            nav.continuation = c
            view.loadFileURL(file, allowingReadAccessTo: readAccess)
        }
    }

    func call(_ js: String, _ args: [String: Any] = [:]) async throws -> Any? {
        try await view.callAsyncJavaScript(js, arguments: args, in: nil, contentWorld: .page)
    }

    func snapshot(to url: URL) async throws {
        let img = try await view.takeSnapshot(configuration: nil)
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try png.write(to: url)
    }
}

// MARK: - Coverage measurement (runs inside the ingest page)

let measureJS = #"""
const SRC_DROP = 'math, annotation, annotation-xml, script, style, svg, .ltx_note, ' +
  'table.ltx_equation, table.ltx_equationgroup, table.ltx_eqn_table, .ltx_eqn_table, .ltx_equationgroup, .ltx_tag_equation, .ltx_eqn_eqno';
const SKIP_ANCESTORS = '.ltx_page_header, .ltx_page_footer, .ltx_page_navbar, nav, header, footer, ' +
  '.ltx_title_document, .ltx_authors, .ltx_dates, .ltx_TOC, .package-alerts, .ltx_ERROR, .ltx_rdf, ' +
  '.ltx_role_affiliation, .ltx_role_email, .ltx_role_address';
function norm(s) {
  return String(s || '').normalize('NFKC').toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, ' ').trim();
}
function srcText(el) {
  const c = el.cloneNode(true);
  c.querySelectorAll(SRC_DROP).forEach((n) => n.remove());
  return norm(c.textContent);
}
const src = new DOMParser().parseFromString(srcHTML, 'text/html');
const root = src.querySelector('article.ltx_document') || src.querySelector('.ltx_document') || src.body;
const kinds = [
  ['abstract', '.ltx_abstract .ltx_p'],
  ['para', '.ltx_p'],
  ['para', '.ltx_para'],
  ['caption', 'figcaption, .ltx_caption'],
  ['cell', 'td, th'],
  ['footnote', '.ltx_note_content'],
  ['bib', '.ltx_bibitem'],
  ['heading', 'h1, h2, h3, h4, h5, h6'],
  ['item', 'li, dt, dd'],
  ['line', '.ltx_listingline, .ltx_listing_line'],
];
const seen = new Set();
const cands = [];
kinds.forEach(([kind, sel]) => {
  root.querySelectorAll(sel).forEach((el) => {
    if (seen.has(el)) return;
    if (el.closest(SKIP_ANCESTORS)) return;
    if (kind === 'para' && el.classList.contains('ltx_para') && el.querySelector('.ltx_p')) return;
    if (kind === 'cell' && el.closest('table.ltx_equation, table.ltx_equationgroup, table.ltx_eqn_table')) return;
    if (kind === 'item' && el.querySelector('.ltx_p, .ltx_para')) return;
    seen.add(el);
    const words = srcText(el).split(' ').filter(Boolean);
    if (words.length < 6) return;
    const inPicture = !!el.closest('svg');
    cands.push({ kind: inPicture ? kind + '(svg)' : kind, words: words });
  });
});

const res = JSON.parse(resultJSON);
const out = new DOMParser().parseFromString('<body>' + res.html + '</body>', 'text/html');
const blockTexts = [];
out.body.querySelectorAll('[data-b]:not(a)').forEach((b) => {
  const c = b.cloneNode(true);
  c.querySelectorAll('span.m').forEach((m) => m.replaceWith(' '));
  c.querySelectorAll('sup.fnref').forEach((m) => m.replaceWith(' '));
  blockTexts.push(norm(c.textContent));
});
// abstract kept outside the body (old behaviour) still reaches Claude via IngestResult.abstract
const absText = norm(res.abstract || '');
const joined = ' ' + blockTexts.join(' ‖ ') + ' ';
const N = 4;
function gramSet(texts) {
  const g = new Set();
  texts.forEach((t) => {
    const w = t.split(' ').filter(Boolean);
    for (let i = 0; i + N <= w.length; i++) g.add(w.slice(i, i + N).join(' '));
  });
  return g;
}
const grams = gramSet(blockTexts);
// Labels of diagrams that became images are drawn in the image and kept in its alt text.
const altTexts = Array.from(out.body.querySelectorAll('img[alt]')).map((i) => norm(i.getAttribute('alt'))).filter(Boolean);
const altJoined = ' ' + altTexts.join(' \u2016 ') + ' ';
const altGrams = gramSet(altTexts);
function present(words, joinedText, gramsSet) {
  const seq = words.join(' ');
  if (joinedText.indexOf(' ' + seq + ' ') >= 0) return 2;
  let hit = 0, tot = 0;
  for (let i = 0; i + N <= words.length; i++) { tot++; if (gramsSet.has(words.slice(i, i + N).join(' '))) hit++; }
  return tot > 0 && hit / tot >= 0.9 ? 1 : 0;
}
const byKind = {};
const missing = [];
let found = 0, words = 0, wordsFound = 0, strictFound = 0, onlyInAbstractField = 0, inBlocks = 0, inImageOnly = 0;
cands.forEach((c) => {
  const seq = c.words.join(' ');
  const inB = present(c.words, joined, grams);
  const inAlt = inB ? 0 : (c.kind.endsWith('(svg)') ? present(c.words, altJoined, altGrams) : 0);
  const strict = inB === 2;
  const ok = inB > 0 || inAlt > 0;
  const k = byKind[c.kind] || (byKind[c.kind] = { total: 0, found: 0, imageOnly: 0 });
  k.total++;
  words += c.words.length;
  if (strict) strictFound++;
  if (inB) inBlocks++;
  if (inAlt) { inImageOnly++; k.imageOnly++; }
  if (ok) { found++; k.found++; wordsFound += c.words.length; }
  else {
    if (absText && absText.indexOf(seq) >= 0) onlyInAbstractField++;
    missing.push({ kind: c.kind, text: c.words.slice(0, 40).join(' ') + (c.words.length > 40 ? ' …' : '') });
  }
});

const leafEqRows = Array.from(root.querySelectorAll('table.ltx_equation tr, table.ltx_equationgroup tr, table.ltx_eqn_table tr, .ltx_eqn_table .ltx_eqn_row'))
  .filter((tr) => !tr.querySelector('tr, .ltx_eqn_row') && tr.querySelector('math'));
const sections = {};
(res.blocks || []).forEach((b) => { sections[b.section] = (sections[b.section] || 0) + 1; });
return JSON.stringify({
  title: res.title,
  authors: (res.authors || []).length,
  candidates: cands.length,
  found: found,
  strictFound: strictFound,
  coverage: cands.length ? found / cands.length : 1,
  blockCoverage: cands.length ? inBlocks / cands.length : 1,
  inImageOnly: inImageOnly,
  wordCoverage: words ? wordsFound / words : 1,
  onlyInAbstractField: onlyInAbstractField,
  byKind: byKind,
  missing: missing,
  blocks: (res.blocks || []).length,
  firstSections: Object.keys(sections).slice(0, 4),
  abstractBlocks: (res.blocks || []).filter((b) => b.section === 'Abstract').length,
  source: {
    math: root.querySelectorAll('math').length,
    img: root.querySelectorAll('img').length,
    svgPictures: root.querySelectorAll('svg.ltx_picture').length,
    svgWithForeignObject: Array.from(root.querySelectorAll('svg.ltx_picture')).filter((s) => s.querySelector('foreignObject')).length,
    eqRows: leafEqRows.length,
    theorems: root.querySelectorAll('.ltx_theorem').length,
    proofs: root.querySelectorAll('.ltx_proof').length,
  },
  output: {
    math: out.body.querySelectorAll('span.m').length,
    img: out.body.querySelectorAll('img').length,
    svgImg: out.body.querySelectorAll('img[src^="data:image/svg+xml"]').length,
    eq: out.body.querySelectorAll('div.eq').length,
    boxes: out.body.querySelectorAll('div.box').length,
    theorems: out.body.querySelectorAll('.theorem').length,
    proofs: out.body.querySelectorAll('.proof').length,
    htmlBytes: res.html.length,
  },
});
"""#

// MARK: - Main

struct Report: Codable {
    var name: String
    var origin: String
    var ok: Bool
    var error: String?
    var ingestMs: Double?
    var metrics: [String: AnyCodable]?
    var render: [String: AnyCodable]?
}

/// Minimal JSON passthrough so the JS report can be embedded in the --json output verbatim.
struct AnyCodable: Codable {
    let value: Any
    init(_ v: Any) { value = v }
    init(from d: Decoder) throws {
        let c = try d.singleValueContainer()
        if c.decodeNil() { value = NSNull() }
        else if let b = try? c.decode(Bool.self) { value = b }
        else if let n = try? c.decode(Double.self) { value = n }
        else if let s = try? c.decode(String.self) { value = s }
        else if let a = try? c.decode([AnyCodable].self) { value = a.map(\.value) }
        else { value = try c.decode([String: AnyCodable].self).mapValues(\.value) }
    }
    func encode(to e: Encoder) throws {
        var c = e.singleValueContainer()
        switch value {
        case let b as Bool: try c.encode(b)
        case let n as NSNumber: try c.encode(n.doubleValue)
        case let s as String: try c.encode(s)
        case let a as [Any]: try c.encode(a.map(AnyCodable.init))
        case let d as [String: Any]: try c.encode(d.mapValues(AnyCodable.init))
        default: try c.encodeNil()
        }
    }
}

func pct(_ x: Any?) -> String {
    guard let d = (x as? NSNumber)?.doubleValue else { return "?" }
    return String(format: "%.1f%%", d * 100)
}

@MainActor
func run(_ o: Options) async -> Int32 {
    let web = o.web!
    let ingest = Page(handlers: ["ingest"], size: NSSize(width: 800, height: 600))
    do {
        try await ingest.load(file: web.appendingPathComponent("ingest.html"), readAccess: web)
    } catch {
        print("could not load ingest.html: \(error)")
        return 2
    }
    var reports: [Report] = []
    var failed = false
    for input in o.inputs {
        var rep = Report(name: input, origin: "", ok: false)
        do {
            let s = try await loadSource(input, o)
            rep.name = s.name
            rep.origin = s.origin
            let t0 = Date()
            guard let resultJSON = try await ingest.call("return Ingest.fromArxivHTML(html, base)",
                                                         ["html": s.html, "base": s.baseURL]) as? String else {
                throw FetchError.noHTML("Ingest returned no string")
            }
            rep.ingestMs = Date().timeIntervalSince(t0) * 1000
            guard let mJSON = try await ingest.call(measureJS, ["srcHTML": s.html, "resultJSON": resultJSON]) as? String,
                  let m = try JSONSerialization.jsonObject(with: Data(mJSON.utf8)) as? [String: Any] else {
                throw FetchError.noHTML("measurement failed")
            }
            rep.metrics = m.mapValues(AnyCodable.init)
            let cov = (m["coverage"] as? NSNumber)?.doubleValue ?? 0
            rep.ok = cov >= o.minCoverage
            if !rep.ok { failed = true }

            if let dir = o.dump {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                if let r = try JSONSerialization.jsonObject(with: Data(resultJSON.utf8)) as? [String: Any] {
                    try ((r["html"] as? String) ?? "").write(to: dir.appendingPathComponent("\(s.name).html"), atomically: true, encoding: .utf8)
                    let blocks = try JSONSerialization.data(withJSONObject: r["blocks"] ?? [], options: [.prettyPrinted])
                    try blocks.write(to: dir.appendingPathComponent("\(s.name).blocks.json"))
                }
            }

            // ---- console report ----
            let src = m["source"] as? [String: Any] ?? [:]
            let out = m["output"] as? [String: Any] ?? [:]
            print("""
            == \(s.name)  \(m["title"] as? String ?? "")
               from \(s.origin)   ingest \(String(format: "%.0f", rep.ingestMs ?? 0)) ms
               coverage \(pct(m["coverage"])) (\(m["found"] ?? 0)/\(m["candidates"] ?? 0) passages; strict \(m["strictFound"] ?? 0); \(m["inImageOnly"] ?? 0) only as diagram text/alt)   in blocks \(pct(m["blockCoverage"]))   words \(pct(m["wordCoverage"]))   \(rep.ok ? "PASS" : "FAIL")
               blocks \(m["blocks"] ?? 0)  abstract blocks \(m["abstractBlocks"] ?? 0)  first sections \((m["firstSections"] as? [String] ?? []).map { $0.isEmpty ? "(none)" : $0 }.joined(separator: " | "))
               math   src \(src["math"] ?? 0) → spans \(out["math"] ?? 0)    eq rows \(src["eqRows"] ?? 0) → div.eq \(out["eq"] ?? 0)
               images src img \(src["img"] ?? 0) + svg \(src["svgPictures"] ?? 0) (with foreignObject \(src["svgWithForeignObject"] ?? 0)) → img \(out["img"] ?? 0) (svg \(out["svgImg"] ?? 0)), boxes \(out["boxes"] ?? 0)
               theorems \(src["theorems"] ?? 0) → \(out["theorems"] ?? 0)   proofs \(src["proofs"] ?? 0) → \(out["proofs"] ?? 0)
            """)
            if let kinds = m["byKind"] as? [String: [String: Any]] {
                let line = kinds.keys.sorted().map { k -> String in
                    let img = (kinds[k]?["imageOnly"] as? NSNumber)?.intValue ?? 0
                    return "\(k) \(kinds[k]?["found"] ?? 0)/\(kinds[k]?["total"] ?? 0)" + (img > 0 ? " (\(img) as image text)" : "")
                }
                print("   by kind: " + line.joined(separator: ", "))
            }
            if let missing = m["missing"] as? [[String: Any]], !missing.isEmpty, o.maxMissing > 0 {
                print("   missing (\(missing.count)):")
                for item in missing.prefix(o.maxMissing) {
                    print("     - [\(item["kind"] ?? "")] \(item["text"] ?? "")")
                }
                if missing.count > o.maxMissing { print("     … \(missing.count - o.maxMissing) more") }
            }

            if let dir = o.render {
                rep.render = try await render(html: resultJSON, name: s.name, dir: dir, o: o).mapValues(AnyCodable.init)
            }
        } catch {
            rep.error = "\(error)"
            failed = true
            print("== \(input)\n   ERROR \(error)")
        }
        reports.append(rep)
    }
    if let path = o.json {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(reports) { try? data.write(to: path) }
    }
    print("\nsummary (coverage = passages found in blocks, or drawn into a diagram image + its alt):")
    for r in reports {
        let cov = r.metrics?["coverage"]?.value
        let blk = r.metrics?["blockCoverage"]?.value
        print("  \(r.name.padding(toLength: 16, withPad: " ", startingAt: 0)) \(r.error == nil ? pct(cov) : "ERROR")  (in blocks \(pct(blk)))  \(r.ok ? "PASS" : "FAIL")")
    }
    return failed ? 1 : 0
}

@MainActor
func render(html resultJSON: String, name: String, dir: URL, o: Options) async throws -> [String: Any] {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let web = o.web!
    let page = Page(handlers: ["reader"], size: NSSize(width: 1000, height: 1300))
    try await page.load(file: web.appendingPathComponent("reader.html"), readAccess: web)
    _ = try await page.call("const r = JSON.parse(res); return JSON.stringify(Reader.load({html: r.html, highlights: []}))",
                            ["res": resultJSON])
    // Wait for progressive KaTeX rendering to drain (every span.m gets children).
    for _ in 0..<60 {
        try await Task.sleep(nanoseconds: 250_000_000)
        let pending = try await page.call("return Array.from(document.querySelectorAll('#paper span.m')).filter(e => !e.firstChild).length") as? NSNumber
        if (pending?.intValue ?? 0) == 0 { break }
    }
    try await Task.sleep(nanoseconds: 800_000_000) // images (arXiv figures load over the network)
    let statsJSON = try await page.call("""
        // the reader renders math progressively; force the rest so every span is checked
        Paperreads.renderMath(document.getElementById('paper'));
        const fb = Array.from(document.querySelectorAll('#paper .tex-fallback'));
        return JSON.stringify({
          height: document.documentElement.scrollHeight,
          katex: document.querySelectorAll('#paper .katex').length,
          fallbacks: fb.length,
          fallbackSamples: fb.slice(0, 8).map((e) => e.textContent.slice(0, 100)),
          brokenImages: Array.from(document.querySelectorAll('#paper img')).filter((i) => i.complete && i.naturalWidth === 0).length,
        });
        """) as? String ?? "{}"
    let stats = (try? JSONSerialization.jsonObject(with: Data(statsJSON.utf8)) as? [String: Any]) ?? [:]
    print("   render: height \(stats["height"] ?? 0)px, katex \(stats["katex"] ?? 0), fallbacks \(stats["fallbacks"] ?? 0), broken images \(stats["brokenImages"] ?? 0)")
    if let samples = stats["fallbackSamples"] as? [String], !samples.isEmpty {
        samples.forEach { print("     fallback: \($0)") }
    }
    var files: [String] = []
    let height = (stats["height"] as? NSNumber)?.doubleValue ?? 0
    if o.shots > 0 {
        for i in 0..<o.shots {
            let y = o.shots == 1 ? 0 : max(0, height - 1300) * Double(i) / Double(o.shots - 1)
            _ = try await page.call("window.scrollTo(0, y); return 1", ["y": y])
            try await Task.sleep(nanoseconds: 500_000_000)
            let url = dir.appendingPathComponent("\(name)-\(i).png")
            try await page.snapshot(to: url)
            files.append(url.path)
        }
    }
    if let sel = o.focus, o.focusCount > 0 {
        let n = (try await page.call("return document.querySelectorAll(sel).length", ["sel": sel]) as? NSNumber)?.intValue ?? 0
        for i in 0..<min(n, o.focusCount) {
            _ = try await page.call("""
                const el = document.querySelectorAll(sel)[i];
                window.scrollTo(0, Math.max(0, el.getBoundingClientRect().top + window.scrollY - 80));
                return 1
                """, ["sel": sel, "i": i])
            try await Task.sleep(nanoseconds: 500_000_000)
            let url = dir.appendingPathComponent("\(name)-focus\(i).png")
            try await page.snapshot(to: url)
            files.append(url.path)
        }
    }
    files.forEach { print("     snapshot \($0)") }
    var r = stats
    r["snapshots"] = files
    return r
}

let options = parseOptions()
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    let code = await run(options)
    exit(code)
}
app.run()
