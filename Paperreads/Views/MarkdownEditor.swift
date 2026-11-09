import SwiftUI
import AppKit

// Plain-Markdown notes editor (NSTextView, TextKit 1). The stored string is always plain
// Markdown; styling is attributes only, applied to the edited paragraph(s) as the text
// storage processes each edit. All smart substitutions are off so "-", "--", "*", "1."
// and quotes stay exactly as typed.

// MARK: - Line prefixes

enum MarkdownLinePrefix: CaseIterable {
    case h1, h2, bullet, numbered, task

    var label: String {
        switch self {
        case .h1: "H1"
        case .h2: "H2"
        case .bullet: "•"
        case .numbered: "1."
        case .task: "☐"
        }
    }

    var help: String {
        switch self {
        case .h1: "Heading"
        case .h2: "Subheading"
        case .bullet: "Bulleted list"
        case .numbered: "Numbered list"
        case .task: "Checklist"
        }
    }
}

/// Lets SwiftUI controls (the formatting row) act on the editor's NSTextView.
@MainActor
final class MarkdownEditorController: ObservableObject {
    fileprivate weak var textView: MarkdownTextView?

    func toggle(_ prefix: MarkdownLinePrefix) {
        guard let tv = textView else { return }
        MarkdownEditing.togglePrefix(prefix, in: tv)
        tv.window?.makeFirstResponder(tv)
    }

    func wrap(_ marker: String) {
        guard let tv = textView else { return }
        MarkdownEditing.wrapSelection(in: tv, marker: marker)
        tv.window?.makeFirstResponder(tv)
    }

    func focus() {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
    }
}

/// The row of text buttons above the editor: `H1  H2  •  1.  ☐`.
struct MarkdownFormatBar: View {
    let controller: MarkdownEditorController

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            ForEach(MarkdownLinePrefix.allCases, id: \.self) { p in
                Button(p.label) { controller.toggle(p) }
                    .buttonStyle(TextButtonStyle(color: Theme.faint, hoverColor: Theme.ink, size: 13, weight: .semibold))
                    .help(p.help)
            }
        }
    }
}

// MARK: - Editor

struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    var controller: MarkdownEditorController?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        let tv = MarkdownTextView(usingTextLayoutManager: false)
        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainerInset = NSSize(width: 0, height: 4)

        MarkdownEditing.configurePlain(tv)
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.insertionPointColor = Theme.nsInk
        tv.selectedTextAttributes = [.backgroundColor: Theme.nsAccent.withAlphaComponent(0.22)]
        tv.typingAttributes = MarkdownStyler.baseAttributes
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true

        let coord = context.coordinator
        tv.delegate = coord
        tv.textStorage?.delegate = coord
        tv.onWrap = { [weak tv] marker in
            guard let tv else { return }
            MarkdownEditing.wrapSelection(in: tv, marker: marker)
        }

        // Initial content: not undoable, styled once in full.
        coord.isApplyingExternal = true
        tv.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: MarkdownStyler.baseAttributes))
        if let storage = tv.textStorage { MarkdownStyler.style(storage, range: NSRange(location: 0, length: storage.length)) }
        coord.isApplyingExternal = false
        coord.lastSynced = text

        scroll.documentView = tv
        coord.textView = tv
        controller?.textView = tv
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coord = context.coordinator
        coord.parent = self
        guard let tv = coord.textView else { return }
        controller?.textView = tv

        // Only push genuinely external changes (not the echo of our own typing).
        guard text != tv.string, text != coord.lastSynced else { return }
        coord.applyExternal(text, to: tv)
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.textView?.delegate = nil
        coordinator.textView?.textStorage?.delegate = nil
        coordinator.textView?.onWrap = nil
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: MarkdownEditor
        weak var textView: MarkdownTextView?
        /// The last value we pushed to (or received from) the binding.
        var lastSynced: String = ""
        var isApplyingExternal = false

        init(_ parent: MarkdownEditor) { self.parent = parent }

        func applyExternal(_ newText: String, to tv: NSTextView) {
            guard let storage = tv.textStorage else { return }
            let sel = tv.selectedRange()
            let full = NSRange(location: 0, length: storage.length)
            isApplyingExternal = true
            // Goes through shouldChange/didChange so it is a single undoable step.
            if tv.shouldChangeText(in: full, replacementString: newText) {
                storage.replaceCharacters(in: full, with: newText)
                tv.didChangeText()
            } else {
                storage.setAttributedString(NSAttributedString(string: newText, attributes: MarkdownStyler.baseAttributes))
            }
            MarkdownStyler.style(storage, range: NSRange(location: 0, length: storage.length))
            isApplyingExternal = false
            lastSynced = newText
            let len = (newText as NSString).length
            let loc = min(sel.location, len)
            tv.setSelectedRange(NSRange(location: loc, length: min(sel.length, len - loc)))
        }

        // MARK: NSTextStorageDelegate — restyle only the edited paragraph(s).

        func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            MarkdownStyler.style(textStorage, range: editedRange)
        }

        // MARK: NSTextViewDelegate

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let s = tv.string
            lastSynced = s
            if !isApplyingExternal, parent.text != s { parent.text = s }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            // Keep the caret/typing font body-sized at paragraph starts (e.g. after Return
            // on a heading); inside a styled run AppKit uses that run's attributes anyway.
            guard let tv = notification.object as? NSTextView else { return }
            let sel = tv.selectedRange()
            let ns = tv.string as NSString
            if sel.length == 0, sel.location == 0 || ns.character(at: sel.location - 1) == 0x0A {
                tv.typingAttributes = MarkdownStyler.baseAttributes
            }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                return MarkdownEditing.handleNewline(in: textView)
            case #selector(NSResponder.insertTab(_:)):
                return MarkdownEditing.handleIndent(in: textView, outdent: false)
            case #selector(NSResponder.insertBacktab(_:)):
                return MarkdownEditing.handleIndent(in: textView, outdent: true)
            default:
                return false
            }
        }
    }
}

