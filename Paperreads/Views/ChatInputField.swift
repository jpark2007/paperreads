import SwiftUI
import AppKit

/// Native multiline composer: ⏎ sends, ⇧⏎ / ⌥⏎ insert a newline, IME composition is respected.
/// Grows with its content between `minHeight` and `maxHeight`.
struct ChatInputField: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat
    var focusToken: Int
    var minHeight: CGFloat = 36
    var maxHeight: CGFloat = 168
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.delegate = context.coordinator
        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = false
        tv.isAutomaticQuoteSubstitutionEnabled = false   // keep LaTeX / code intact
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = true
        tv.font = Theme.nsRounded(14)
        tv.textColor = Theme.nsInk
        tv.insertionPointColor = Theme.nsAccent
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.textContainerInset = NSSize(width: 0, height: 8)
        tv.textContainer?.lineFragmentPadding = 0
        tv.typingAttributes = [.font: Theme.nsRounded(14), .foregroundColor: Theme.nsInk]
        tv.string = text
        context.coordinator.textView = tv
        context.coordinator.lastFocusToken = focusToken
        tv.postsFrameChangedNotifications = true
        context.coordinator.frameObserver = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification, object: tv, queue: .main
        ) { [weak coordinator = context.coordinator] _ in
            coordinator?.recalcHeight()
        }
        DispatchQueue.main.async { context.coordinator.recalcHeight() }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let tv = c.textView else { return }
        if tv.string != text && !tv.hasMarkedText() {
            tv.string = text
            tv.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
            c.recalcHeight()
        }
        if c.lastFocusToken != focusToken {
            c.lastFocusToken = focusToken
            DispatchQueue.main.async {
                tv.window?.makeFirstResponder(tv)
                tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            }
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        if let observer = coordinator.frameObserver {
            NotificationCenter.default.removeObserver(observer)
            coordinator.frameObserver = nil
        }
        coordinator.textView?.delegate = nil
        coordinator.textView = nil
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInputField
        weak var textView: NSTextView?
        var lastFocusToken = 0
        var frameObserver: NSObjectProtocol?

        init(parent: ChatInputField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = textView else { return }
            parent.text = tv.string
            recalcHeight()
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) else { return false }
            if textView.hasMarkedText() { return false }
            let flags = NSApp.currentEvent?.modifierFlags ?? []
            if flags.contains(.shift) || flags.contains(.option) {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            parent.onSubmit()
            return true
        }

        func recalcHeight() {
            guard let tv = textView, let lm = tv.layoutManager, let container = tv.textContainer else { return }
            lm.ensureLayout(for: container)
            let used = lm.usedRect(for: container).height
            let lineHeight = lm.defaultLineHeight(for: tv.font ?? Theme.nsRounded(14))
            let content = max(used, lineHeight) + tv.textContainerInset.height * 2
            let clamped = min(max(content.rounded(.up), parent.minHeight), parent.maxHeight)
            if abs(clamped - parent.height) > 0.5 {
                let binding = parent.$height
                DispatchQueue.main.async { binding.wrappedValue = clamped }
            }
        }
    }
}
