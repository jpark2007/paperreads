# Paperreads — architecture & module contract

Native macOS (SwiftUI, macOS 14+) paper reader. Read papers as clean text (default) or the
original PDF, highlight + annotate, and ask Claude questions grounded in the paper and its
cited papers. Single user, local-first. Built with XcodeGen (`project.yml`), ad-hoc signed.

**Contract files (do not change signatures without updating this doc):**
`Paperreads/Core/Models.swift`, `Core/PaperStore.swift`, `Core/AppSettings.swift`.

---

## 1. Visual design (matches the user's "Atlas" app — Editorial Minimal, light, clay)

Tokens (use exactly; mirror in SwiftUI `Theme` and in `Web/common.css` `:root`):

| token | value | use |
|---|---|---|
| bg | `#f2efe6` | every surface (off-white paper). No cards, no shadows, no gradients. |
| ink | `#211d17` | primary text, 1.5px outlines on controls |
| muted | `#565145` | secondary text |
| faint | `#7d7669` | tertiary text, placeholders |
| hairline | `rgba(33,29,23,0.12)` | 1px dividers between regions/rows |
| accent | `#d97757` | clay — ONLY for live/now states, highlight marks, focus. Never a button fill. |
| accentText | `#b04f2f` | accent used as text (links, citation chips) |
| highlightFill | `rgba(217,119,87,0.22)` | highlighted passages |
| danger | `#c4472f` | errors |

Typography: UI chrome = SF Pro Rounded (`.system(design: .rounded)` / CSS `ui-rounded, -apple-system`).
Reading text = New York (`ui-serif`), 19px/1.62, measure ~68ch, centered column. Section headings
in the reader: serif, 600 weight. Small caps labels: 11px bold +0.08em uppercase muted.
Controls: transparent with 1.5px ink outline, radius 19 (pill) or plain text buttons. Generous
spacing (24/32/48 rhythm). Only real text — no decorative icons except minimal SF Symbols in
toolbars where text would not fit. Light appearance only (force `.light`).

## 2. Layout

`NavigationSplitView`:
- **Sidebar (Library)**: search field; filter row `All · To read · Reading · Done`; tag filter;
  list of papers (title in ink, author line + year muted; busy import shows status text in
  accent). Footer: "Add paper" (⌘L link / ⌘O PDF). Drag-and-drop PDF onto the window imports it.
  Context menu: set status, edit tags, delete.
- **Detail**: `HSplitView` of Reader (center) and Side panel (right, toggle ⌘J, ~380pt).
  - Reader header: title (serif 28), authors · year · arXiv id, status picker, mode toggle
    `Text | PDF` (⌘⇧P). Text = `WebReader` (WKWebView). PDF = `PDFKitView`.
    Busy imports show a quiet progress state; failures show the error + "Retry".
  - Side panel: tabs `Ask | Notes`.
    - Ask: chat transcript (WKWebView `chat.html`, renders markdown + KaTeX) and a native
      multiline input at bottom (⏎ send, ⇧⏎ newline), "New chat" text button, model name muted.
    - Notes: paper-level notes (TextEditor) + list of highlights (quote in serif, editable note,
      click → scroll reader to block, delete).
- Settings window (⌘,): API key (SecureField), model picker, embedding status.

Commands: ⌘L import link, ⌘O import PDF, ⌘J toggle panel, ⌘⇧P text/PDF, ⌘E explain selection,
⌘⇧H highlight selection.

## 3. Import pipeline (`Services/Importer.swift`, owned by module C)

```swift
@MainActor final class Importer: ObservableObject {
    static let shared: Importer
    /// Accepts arXiv ids ("2401.12345", "2401.12345v2", "hep-th/9901001"), arxiv.org abs/pdf/html
    /// URLs, DOIs ("10.xxxx/..."), doi.org URLs. Creates the Paper immediately (state .queued),
    /// returns it, and runs the pipeline in a Task. Throws ImportError.unrecognized on bad input.
    func importLink(_ input: String, context: ModelContext) throws -> Paper
    /// Copies the PDF into the store, creates Paper, runs pipeline.
    func importPDF(at url: URL, context: ModelContext) -> Paper
    func retry(_ paper: Paper, context: ModelContext)
}
```