/// NSTextView that maps ⌘B / ⌘I to Markdown emphasis.
final class MarkdownTextView: NSTextView {
    var onWrap: ((String) -> Void)?

    private func emphasisMarker(for event: NSEvent) -> String? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command, let c = event.charactersIgnoringModifiers?.lowercased() else { return nil }
        switch c {
        case "b": return "**"
        case "i": return "*"
        default: return nil
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, window?.firstResponder === self, isEditable,
           let marker = emphasisMarker(for: event), let onWrap {
            onWrap(marker)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if let marker = emphasisMarker(for: event), let onWrap, isEditable {
            onWrap(marker)
            return
        }
        super.keyDown(with: event)
    }
}

// MARK: - Styling

enum MarkdownStyler {
    static let bodySize: CGFloat = 14

    static var bodyFont: NSFont { Theme.nsRounded(bodySize) }

    static var baseParagraph: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 3
        p.paragraphSpacing = 3
        return p
    }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: bodyFont, .foregroundColor: Theme.nsInk, .paragraphStyle: baseParagraph]
    }

    private static let markerColor = Theme.nsFaint
    private static let codeBackground = Theme.nsInk.withAlphaComponent(0.06)

    static func serif(_ size: CGFloat, weight: NSFont.Weight) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: weight)
        if let d = base.fontDescriptor.withDesign(.serif), let f = NSFont(descriptor: d, size: size) { return f }
        return base
    }

    // Regexes are compiled once.
    private static let headingRE = try! NSRegularExpression(pattern: "^(#{1,6})[ \\t]+")
    private static let quoteRE = try! NSRegularExpression(pattern: "^([ \\t]*)(>[ \\t]?)")
    private static let codeRE = try! NSRegularExpression(pattern: "`[^`\\n]+`")
    private static let boldRE = try! NSRegularExpression(pattern: "(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")
    private static let italicRE = try! NSRegularExpression(
        pattern: "(?<![\\*\\w])\\*(?=[^\\s\\*])(.+?)(?<=[^\\s\\*])\\*(?![\\*\\w])")

    /// Restyle every paragraph intersecting `range` (expanded to whole paragraphs).
    static func style(_ storage: NSTextStorage, range: NSRange) {
        let ns = storage.string as NSString
        guard ns.length > 0 else { return }
        let clamped = NSRange(location: min(range.location, ns.length),
                              length: min(range.length, ns.length - min(range.location, ns.length)))
        let paraRange = ns.paragraphRange(for: clamped)
        ns.enumerateSubstrings(in: paraRange, options: [.byParagraphs, .substringNotRequired]) { _, lineRange, enclosing, _ in
            styleParagraph(storage, ns: ns, line: lineRange, enclosing: enclosing)
        }
    }

    private static func styleParagraph(_ storage: NSTextStorage, ns: NSString, line: NSRange, enclosing: NSRange) {
        // Reset to body.
        storage.setAttributes(baseAttributes, range: enclosing)
        guard line.length > 0 else { return }
        let text = ns.substring(with: line)
        let local = NSRange(location: 0, length: (text as NSString).length)

        var serifHeading = false
        var size = bodySize
        var weight: NSFont.Weight = .regular

        if let m = headingRE.firstMatch(in: text, range: local) {
            let level = m.range(at: 1).length
            serifHeading = level <= 3
            switch level {
            case 1: size = 22
            case 2: size = 18
            case 3: size = 16
            default: size = bodySize
            }
            weight = .semibold
            let font = serifHeading ? serif(size, weight: weight) : Theme.nsRounded(size, weight: weight)
            let p = NSMutableParagraphStyle()
            p.lineSpacing = 2
            p.paragraphSpacing = 4
            p.paragraphSpacingBefore = level <= 2 ? 8 : 4
            storage.addAttributes([.font: font, .paragraphStyle: p], range: enclosing)
            storage.addAttribute(.foregroundColor, value: markerColor,
                                 range: NSRange(location: line.location, length: m.range.length))
        } else if let marker = MarkdownEditing.listMarker(in: text) {
            let prefix = (text as NSString).substring(to: marker.length)
            let indentWidth = (prefix as NSString).size(withAttributes: [.font: bodyFont]).width
            let p = NSMutableParagraphStyle()
            p.lineSpacing = 3
            p.paragraphSpacing = 3
            p.firstLineHeadIndent = 0
            p.headIndent = ceil(indentWidth)
            storage.addAttribute(.paragraphStyle, value: p, range: enclosing)
            let markerStart = line.location + (marker.indent as NSString).length
            storage.addAttribute(.foregroundColor, value: Theme.nsMuted,
                                 range: NSRange(location: markerStart, length: marker.length - (marker.indent as NSString).length))
            if marker.isChecked {
                let contentRange = NSRange(location: line.location + marker.length, length: line.length - marker.length)
                if contentRange.length > 0 {
                    storage.addAttributes([.foregroundColor: Theme.nsFaint,
                                           .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                           .strikethroughColor: Theme.nsFaint], range: contentRange)
                }
            }
        } else if let m = quoteRE.firstMatch(in: text, range: local) {
            let markerWidth = ((text as NSString).substring(with: m.range) as NSString)
                .size(withAttributes: [.font: bodyFont]).width
            let p = NSMutableParagraphStyle()
            p.lineSpacing = 3
            p.paragraphSpacing = 3
            p.firstLineHeadIndent = 10
            p.headIndent = 10 + ceil(markerWidth)
            storage.addAttributes([.paragraphStyle: p, .foregroundColor: Theme.nsMuted], range: enclosing)
            storage.addAttribute(.foregroundColor, value: markerColor,
                                 range: NSRange(location: line.location + m.range.location, length: m.range.length))
        }

        styleInline(storage, text: text, line: line, serif: serifHeading, size: size, weight: weight)
    }

    private static func font(serif: Bool, size: CGFloat, weight: NSFont.Weight) -> NSFont {
        serif ? self.serif(size, weight: weight) : Theme.nsRounded(size, weight: weight)
    }

    private static func styleInline(_ storage: NSTextStorage, text: String, line: NSRange,
                                    serif: Bool, size: CGFloat, weight: NSFont.Weight) {
        let local = NSRange(location: 0, length: (text as NSString).length)
        func absRange(_ r: NSRange) -> NSRange { NSRange(location: line.location + r.location, length: r.length) }

        // Code spans first; emphasis is not applied inside them.
        var codeRanges: [NSRange] = []
        for m in codeRE.matches(in: text, range: local) {
            codeRanges.append(m.range)
            storage.addAttributes([.font: NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular),
                                   .backgroundColor: codeBackground], range: absRange(m.range))
            storage.addAttribute(.foregroundColor, value: markerColor, range: absRange(NSRange(location: m.range.location, length: 1)))
            storage.addAttribute(.foregroundColor, value: markerColor,
                                 range: absRange(NSRange(location: NSMaxRange(m.range) - 1, length: 1)))
        }
        func inCode(_ r: NSRange) -> Bool { codeRanges.contains { NSIntersectionRange($0, r).length > 0 } }

        let boldWeight: NSFont.Weight = weight == .regular ? .semibold : .bold
        for m in boldRE.matches(in: text, range: local) where !inCode(m.range) {
            storage.addAttribute(.font, value: font(serif: serif, size: size, weight: boldWeight), range: absRange(m.range))
            let mk = m.range(at: 1).length
            storage.addAttribute(.foregroundColor, value: markerColor, range: absRange(NSRange(location: m.range.location, length: mk)))
            storage.addAttribute(.foregroundColor, value: markerColor,
                                 range: absRange(NSRange(location: NSMaxRange(m.range) - mk, length: mk)))
        }

        for m in italicRE.matches(in: text, range: local) where !inCode(m.range) {
            let r = absRange(m.range)
            // Italicise whatever font is already there (may be bold).
            storage.enumerateAttribute(.font, in: r, options: []) { value, sub, _ in
                let f = (value as? NSFont) ?? font(serif: serif, size: size, weight: weight)
                let d = f.fontDescriptor.withSymbolicTraits(f.fontDescriptor.symbolicTraits.union(.italic))
                if let it = NSFont(descriptor: d, size: f.pointSize),
                   it.fontDescriptor.symbolicTraits.contains(.italic) {
                    storage.addAttribute(.font, value: it, range: sub)
                } else {
                    storage.addAttribute(.obliqueness, value: 0.18, range: sub)
                }
            }
            storage.addAttribute(.foregroundColor, value: markerColor, range: absRange(NSRange(location: m.range.location, length: 1)))
            storage.addAttribute(.foregroundColor, value: markerColor,
                                 range: absRange(NSRange(location: NSMaxRange(m.range) - 1, length: 1)))
        }
    }
}

