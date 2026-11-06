#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit

/// Custom NSTextView subclass that draws a subtle active-line highlight (Notepad++ style)
/// and forwards app-level Cmd shortcuts cleanly to SwiftUI even while typing.
public final class EditorTextView: NSTextView {
    public var currentLineHighlightColor: NSColor = NSColor.white.withAlphaComponent(0.04)

    public override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        guard let layoutManager = self.layoutManager,
              let textContainer = self.textContainer else { return }

        let selected = self.selectedRange()
        let nsString = self.string as NSString
        guard selected.location <= nsString.length else { return }

        let lineRange = nsString.lineRange(for: NSRange(location: selected.location, length: 0))
        let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
        var lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        lineRect.origin.x = 0
        lineRect.origin.y += self.textContainerInset.height
        lineRect.size.width = self.bounds.width
        lineRect.size.height = max(19, lineRect.size.height)

        currentLineHighlightColor.setFill()
        lineRect.fill()
    }
}

/// Native AppKit NSTextView wrapped for SwiftUI with rich Notepad++ / Xcode Dark syntax highlighting,
/// active-line highlight, dynamic word-wrap, zoom scaling, and live cursor/selection tracking.
public struct CodeEditorView: NSViewRepresentable {
    @Binding public var tab: DocumentTab
    public var preferences: EditorPreferences
    public var searchHighlights: [NSRange]
    public var focusedMatchRange: NSRange?

    public init(
        tab: Binding<DocumentTab>,
        preferences: EditorPreferences,
        searchHighlights: [NSRange] = [],
        focusedMatchRange: NSRange? = nil
    ) {
        self._tab = tab
        self.preferences = preferences
        self.searchHighlights = searchHighlights
        self.focusedMatchRange = focusedMatchRange
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

        let textView = EditorTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = preferences.spellCheckEnabled
        textView.usesFindBar = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.autoresizingMask = [.width, .height]
        textView.delegate = context.coordinator

        configureWordWrap(on: textView, scrollView: scrollView, wordWrap: preferences.wordWrap)

        scrollView.documentView = textView
        context.coordinator.textView = textView
        applyStylingAndHighlighting(to: textView)
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? EditorTextView else { return }
        if textView.string != tab.content {
            context.coordinator.isProgrammaticUpdate = true
            let selectedRanges = textView.selectedRanges
            textView.string = tab.content
            textView.selectedRanges = selectedRanges
            context.coordinator.isProgrammaticUpdate = false
        }
        textView.isContinuousSpellCheckingEnabled = preferences.spellCheckEnabled
        configureWordWrap(on: textView, scrollView: scrollView, wordWrap: preferences.wordWrap)
        applyStylingAndHighlighting(to: textView)

        if let targetRange = focusedMatchRange,
           targetRange.location + targetRange.length <= (textView.string as NSString).length,
           context.coordinator.lastFocusedMatchRange != targetRange {
            context.coordinator.lastFocusedMatchRange = targetRange
            textView.scrollRangeToVisible(targetRange)
        }
    }