Pipeline (each step updates `paper.importState` + `importStatusDetail`, saves context):
1. **Resolve** (`fetching`): DOI → Semantic Scholar `GET /graph/v1/paper/DOI:{doi}?fields=title,authors,year,abstract,externalIds,openAccessPdf`.
   If it has an ArXiv external id → arXiv path. Else if openAccessPdf → download PDF → PDF path.
   Else fail with "No open-access PDF found — drag the PDF in instead."
   Dropped PDF: extract first-2-pages text with PDFKit. The arXiv margin stamp
   `arXiv:{id}(vN)? [category]` → arXiv path (keep the local PDF). A bare `arXiv:{id}` mention
   (may be a cited preprint) is used only if Semantic Scholar's title for that id appears on
   page 1; else PDF path. A dropped PDF's file-name title is provisional: replaced by S2
   metadata or by IngestResult.title.
2. **arXiv path**: metadata from Semantic Scholar `paper/arXiv:{id}` (fallback: HTML title).
   Clean HTML: try `https://arxiv.org/html/{id}` then `https://ar5iv.labs.arxiv.org/html/{id}`;
   valid only if response is 200 and contains `ltx_document` (ar5iv redirects to abs page when
   missing). Run `WebProcessor.ingestArxivHTML(html, baseURL: finalURL)`. Also download
   `https://arxiv.org/pdf/{id}` to `original.pdf` (non-fatal if it fails). If no HTML → PDF path.
   `contentKind = .arxivHTML`.
3. **PDF path** (`converting`): `ClaudeClient.convertPDF(pdfData:pageCount:onProgress:)` →
   `PDFConversion`; if `!isComplete` (stopped at max_tokens / context window) append a visible
   "Conversion incomplete" blockquote and set `importStatusDetail` after ready (fail only if no
   text at all). Save `source.md` plus `source.json` (PDF size, SHA-256, isComplete); a retry on the same PDF reuses it instead of converting again. PDFs are limited to ~23.9 MB raw so the base64 request stays under the 32 MB API cap. `WebProcessor.ingestMarkdown(md)`. If arXiv HTML ingest fails, the arXiv path falls back to this PDF route. `contentKind = .claudeMarkdown`.
   If title unknown (placeholder or file name), use IngestResult.title.
4. Save content via `PaperStore.writeContent`. State → `ready` (reader usable now).
5. **References** (`referencesState = fetching`, runs after ready, non-blocking): Semantic
   Scholar `GET /graph/v1/paper/{s2id or arXiv:id or DOI:doi}/references?fields=title,authors,year,abstract,externalIds,openAccessPdf&limit=500`.
   For non-arXiv papers without ids, first `GET /graph/v1/paper/search/match?query={title}`;
   the hit is accepted only if its normalised title matches the paper's title.
   Create `ReferenceEntry` rows (ordinal 1..n). For each with a non-empty abstract, embed
   "title. abstract" with `Embedder` and insert `RefChunk(label: "r\(ordinal)")`. Then `ready`/`unavailable`/`failed`.

Network hygiene (all HTTP): one shared `URLSession` with 30s request timeout (Claude: 600s),
`User-Agent: Paperreads/0.1 (personal research reader)`, max response sizes enforced
(HTML 25MB, PDF 60MB), only `https` URLs, Semantic Scholar 429 → exponential backoff
(1s,2s,4s, max 3 retries). Imports are serialized (one active pipeline at a time, others queued).
On app launch, papers stuck in a busy state are marked failed with "Interrupted — Retry", and
ready papers whose references are `none`/`failed` are queued for the reference step again
(`Importer.resumeReferences`). The library context menu offers "Retry References"
(`Importer.retryReferences`). Hosts that are loopback/private/link-local/CGNAT IP literals,
`localhost` or `.local` are rejected by `HTTP.validate` (also on every redirect hop).