// MARK: - Editing behaviours

enum MarkdownEditing {
    struct ListMarker {
        enum Kind { case bullet(String), ordered(Int, String) }
        var indent: String
        var kind: Kind
        var hasCheckbox: Bool
        var isChecked: Bool
        /// UTF-16 length of the whole prefix (indent + marker + spacing + checkbox).
        var length: Int

        /// Marker for a new item after this one.
        var continuation: String {
            var s = indent
            switch kind {
            case .bullet(let b): s += b
            case .ordered(let n, let d): s += "\(n + 1)\(d)"
            }
            s += " "
            if hasCheckbox { s += "[ ] " }
            return s
        }
    }

    private static let listRE = try! NSRegularExpression(
        pattern: "^([ \\t]*)([-*•+]|\\d{1,9}[.)])[ \\t]+(\\[([ xX])\\](?:[ \\t]+|$))?")
    private static let quoteRE = try! NSRegularExpression(pattern: "^([ \\t]*)>[ \\t]?")
    private static let headingRE = try! NSRegularExpression(pattern: "^#{1,6}[ \\t]+")

    /// `line` excludes the trailing newline.
    static func listMarker(in line: String) -> ListMarker? {
        let ns = line as NSString
        guard let m = listRE.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let indent = ns.substring(with: m.range(at: 1))
        let token = ns.substring(with: m.range(at: 2))
        let kind: ListMarker.Kind
        if let last = token.last, last == "." || last == ")", let n = Int(token.dropLast()) {
            kind = .ordered(n, String(last))
        } else {
            kind = .bullet(token)
        }
        let hasBox = m.range(at: 3).location != NSNotFound
        let checked = hasBox && m.range(at: 4).location != NSNotFound
            && ns.substring(with: m.range(at: 4)).lowercased() == "x"
        return ListMarker(indent: indent, kind: kind, hasCheckbox: hasBox, isChecked: checked, length: m.range.length)
    }

