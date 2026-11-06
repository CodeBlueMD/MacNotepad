#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit

/// Native AppKit NSTextView wrapped for SwiftUI with syntax highlighting, column selection (Option+Drag),
/// zoom scaling, and live cursor/selection tracking.
public struct CodeEditorView: NSViewRepresentable {
    @Binding public var tab: DocumentTab
    public var preferences: EditorPreferences
    public var searchHighlights: [NSRange]

    public init(
        tab: Binding<DocumentTab>,
        preferences: EditorPreferences,
        searchHighlights: [NSRange] = []
    ) {
        self._tab = tab
        self.preferences = preferences
        self.searchHighlights = searchHighlights
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = !preferences.wordWrap
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true

        let textView = NSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = preferences.spellCheckEnabled
        textView.usesFindBar = false
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.autoresizingMask = [.width, .height]
        textView.delegate = context.coordinator

        scrollView.documentView = textView
        context.coordinator.textView = textView
        applyStylingAndHighlighting(to: textView)
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.string != tab.content {
            context.coordinator.isProgrammaticUpdate = true
            let selectedRanges = textView.selectedRanges
            textView.string = tab.content
            textView.selectedRanges = selectedRanges
            context.coordinator.isProgrammaticUpdate = false
        }
        textView.isContinuousSpellCheckingEnabled = preferences.spellCheckEnabled
        applyStylingAndHighlighting(to: textView)
    }

    private func applyStylingAndHighlighting(to textView: NSTextView) {
        let isDark = preferences.theme != .lightMica
        textView.backgroundColor = isDark
            ? NSColor(calibratedRed: 0.11, green: 0.12, blue: 0.15, alpha: 1.0)
            : NSColor(calibratedRed: 0.98, green: 0.98, blue: 0.99, alpha: 1.0)
        textView.insertionPointColor = isDark ? .systemCyan : .systemBlue

        let effectiveSize = CGFloat(preferences.fontSize) * CGFloat(preferences.zoomPercentage) / 100.0
        let font = NSFont.monospacedSystemFont(ofSize: max(9, effectiveSize), weight: .regular)
        let baseColor = isDark
            ? NSColor(calibratedWhite: 0.92, alpha: 1.0)
            : NSColor(calibratedWhite: 0.12, alpha: 1.0)

        guard let storage = textView.textStorage else { return }
        let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
        storage.beginEditing()
        storage.setAttributes([
            .font: font,
            .foregroundColor: baseColor
        ], range: fullRange)

        // Keyword highlighting
        let keywords = SyntaxHighlighter.keywords(for: tab.language)
        if !keywords.isEmpty {
            let pattern = "\\b(" + keywords.joined(separator: "|") + ")\\b"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let keywordColor = isDark
                    ? NSColor(calibratedRed: 0.48, green: 0.67, blue: 0.98, alpha: 1.0)
                    : NSColor(calibratedRed: 0.10, green: 0.34, blue: 0.78, alpha: 1.0)
                for match in regex.matches(in: textView.string, range: fullRange) {
                    storage.addAttribute(.foregroundColor, value: keywordColor, range: match.range)
                }
            }
        }

        // String literal highlighting
        if let strRegex = try? NSRegularExpression(pattern: "\"[^\"\\\\]*(?:\\\\.[^\"\\\\]*)*\"") {
            let stringColor = isDark
                ? NSColor(calibratedRed: 0.64, green: 0.86, blue: 0.56, alpha: 1.0)
                : NSColor(calibratedRed: 0.15, green: 0.52, blue: 0.24, alpha: 1.0)
            for match in strRegex.matches(in: textView.string, range: fullRange) {
                storage.addAttribute(.foregroundColor, value: stringColor, range: match.range)
            }
        }

        // Comment highlighting
        if let commentRegex = try? NSRegularExpression(pattern: "(//.*$|#.*$)", options: [.anchorsMatchLines]) {
            let commentColor = isDark
                ? NSColor(calibratedWhite: 0.50, alpha: 1.0)
                : NSColor(calibratedWhite: 0.45, alpha: 1.0)
            for match in commentRegex.matches(in: textView.string, range: fullRange) {
                storage.addAttribute(.foregroundColor, value: commentColor, range: match.range)
            }
        }

        // Search match highlights
        let highlightBg = NSColor.systemYellow.withAlphaComponent(0.35)
        for range in searchHighlights where range.location + range.length <= fullRange.length {
            storage.addAttribute(.backgroundColor, value: highlightBg, range: range)
        }

        storage.endEditing()
    }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView
        weak var textView: NSTextView?
        var isProgrammaticUpdate = false

        init(_ parent: CodeEditorView) {
            self.parent = parent
        }

        public func textDidChange(_ notification: Notification) {
            guard !isProgrammaticUpdate, let textView = notification.object as? NSTextView else { return }
            parent.tab.content = textView.string
            parent.tab.isDirty = true
            parent.tab.lastModified = Date()
            updateCursorPosition(textView)
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            updateCursorPosition(textView)
        }

        private func updateCursorPosition(_ textView: NSTextView) {
            let range = textView.selectedRange()
            let nsString = textView.string as NSString
            let safeLoc = min(range.location, nsString.length)
            let prefix = nsString.substring(to: safeLoc)
            let lines = prefix.components(separatedBy: .newlines)
            parent.tab.cursorLine = max(1, lines.count)
            parent.tab.cursorColumn = (lines.last?.count ?? 0) + 1
            parent.tab.selectedCharacterCount = range.length
        }
    }
}
#endif