    private func configureWordWrap(on textView: NSTextView, scrollView: NSScrollView, wordWrap: Bool) {
        scrollView.hasHorizontalScroller = !wordWrap
        textView.isHorizontallyResizable = !wordWrap
        if wordWrap {
            textView.textContainer?.widthTracksTextView = true
            textView.textContainer?.containerSize = NSSize(
                width: max(200, scrollView.contentSize.width),
                height: CGFloat.greatestFiniteMagnitude
            )
        } else {
            textView.textContainer?.widthTracksTextView = false
            textView.textContainer?.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            )
        }
    }

    private func resolveEditorFont(size: CGFloat) -> NSFont {
        if preferences.fontFamily != "SF Mono",
           let custom = NSFont(name: preferences.fontFamily, size: size) {
            return custom
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private func applyStylingAndHighlighting(to textView: EditorTextView) {
        let isDark = preferences.theme != .light
        textView.backgroundColor = isDark
            ? NSColor(calibratedRed: 0.098, green: 0.106, blue: 0.125, alpha: 1.0) // #191B20
            : NSColor(calibratedRed: 0.98, green: 0.98, blue: 0.99, alpha: 1.0)
        textView.currentLineHighlightColor = isDark
            ? NSColor.white.withAlphaComponent(0.035)
            : NSColor.black.withAlphaComponent(0.035)
        textView.insertionPointColor = isDark ? .systemCyan : .systemBlue

        let effectiveSize = max(10, CGFloat(preferences.fontSize) * CGFloat(preferences.zoomPercentage) / 100.0)
        let font = resolveEditorFont(size: effectiveSize)
        let boldFont = NSFont.monospacedSystemFont(ofSize: effectiveSize, weight: .semibold)
        let baseColor = isDark
            ? NSColor(calibratedRed: 0.86, green: 0.88, blue: 0.92, alpha: 1.0)
            : NSColor(calibratedWhite: 0.14, alpha: 1.0)

        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 3.0

        guard let storage = textView.textStorage else { return }
        let nsText = textView.string as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)

        storage.beginEditing()
        storage.setAttributes([
            .font: font,
            .foregroundColor: baseColor,
            .paragraphStyle: paragraphStyle
        ], range: fullRange)

        // 1. Function / Method calls and declarations (cyan/teal like AppEngine.swift mockup)
        if let funcRegex = try? NSRegularExpression(pattern: "\\b([A-Za-z_][A-Za-z0-9_]*)(?=\\s*\\()") {
            let funcColor = isDark
                ? NSColor(calibratedRed: 0.35, green: 0.83, blue: 0.90, alpha: 1.0) // #5AD4E6
                : NSColor(calibratedRed: 0.05, green: 0.45, blue: 0.65, alpha: 1.0)
            for match in funcRegex.matches(in: textView.string, range: fullRange) {
                storage.addAttribute(.foregroundColor, value: funcColor, range: match.range(at: 1))
            }
        }

        // 2. Capitalized Types / Classes (Foundation, AppEngine)
        if let typeRegex = try? NSRegularExpression(pattern: "\\b([A-Z][A-Za-z0-9_]*)\\b") {
            let typeColor = isDark
                ? NSColor(calibratedRed: 0.48, green: 0.85, blue: 0.92, alpha: 1.0)
                : NSColor(calibratedRed: 0.12, green: 0.42, blue: 0.68, alpha: 1.0)
            for match in typeRegex.matches(in: textView.string, range: fullRange) {
                storage.addAttribute(.foregroundColor, value: typeColor, range: match.range(at: 1))
            }
        }

        // 3. Language Keywords (pink/magenta like `import`, `class`, `var`, `func`, `return`)
        let keywords = SyntaxHighlighter.keywords(for: tab.language)
        if !keywords.isEmpty {
            let pattern = "\\b(" + keywords.joined(separator: "|") + ")\\b"
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let keywordColor = isDark
                    ? NSColor(calibratedRed: 1.0, green: 0.42, blue: 0.70, alpha: 1.0) // #FF6BB3
                    : NSColor(calibratedRed: 0.68, green: 0.12, blue: 0.54, alpha: 1.0)
                for match in regex.matches(in: textView.string, range: fullRange) {
                    storage.addAttributes([
                        .foregroundColor: keywordColor,
                        .font: boldFont
                    ], range: match.range)
                }
            }
        }

        // 4. Booleans, nil, null, self, numbers (purple/blue)
        if let literalRegex = try? NSRegularExpression(pattern: "\\b(true|false|nil|null|self|\\d+(?:\\.\\d+)?)\\b") {
            let literalColor = isDark
                ? NSColor(calibratedRed: 0.68, green: 0.55, blue: 0.98, alpha: 1.0) // #AD8CFA
                : NSColor(calibratedRed: 0.40, green: 0.20, blue: 0.78, alpha: 1.0)
            for match in literalRegex.matches(in: textView.string, range: fullRange) {
                storage.addAttribute(.foregroundColor, value: literalColor, range: match.range)
            }
        }

        // 5. String literals (warm orange/salmon `"Engine starting..."`)
        if let strRegex = try? NSRegularExpression(pattern: "\"[^\"\\\\]*(?:\\\\.[^\"\\\\]*)*\"") {
            let stringColor = isDark
                ? NSColor(calibratedRed: 0.92, green: 0.58, blue: 0.42, alpha: 1.0) // #EB946B
                : NSColor(calibratedRed: 0.76, green: 0.28, blue: 0.14, alpha: 1.0)
            for match in strRegex.matches(in: textView.string, range: fullRange) {
                storage.addAttribute(.foregroundColor, value: stringColor, range: match.range)
            }
        }

        // 6. Comments (`// ...` and `# ...`)
        if let commentRegex = try? NSRegularExpression(pattern: "(//.*$|#.*$)", options: [.anchorsMatchLines]) {
            let commentColor = isDark
                ? NSColor(calibratedRed: 0.45, green: 0.52, blue: 0.58, alpha: 1.0)
                : NSColor(calibratedWhite: 0.45, alpha: 1.0)
            for match in commentRegex.matches(in: textView.string, range: fullRange) {
                storage.addAttributes([
                    .foregroundColor: commentColor,
                    .font: font
                ], range: match.range)
            }
        }

        // 7. Search match highlights
        let matchBg = NSColor.systemYellow.withAlphaComponent(0.28)
        let activeMatchBg = NSColor.systemCyan.withAlphaComponent(0.45)
        for range in searchHighlights where range.location + range.length <= fullRange.length {
            let isFocused = (focusedMatchRange == range)
            storage.addAttribute(.backgroundColor, value: isFocused ? activeMatchBg : matchBg, range: range)
        }

        storage.endEditing()
        textView.needsDisplay = true
    }

    public final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditorView
        weak var textView: EditorTextView?
        var isProgrammaticUpdate = false
        var lastFocusedMatchRange: NSRange?

        init(_ parent: CodeEditorView) {
            self.parent = parent
        }

        public func textDidChange(_ notification: Notification) {
            guard !isProgrammaticUpdate, let textView = notification.object as? EditorTextView else { return }
            parent.tab.content = textView.string
            parent.tab.isDirty = true
            parent.tab.lastModified = Date()
            updateCursorPosition(textView)
            textView.needsDisplay = true
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? EditorTextView else { return }
            updateCursorPosition(textView)
            textView.needsDisplay = true
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