    static func configurePlain(_ tv: NSTextView) {
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.isAutomaticTextCompletionEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.isContinuousSpellCheckingEnabled = true
        tv.isEditable = true
        tv.isSelectable = true
    }

    /// One undoable replacement, with the resulting selection.
    static func replace(_ tv: NSTextView, range: NSRange, with s: String, select: NSRange, actionName: String) {
        guard let storage = tv.textStorage else { return }
        tv.breakUndoCoalescing()
        guard tv.shouldChangeText(in: range, replacementString: s) else { return }
        storage.replaceCharacters(in: range, with: s)
        tv.didChangeText()
        let len = storage.length
        let loc = min(max(0, select.location), len)
        tv.setSelectedRange(NSRange(location: loc, length: min(max(0, select.length), len - loc)))
        tv.scrollRangeToVisible(tv.selectedRange())
        tv.undoManager?.setActionName(actionName)
    }

    /// Line range at `location` without its trailing newline.
    private static func lineContentRange(_ ns: NSString, at location: Int) -> NSRange {
        let lr = ns.lineRange(for: NSRange(location: location, length: 0))
        var end = NSMaxRange(lr)
        if end > lr.location, ns.character(at: end - 1) == 0x0A { end -= 1 }
        if end > lr.location, ns.character(at: end - 1) == 0x0D { end -= 1 }
        return NSRange(location: lr.location, length: end - lr.location)
    }