### WebProcessor (`Services/WebProcessor.swift`, module C)

One offscreen `WKWebView` (created lazily, kept for app lifetime, non-persistent data store,
JavaScript enabled, no network access needed — content is passed in) loading bundled
`Web/ingest.html`. Calls via `callAsyncJavaScript`:

```swift
@MainActor final class WebProcessor {
    static let shared: WebProcessor
    func ingestArxivHTML(_ html: String, baseURL: URL) async throws -> IngestResult
    func ingestMarkdown(_ markdown: String) async throws -> IngestResult
}
```
JS returns a JSON string; Swift decodes `IngestResult`.

### ScholarAPI (`Services/ScholarAPI.swift`, module C)
Thin async client for the endpoints above. Returns plain Codable structs.

### Embeddings & retrieval (`Services/Retriever.swift`, module C)

```swift
enum Embedder {
    /// On-device sentence embedding (NaturalLanguage NLEmbedding.sentenceEmbedding(.english)),
    /// L2-normalised, packed as little-endian Float32 Data. Returns empty Data if unavailable.
    static func embed(_ text: String) -> Data
}
struct RetrievedChunk { let label: String; let title: String; let text: String; let score: Double }
enum Retriever {
    /// Hybrid: cosine over embeddings + BM25 over RefChunk.text, fused with reciprocal rank
    /// fusion (k=60). Only chunks where chunk.paperId == paperId. `title` from ReferenceEntry.
    @MainActor static func search(paperId: UUID, query: String, k: Int, context: ModelContext) -> [RetrievedChunk]
}
```
Embed long text by truncating to ~2000 chars (the model is sentence-level). Run embedding of
many references off the main actor (pure values in, Data out), insert rows on main.

## 4. Claude integration (module B)

Raw HTTP to `https://api.anthropic.com/v1/messages` (no Swift SDK exists). Headers:
`x-api-key`, `anthropic-version: 2026-10-21`, `content-type: application/json`,
`anthropic-beta: server-side-fallback-2026-07-01`. Body always includes
`"fallbacks": "default"`, `"stream": true`. Never send `temperature`/`top_p`/`top_k`,
`thinking.budget_tokens`, `thinking: {type:"disabled"}`, or assistant prefill. Omit `thinking`
(Opus 5.5 runs adaptive). Effort via `"output_config": {"effort": "low"|"medium"}`.
Model from `AppSettings.shared.model`.