    // Return: continue list / quote markers; on an empty item, remove the marker.
    static func handleNewline(in tv: NSTextView) -> Bool {
        let sel = tv.selectedRange()
        guard sel.length == 0, !tv.hasMarkedText() else { return false }
        let ns = tv.string as NSString
        let lineR = lineContentRange(ns, at: sel.location)
        let line = ns.substring(with: lineR)

        var prefixLen: Int
        var continuation: String
        if let marker = listMarker(in: line) {
            prefixLen = marker.length
            continuation = marker.continuation
        } else if let q = quoteRE.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)) {
            prefixLen = q.range.length
            continuation = (line as NSString).substring(to: q.range.length)
            if !continuation.hasSuffix(" ") { continuation += " " }
        } else {
            return false
        }
        guard sel.location >= lineR.location + prefixLen else { return false }

        let rest = (line as NSString).substring(from: prefixLen)
        if rest.trimmingCharacters(in: .whitespaces).isEmpty {
            // Empty item: drop the marker, leaving an empty line (end the list).
            replace(tv, range: lineR, with: "", select: NSRange(location: lineR.location, length: 0),
                    actionName: "End List")
            return true
        }
        let insertion = "\n" + continuation
        replace(tv, range: sel, with: insertion,
                select: NSRange(location: sel.location + (insertion as NSString).length, length: 0),
                actionName: "Typing")
        return true
    }

    // Tab / Shift-Tab on list lines: indent / outdent by two spaces.
    static func handleIndent(in tv: NSTextView, outdent: Bool) -> Bool {
        let sel = tv.selectedRange()
        guard !tv.hasMarkedText() else { return false }
        let ns = tv.string as NSString
        let firstLine = ns.substring(with: lineContentRange(ns, at: sel.location))
        guard listMarker(in: firstLine) != nil else { return false }

        let linesRange = ns.lineRange(for: sel)
        let chunk = ns.substring(with: linesRange)
        let trailingNewline = chunk.hasSuffix("\n")
        var lines = (trailingNewline ? String(chunk.dropLast()) : chunk).components(separatedBy: "\n")
        var firstDelta = 0
        var totalDelta = 0
        for i in lines.indices where listMarker(in: lines[i]) != nil {
            var delta = 0
            if outdent {
                if lines[i].hasPrefix("  ") { lines[i].removeFirst(2); delta = -2 }
                else if lines[i].hasPrefix("\t") || lines[i].hasPrefix(" ") { lines[i].removeFirst(); delta = -1 }
            } else {
                lines[i] = "  " + lines[i]
                delta = 2
            }
            if i == 0 { firstDelta = delta }
            totalDelta += delta
        }
        guard totalDelta != 0 || !outdent else { return true }   // nothing to outdent; swallow
        let replacement = lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        let firstLineStart = linesRange.location
        let newLoc = max(firstLineStart, sel.location + firstDelta)
        let newLen = sel.length == 0 ? 0 : max(0, sel.length + totalDelta - firstDelta)
        replace(tv, range: linesRange, with: replacement, select: NSRange(location: newLoc, length: newLen),
                actionName: outdent ? "Outdent" : "Indent")
        return true
    }

    // Formatting row: toggle the prefix of the current line(s).
    static func togglePrefix(_ kind: MarkdownLinePrefix, in tv: NSTextView) {
        guard tv.isEditable, !tv.hasMarkedText() else { return }
        let sel = tv.selectedRange()
        let ns = tv.string as NSString
        let linesRange = ns.lineRange(for: sel)
        let chunk = ns.substring(with: linesRange)
        let trailingNewline = chunk.hasSuffix("\n")
        var lines = (trailingNewline ? String(chunk.dropLast()) : chunk).components(separatedBy: "\n")
        let multi = lines.count > 1

        func strip(_ line: String) -> (indent: String, content: String) {
            let lns = line as NSString
            if let h = headingRE.firstMatch(in: line, range: NSRange(location: 0, length: lns.length)) {
                return ("", lns.substring(from: h.range.length))
            }
            if let m = listMarker(in: line) {
                return (m.indent, lns.substring(from: m.length))
            }
            return ("", line)
        }
        func has(_ line: String) -> Bool {
            switch kind {
            case .h1: return line.hasPrefix("# ")
            case .h2: return line.hasPrefix("## ")
            case .bullet:
                guard let m = listMarker(in: line), !m.hasCheckbox, case .bullet = m.kind else { return false }
                return true
            case .numbered:
                guard let m = listMarker(in: line), case .ordered = m.kind else { return false }
                return true
            case .task:
                return listMarker(in: line)?.hasCheckbox == true
            }
        }

        let candidates = lines.indices.filter { !multi || !lines[$0].trimmingCharacters(in: .whitespaces).isEmpty }
        guard !candidates.isEmpty else { return }
        let removing = candidates.allSatisfy { has(lines[$0]) }

        var counter = 1
        var firstDelta = 0
        for i in candidates {
            let before = (lines[i] as NSString).length
            let (indent, content) = strip(lines[i])
            if removing {
                lines[i] = (kind == .h1 || kind == .h2) ? content : indent + content
            } else {
                switch kind {
                case .h1: lines[i] = "# " + content
                case .h2: lines[i] = "## " + content
                case .bullet: lines[i] = indent + "- " + content
                case .numbered: lines[i] = indent + "\(counter). " + content; counter += 1
                case .task: lines[i] = indent + "- [ ] " + content
                }
            }
            if i == 0 { firstDelta = (lines[i] as NSString).length - before }
        }

        let replacement = lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        let select: NSRange
        if multi {
            let len = (replacement as NSString).length - (trailingNewline ? 1 : 0)
            select = NSRange(location: linesRange.location, length: max(0, len))
        } else {
            let lineLen = (lines[0] as NSString).length
            let loc = min(max(linesRange.location, sel.location + firstDelta), linesRange.location + lineLen)
            select = NSRange(location: loc, length: min(sel.length, linesRange.location + lineLen - loc))
        }
        replace(tv, range: linesRange, with: replacement, select: select, actionName: kind.help)
    }

    // ⌘B / ⌘I: wrap (or unwrap) the selection in `marker`.
    static func wrapSelection(in tv: NSTextView, marker: String) {
        guard tv.isEditable, !tv.hasMarkedText() else { return }
        let sel = tv.selectedRange()
        let ns = tv.string as NSString
        let m = (marker as NSString).length
        let actionName = marker == "**" ? "Bold" : "Italic"

        // Already wrapped just outside the selection → unwrap.
        if sel.location >= m, NSMaxRange(sel) + m <= ns.length,
           ns.substring(with: NSRange(location: sel.location - m, length: m)) == marker,
           ns.substring(with: NSRange(location: NSMaxRange(sel), length: m)) == marker {
            let outer = NSRange(location: sel.location - m, length: sel.length + 2 * m)
            replace(tv, range: outer, with: ns.substring(with: sel),
                    select: NSRange(location: sel.location - m, length: sel.length), actionName: actionName)
            return
        }
        // Selection itself includes the markers → unwrap.
        if sel.length >= 2 * m + 1 {
            let s = ns.substring(with: sel)
            if s.hasPrefix(marker), s.hasSuffix(marker) {
                let inner = (s as NSString).substring(with: NSRange(location: m, length: sel.length - 2 * m))
                replace(tv, range: sel, with: inner,
                        select: NSRange(location: sel.location, length: (inner as NSString).length), actionName: actionName)
                return
            }
        }
        let inner = ns.substring(with: sel)
        replace(tv, range: sel, with: marker + inner + marker,
                select: NSRange(location: sel.location + m, length: sel.length), actionName: actionName)
    }
}

// MARK: - Plain note field (highlight notes)

/// A growing, borderless plain-text field with smart substitutions off (SwiftUI's TextField
/// uses the window's shared field editor, whose dash/quote substitution can't be disabled
/// per field). Return inserts a newline; Escape ends editing.
struct PlainNoteField: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat = 13
    var color: NSColor = Theme.nsMuted

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> PlainFieldTextView {
        let tv = PlainFieldTextView(usingTextLayoutManager: false)
        MarkdownEditing.configurePlain(tv)
        tv.isContinuousSpellCheckingEnabled = false
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: 240, height: CGFloat.greatestFiniteMagnitude)
        tv.insertionPointColor = Theme.nsInk
        tv.selectedTextAttributes = [.backgroundColor: Theme.nsAccent.withAlphaComponent(0.22)]
        let attrs = attributes
        tv.typingAttributes = attrs
        tv.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attrs))
        tv.delegate = context.coordinator
        context.coordinator.lastSynced = text
        return tv
    }

    var attributes: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 2
        return [.font: Theme.nsRounded(fontSize), .foregroundColor: color, .paragraphStyle: p]
    }

    func updateNSView(_ tv: PlainFieldTextView, context: Context) {
        context.coordinator.parent = self
        guard text != tv.string, text != context.coordinator.lastSynced else { return }
        let sel = tv.selectedRange()
        tv.textStorage?.setAttributedString(NSAttributedString(string: text, attributes: attributes))
        context.coordinator.lastSynced = text
        let len = (text as NSString).length
        tv.setSelectedRange(NSRange(location: min(sel.location, len), length: 0))
        tv.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PlainFieldTextView, context: Context) -> CGSize? {
        var width = proposal.width ?? 240
        if !width.isFinite || width <= 0 { width = 240 }
        guard let lm = nsView.layoutManager, let tc = nsView.textContainer else { return nil }
        tc.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        lm.ensureLayout(for: tc)
        let font = Theme.nsRounded(fontSize)
        let lineHeight = lm.defaultLineHeight(for: font)
        let used = lm.usedRect(for: tc).height
        return CGSize(width: width, height: ceil(max(used, lineHeight)))
    }

    static func dismantleNSView(_ tv: PlainFieldTextView, coordinator: Coordinator) {
        tv.delegate = nil
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainNoteField
        var lastSynced = ""
        init(_ parent: PlainNoteField) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            let s = tv.string
            lastSynced = s
            if parent.text != s { parent.text = s }
            tv.invalidateIntrinsicContentSize()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                textView.window?.makeFirstResponder(nil)
                return true
            }
            if commandSelector == #selector(NSResponder.insertTab(_:)) {
                textView.window?.selectNextKeyView(nil)
                return true
            }
            if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
                textView.window?.selectPreviousKeyView(nil)
                return true
            }
            return false
        }
    }
}

final class PlainFieldTextView: NSTextView {
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        if let tc = textContainer, abs(tc.containerSize.width - newSize.width) > 0.5 {
            tc.containerSize = NSSize(width: newSize.width, height: CGFloat.greatestFiniteMagnitude)
        }
    }

    // Scroll gestures belong to the enclosing panel, not this field.
    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }
}