```swift
struct ClaudeError: LocalizedError { ... }   // includes HTTP status + API error message
enum ClaudeStreamEvent {
    case textDelta(String)
    case thinking                       // a thinking block started (show "Thinking…")
    case done(contentJSON: Data, text: String, stopReason: String?)
}
struct ClaudeClient {
    /// Streams one Messages request. `body` is the JSON object minus model/stream/fallbacks,
    /// which the client adds. Reconstructs every content block exactly (text, thinking with
    /// signature via signature_delta, redacted_thinking, unknown types copied from
    /// content_block_start) so the assistant turn can be replayed byte-for-byte.
    func stream(body: [String: Any]) -> AsyncThrowingStream<ClaudeStreamEvent, Error>
    /// PDF → Markdown conversion (document block, base64). effort low, max_tokens 64000.
    func convertPDF(pdfData: Data, pageCount: Int? = nil,
                    onProgress: @escaping @MainActor (Int) -> Void) async throws -> PDFConversion
}
struct PDFConversion { let markdown: String; let stopReason: String?; let isComplete: Bool }
```
SSE: parse `event:`/`data:` lines from `URLSession.bytes`; handle `message_start`,
`content_block_start`, `content_block_delta` (`text_delta`, `thinking_delta`, `signature_delta`,
`citations_delta` append to block), `content_block_stop`, `message_delta` (stop_reason),
`error` events, `ping`. HTTP non-200 → read body, throw ClaudeError. `stop_reason == "refusal"`
→ surface a clear message (don't crash). Task cancellation must cancel the request.

PDF conversion prompt: convert the whole paper to Markdown; `#`/`##` headings; every equation
as LaTeX (`$…$` inline, `$$…$$` display, equation numbers as `\tag{n}`); tables as Markdown
tables; figures as `> **Figure n.** caption`; omit running headers/footers/page numbers; keep
the references section as a numbered list; output only the Markdown. PDFs > 32MB or > 600
pages → error.

### ChatEngine (`Services/ChatEngine.swift`, module B)

```swift
@MainActor final class ChatEngine: ObservableObject {
    @Published private(set) var messages: [ChatDisplayMessage]   // for chat.html
    @Published private(set) var streamingText: String?          // nil when idle
    @Published private(set) var isThinking: Bool
    @Published var errorText: String?
    init(paper: Paper, context: ModelContext)   // loads latest conversation for paper
    func ask(_ question: String)
    func explain(_ selection: ReaderSelection)
    func newConversation()
    func cancel()
}
struct ChatDisplayMessage: Codable, Identifiable, Equatable { let id: UUID; let role: String; let kind: String; let markdown: String }
```

**Prompt design (prompt caching + append-only history — required for preserved thinking):**
- `system` = FROZEN per paper: instructions + full paper text, built once from `blocks.json`
  as lines `[b{n}] {text}` grouped under `## {section}` headings, with a
  `cache_control: {type: "ephemeral"}` on the paper block. Never changes within a conversation.
  Instructions: you are a reading companion for a researcher; answer grounded in the paper;
  cite paper passages as `[b12]` and cited works as `[r3]`; explain math step by step with
  LaTeX (`$…$`, `$$…$$`); say when something is not in the paper/sources; be concise.
- Each user turn content = [optional text block "Related cited works (retrieved):\n[r3] Title (year): abstract…" (top 6 from `Retriever.search`) , text block with the question].
  For explain: question = "Explain this passage in context. Define terms and unpack any math:\n> {quote}\n(Located at [b{blockIndex}]; surrounding text: {contextText})".
  Ask and Explain both use top-level effort "medium" (constant per conversation: changing
  `effort` between turns invalidates the prompt cache).
- `messages` = all prior `ChatTurn.contentJSON` for this conversation in `seq` order, verbatim,
  then the new user turn. Persist the user turn BEFORE sending and the assistant turn's exact
  content blocks after `done`. If a request fails, delete only the just-added unanswered user
  turn (it is the tail, so history stays append-only) and set `errorText`.
- The new user turn's last content block carries `cache_control: {type: "ephemeral"}` in the
  request copy only (never in stored contentJSON), so each turn reads the whole prior prefix
  from cache (2 of 4 breakpoints).
- `max_tokens` 16000. The frozen system is built lazily on the first send.
- Conversation size guard: if the stored conversation exceeds ~150 turns or the estimated
  request size (bytes/3) exceeds ~176k tokens, `newConversation()` with a notice.
- Streaming text is coalesced: `streamingText` is published at most every 50 ms, and
  ChatWebView keeps only the latest pending `Chat.setStreaming` payload.

## 5. Web layer (`Paperreads/Web/`, module A)

All pages load only bundled files (no CDN): `vendor/katex/katex.min.{js,css}` + fonts,
`vendor/marked.min.js`. Shared `common.css` (tokens, typography) and `common.js`
(math helpers). A strict CSP meta tag on every page:
`default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; font-src 'self'; img-src 'self' https://arxiv.org https://*.arxiv.org data:;`
(reader; chat uses `img-src 'self' data:`). Claude Markdown keeps image alt text only. Paper HTML is UNTRUSTED: ingest must sanitize to an allowlist of tags
(`h1-h4 p ul ol li figure figcaption img table thead tbody tr td th em strong i b sub sup a span div br blockquote code pre cite`)
and attributes (`src` (https or data:image only), `href` (https or `#…` only), `colspan`,
`rowspan`, `alt`, `data-tex`, `data-d`, `class` only for our own classes; `data-b` only with
`keepBlockIds: true`, i.e. the reader's re-sanitize of our own content.html — untrusted input
can never set block ids). Chat shows each model link's full URL on hover and its host inline. No inline
event handlers, no `style`, no `script`/`iframe`/`object`/`form`/`svg`/`math` survives ingest.
LLM output rendered in chat is ALSO untrusted: marked output must be sanitized with the same
allowlist before insertion.

### Math normal form
Every equation becomes `<span class="m" data-tex="{latex}" data-d="0|1"></span>`
(d=1 display). Display equations sit in `<div class="eq">…<span class="eqn">(3)</span></div>`.
Renderer calls `katex.render(tex, el, {displayMode, throwOnError: true, strict: "ignore"})`;
on error show the raw TeX in `code.tex-fallback`. Common LaTeXML macros not in KaTeX can be
left to fallback.

### `ingest.html` / `ingest.js`
- `Ingest.fromArxivHTML(html, baseURL)` → JSON string of IngestResult. DOMParser; root
  `article.ltx_document` (fallback `body`). Title `.ltx_title_document`, authors
  `.ltx_personname` (split on newlines/commas, trim, drop emails/affiliations best-effort),
  abstract `.ltx_abstract` (minus its heading). Replace every `<math>` with a math span using
  its `alttext` (display = `display="block"`). Convert `table.ltx_equation`/`ltx_equationgroup`
  rows into `div.eq` (keep equation number from `.ltx_tag_equation`). Make `img` src absolute
  against baseURL. Drop title/authors/abstract header block from body (rendered natively),
  nav, footers, `.ltx_page_footer`, `.ltx_role_*` noise. Sanitize. Tag blocks.
- `Ingest.fromMarkdown(md)` → JSON string. Protect `$$…$$`, `\[…\]`, `$…$`, `\(…\)` with
  placeholders before `marked.parse`, restore as math spans after. Title = first `# ` heading
  (removed from body); abstract = paragraph(s) under a heading matching /abstract/i. Sanitize. Tag.
- **Block tagging**: in document order, assign `data-b=0..n` to: `h2,h3,h4`, `p`, `li` (without
  nested `p`), `figcaption`, `div.eq`, `table` (not inside div.eq), `blockquote` (without nested `p`),
  `pre`, `div.listing` (code / algorithm listings).
  Block text = textContent with math spans replaced by `$tex$` / `$$tex$$`, whitespace collapsed.
  `section` = text of the most recent h2/h3. Skip empty blocks.

### `reader.html` / `reader.js` (WKWebView, `loadFileURL` with read access to Web dir)
API (called by Swift via `evaluateJavaScript`/`callAsyncJavaScript`):
- `Reader.load({html, highlights:[{id, blockIndex, startOffset, quote}]})` — inject (already
  sanitized) html into `#paper`, render math, apply highlights (wrap matching text-node
  segments in `mark.hl[data-id]`; locate by blockIndex+startOffset, fallback search quote in block).
- `Reader.addHighlight(h)`, `Reader.removeHighlight(id)`, `Reader.scrollToBlock(b)` (smooth,
  brief accent flash), `Reader.flashHighlight(id)`.
- `Reader.getSelection()` → ReaderSelection JSON or null. Offsets measured in the block's
  plain textContent (math spans count as their rendered text — use the same function both
  ways so add/apply round-trips).
- Floating selection toolbar (appears above a non-empty selection inside `#paper`):
  text buttons `Highlight · Explain · Ask`. Posts to Swift.
Messages to Swift: `window.webkit.messageHandlers.reader.postMessage(obj)`:
`{type:"ready"}`, `{type:"selection", action:"highlight"|"explain"|"ask", selection:{…}}`,
`{type:"highlightClicked", id}`.
Typography per §1; images max-width 100%; tables scroll horizontally; `.eq` centered with
number right-aligned.

### `chat.html` / `chat.js`
- `Chat.setMessages([{id, role, kind, markdown}])`, `Chat.setStreaming(markdownOrNull, thinking)`
  (re-render throttled ≤ 20fps), `Chat.setReferences({"r3": "Title (2017)", …})`,
  `Chat.setPaperTitle(str)` for empty state.
- Markdown rendering: protect math → marked → sanitize → restore math → KaTeX. Citation tokens
  `[b12]`, `[b3, b4]`, `[r5]` become `<a class="cite" data-b="12">§</a>` chips (b → "¶12",
  r → short ref title on hover via `title` attr).
- User messages: right-aligned muted serif, no bubble; assistant: full width ink. Hairline
  between turns. Empty state: "Ask anything about *{title}*." in faint.
Messages to Swift: `chat` handler: `{type:"ready"}`, `{type:"jumpToBlock", b}`, `{type:"openReference", label}`.

### Swift ↔ JS bridge rules (security)
- `WKUserContentController` handlers validate every message: known `type`, expected field
  types, size caps (quote ≤ 4000 chars, context ≤ 8000). Ignore anything else.
- Navigation policy: allow only the initial file URL; any link click (`navigationType ==
  .linkActivated`) to https opens in the default browser via `NSWorkspace`, everything else is
  cancelled. No `javaScriptCanOpenWindowsAutomatically`. Pass data into JS via JSON-encoded
  arguments (`callAsyncJavaScript(arguments:)`), never string-interpolated JS.
- Use the non-persistent `WKWebsiteDataStore`.

## 6. Views (module D, `Paperreads/App`, `Paperreads/Views`)

- `App/PaperreadsApp.swift` — `@main`, `.modelContainer(for: SchemaV1.models)`, window
  min 1100×700, `.preferredColorScheme(.light)`, `Settings { SettingsView() }`, `.commands`
  wiring the shortcuts via `FocusedValue`s or a shared `@MainActor AppCommands` ObservableObject.
  On launch: mark interrupted imports failed.
- `App/Theme.swift` — tokens from §1 (`Theme.bg`, `.ink`, …, `Font.serif(_:)`, `.rounded(_:)`),
  view modifiers `capsLabel()`, `outlineControl()`.
- `Views/RootView.swift`, `LibrarySidebar.swift`, `ReaderView.swift`, `WebReader.swift`
  (NSViewRepresentable + Coordinator: WKScriptMessageHandler + WKNavigationDelegate; holds
  weak refs to avoid retain cycles — use a weak proxy for script message handlers and remove
  them in `dismantleNSView`), `PDFKitView.swift`, `SidePanel.swift`, `ChatWebView.swift`,
  `NotesPanel.swift`, `ImportSheet.swift`, `SettingsView.swift`.
- One `ChatEngine` per open paper, created when the paper is selected, cancelled on switch.

## 7. Module ownership (parallel build)

| module | owns | depends on |
|---|---|---|
| A — Web layer | everything under `Paperreads/Web/` except `vendor/` | §1, §5 |
| B — Claude | `Services/ClaudeClient.swift`, `Services/ChatEngine.swift` | Core, `Retriever` signature |
| C — Import pipeline | `Services/Importer.swift`, `WebProcessor.swift`, `ScholarAPI.swift`, `Retriever.swift`, `Services/HTTP.swift` | Core, `ClaudeClient.convertPDF` signature, ingest JS API |
| D — App + UI | `App/*`, `Views/*` | Core, Importer/ChatEngine/Retriever signatures, reader/chat JS APIs |

`Services/HTTP.swift` (module C) exposes `enum HTTP { static let session: URLSession; static func get(_ url: URL, maxBytes: Int) async throws -> (Data, HTTPURLResponse) }`
— module B may use `HTTP.session` only via its own request building; B's Claude session has
its own 600s timeout, so B may create its own `URLSession` in ClaudeClient.

Never edit another module's files; if a contract is insufficient, note it in the final report.
