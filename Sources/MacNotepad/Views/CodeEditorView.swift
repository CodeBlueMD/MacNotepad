#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit

extension AppTheme {
    /// Whether the editor should use dark colors (System follows macOS appearance).
    var isDark: Bool {
        switch self {
        case .light: return false
        case .system: return NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        default: return true
        }
    }
}

/// Line-number gutter attached to the editor's scroll view, so it scrolls, zooms and wraps with the text.
/// Also shows fold chevrons; clicking one folds or unfolds that block.
final class LineNumberRulerView: NSRulerView {
    var numberColor = NSColor.white.withAlphaComponent(0.35)
    var currentNumberColor = NSColor.white
    var gutterBackground = NSColor.black
    var numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    var showNumbers = true

    private var editor: EditorTextView? { clientView as? EditorTextView }

    init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 40
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        gutterBackground.setFill()
        bounds.fill()

        guard let textView = editor,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer,
              let storage = textView.textStorage else { return }

        let text = textView.string as NSString
        let inset = textView.textContainerInset
        let visibleRect = textView.visibleRect.offsetBy(dx: -inset.width, dy: -inset.height)
        let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let visibleChars = layoutManager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        let cursorLine = TextMetrics.lineNumber(at: textView.selectedRange().location, in: text)
        let yOffset = convert(NSPoint.zero, from: textView).y + inset.height
        let foldStarts = Dictionary(textView.foldRegions.map { ($0.startLine, $0) }, uniquingKeysWith: { a, _ in a })
        let hasFolds = textView.hasFolds

        var lineNumber = TextMetrics.lineNumber(at: visibleChars.location, in: text)
        var index = text.lineRange(for: NSRange(location: visibleChars.location, length: 0)).location

        func draw(_ number: Int, fragmentRect: NSRect) {
            let isCurrent = number == cursorLine
            if showNumbers {
                let label = "\(number)" as NSString
                let attributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: isCurrent ? currentNumberColor : numberColor]
                let size = label.size(withAttributes: attributes)
                if size.width + 26 > ruleThickness { ruleThickness = ceil(size.width + 26) }
                let y = fragmentRect.minY + yOffset + min(fragmentRect.height - size.height, 6) / 2
                label.draw(at: NSPoint(x: ruleThickness - size.width - 16, y: y), withAttributes: attributes)
            }
            if let region = foldStarts[number] {
                let folded = textView.isFolded(region)
                let symbol = NSImage(systemSymbolName: folded ? "chevron.right" : "chevron.down", accessibilityDescription: nil)
                let config = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
                if let image = symbol?.withSymbolConfiguration(config) {
                    let size = image.size
                    let lineHeight = min(fragmentRect.height, numberFont.pointSize * 1.6)
                    let origin = NSPoint(x: ruleThickness - size.width - 4, y: fragmentRect.minY + yOffset + (lineHeight - size.height) / 2)
                    (folded ? currentNumberColor : numberColor).set()
                    image.isTemplate = true
                    let tinted = NSImage(size: size, flipped: false) { r in
                        image.draw(in: r)
                        (folded ? self.currentNumberColor : self.numberColor).set()
                        r.fill(using: .sourceAtop)
                        return true
                    }
                    tinted.draw(in: NSRect(origin: origin, size: size))
                }
            }
        }

        while index < NSMaxRange(visibleChars) {
            if hasFolds, index > 0, let _ = storage.attribute(.macNotepadFolded, at: index - 1, effectiveRange: nil),
               storage.attribute(.macNotepadFolded, at: index, effectiveRange: nil) != nil {
                // Skip a hidden block in one step, counting the lines inside it.
                var hidden = NSRange()
                _ = storage.attribute(.macNotepadFolded, at: index, longestEffectiveRange: &hidden, in: NSRange(location: 0, length: storage.length))
                let skipped = text.substring(with: NSRange(location: index, length: NSMaxRange(hidden) - index)).filter { $0 == "\n" }.count
                lineNumber += skipped
                index = text.lineRange(for: NSRange(location: NSMaxRange(hidden), length: 0)).location
                index = NSMaxRange(text.lineRange(for: NSRange(location: index, length: 0)))
                lineNumber += 1
                continue
            }
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: lineRange.location)
            let fragmentRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            draw(lineNumber, fragmentRect: fragmentRect)
            index = NSMaxRange(lineRange)
            lineNumber += 1
        }

        // Empty document or trailing newline: the caret line has no glyphs of its own.
        if NSMaxRange(visibleChars) >= text.length, layoutManager.extraLineFragmentTextContainer != nil {
            draw(lineNumber, fragmentRect: layoutManager.extraLineFragmentRect)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let textView = editor, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        let point = textView.convert(event.locationInWindow, from: nil)
        let containerPoint = NSPoint(x: 0, y: point.y - textView.textContainerInset.height)
        let glyph = layoutManager.glyphIndex(for: containerPoint, in: container)
        let char = layoutManager.characterIndexForGlyph(at: glyph)
        let line = TextMetrics.lineNumber(at: char, in: textView.string as NSString)
        if textView.foldRegions.contains(where: { $0.startLine == line }) {
            textView.toggleFold(startingAtLine: line)
        } else {
            // Click on a line number selects the line.
            let range = (textView.string as NSString).lineRange(for: NSRange(location: char, length: 0))
            textView.setSelectedRange(range)
            textView.window?.makeFirstResponder(textView)
        }
    }
}

/// Native AppKit NSTextView wrapped for SwiftUI with syntax highlighting, live Markdown, folding,
/// multi-cursor editing, a line-number gutter, word-wrap, zoom and cursor tracking.
public struct CodeEditorView: NSViewRepresentable {
    @Binding public var tab: DocumentTab
    public var preferences: EditorPreferences
    public var searchHighlights: [NSRange]
    public var focusedMatchRange: NSRange?
    /// Line to scroll to (set by the outline panel); each new request id is honoured once.
    public var revealRequest: RevealRequest?

    public struct RevealRequest: Equatable {
        public let line: Int
        public let id = UUID()
        public init(line: Int) { self.line = line }
    }

    public init(
        tab: Binding<DocumentTab>,
        preferences: EditorPreferences,
        searchHighlights: [NSRange] = [],
        focusedMatchRange: NSRange? = nil,
        revealRequest: RevealRequest? = nil
    ) {
        self._tab = tab
        self.preferences = preferences
        self.searchHighlights = searchHighlights
        self.focusedMatchRange = focusedMatchRange
        self.revealRequest = revealRequest
    }

    /// Documents above this size (UTF-16 units) open in a fast plain mode.
    static let largeFileThreshold = 2_000_000

    /// Everything that requires re-styling the whole document when it changes.
    struct StyleKey: Equatable {
        var language: SyntaxLanguage
        var isDark: Bool
        var fontFamily: String
        var effectiveFontSize: CGFloat
        var liveMarkdown: Bool
        var isLarge: Bool
    }

    /// One undo history per tab, kept while the tab is open so switching tabs neither loses nor mixes them.
    private static var undoManagers: [UUID: UndoManager] = [:]

    /// Live editors, so pending large-file edits can be flushed before saving or closing.
    private static let liveCoordinators = NSHashTable<Coordinator>.weakObjects()

    static func flushPendingEdits() {
        for coordinator in liveCoordinators.allObjects { coordinator.flushPendingSync() }
    }

    static func forgetUndoHistory(for tabID: UUID) {
        undoManagers.removeValue(forKey: tabID)
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
        textView.importsGraphics = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = preferences.spellCheckEnabled
        textView.usesFindBar = false
        textView.textContainerInset = NSSize(width: 14, height: 14)
        textView.autoresizingMask = [.width, .height]
        textView.language = tab.language
        textView.autoCloseBrackets = preferences.autoCloseBrackets
        #if compiler(>=6.0)
        if #available(macOS 15.0, *) {
            // Apple Intelligence Writing Tools (rewrite, proofread, summarize) on supported Macs.
            textView.writingToolsBehavior = .complete
            textView.allowedWritingToolsResultOptions = [.plainText]
        }
        #endif

        let isLarge = (tab.content as NSString).length > Self.largeFileThreshold
        textView.layoutManager?.allowsNonContiguousLayout = isLarge
        textView.layoutManager?.delegate = context.coordinator

        configureWordWrap(on: textView, scrollView: scrollView, wordWrap: preferences.wordWrap)

        scrollView.documentView = textView
        let ruler = LineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        ruler.showNumbers = preferences.showLineNumbers

        let coordinator = context.coordinator
        Self.liveCoordinators.add(coordinator)
        coordinator.textView = textView
        coordinator.ruler = ruler
        coordinator.undoManager = Self.undoManagers[tab.id] ?? {
            let manager = UndoManager()
            Self.undoManagers[tab.id] = manager
            return manager
        }()
        textView.textStorage?.delegate = coordinator
        textView.delegate = coordinator
        textView.onFoldingChanged = { [weak ruler] in ruler?.needsDisplay = true }

        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator,
            selector: #selector(Coordinator.scrollViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        applyStyle(to: textView, coordinator: coordinator)
        let savedLine = tab.cursorLine, savedColumn = tab.cursorColumn
        coordinator.isProgrammaticUpdate = true
        textView.string = tab.content
        let caret = caretLocation(line: savedLine, column: savedColumn, in: textView.string as NSString)
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        coordinator.isProgrammaticUpdate = false
        coordinator.lastSyncedContent = tab.content
        coordinator.refreshFoldRegions()
        textView.scrollRangeToVisible(NSRange(location: caret, length: 0))
        applySearchHighlights(to: textView)
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? EditorTextView else { return }
        let coordinator = context.coordinator
        coordinator.parent = self

        // `lastSyncedContent` shares storage with what the editor last published, so this is usually O(1).
        if tab.content != coordinator.lastSyncedContent {
            // Programmatic edit (text tools, replace all, reload): route through the text system so it is undoable.
            coordinator.flushPendingSync()
            let fullRange = NSRange(location: 0, length: (textView.string as NSString).length)
            let selection = textView.selectedRange()
            coordinator.isProgrammaticUpdate = true
            if textView.shouldChangeText(in: fullRange, replacementString: tab.content) {
                textView.textStorage?.replaceCharacters(in: fullRange, with: tab.content)
                textView.didChangeText()
            }
            coordinator.isProgrammaticUpdate = false
            coordinator.lastSyncedContent = tab.content
            let length = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
            coordinator.refreshFoldRegions()
        }

        textView.language = tab.language
        textView.autoCloseBrackets = preferences.autoCloseBrackets
        textView.isContinuousSpellCheckingEnabled = preferences.spellCheckEnabled
        if textView.layoutManager?.showsInvisibleCharacters != preferences.showWhitespace {
            textView.layoutManager?.showsInvisibleCharacters = preferences.showWhitespace
        }
        if coordinator.ruler?.showNumbers != preferences.showLineNumbers {
            coordinator.ruler?.showNumbers = preferences.showLineNumbers
            coordinator.ruler?.ruleThickness = preferences.showLineNumbers ? 40 : 18
            coordinator.ruler?.needsDisplay = true
        }
        configureWordWrap(on: textView, scrollView: scrollView, wordWrap: preferences.wordWrap)
        if applyStyle(to: textView, coordinator: coordinator) { coordinator.refreshFoldRegions() }
        applySearchHighlights(to: textView)

        if let targetRange = focusedMatchRange,
           NSMaxRange(targetRange) <= (textView.string as NSString).length,
           coordinator.lastFocusedMatchRange != targetRange {
            coordinator.lastFocusedMatchRange = targetRange
            textView.scrollRangeToVisible(targetRange)
        }
        if let request = revealRequest, coordinator.lastRevealID != request.id {
            coordinator.lastRevealID = request.id
            let line = request.line
            let location = caretLocation(line: line, column: 1, in: textView.string as NSString)
            textView.setSelectedRange(NSRange(location: location, length: 0))
            textView.scrollRangeToVisible(NSRange(location: location, length: 0))
            if let visible = textView.enclosingScrollView?.contentView, let lm = textView.layoutManager {
                // Put the heading near the top rather than the bottom edge.
                let glyph = lm.glyphIndexForCharacter(at: min(location, max(0, (textView.string as NSString).length - 1)))
                let rect = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                visible.scroll(to: NSPoint(x: 0, y: max(0, rect.minY - 40)))
                textView.enclosingScrollView?.reflectScrolledClipView(visible)
            }
            textView.window?.makeFirstResponder(textView)
        }
    }

    public static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.flushPendingSync()
        NotificationCenter.default.removeObserver(coordinator)
    }

    func caretLocation(line: Int, column: Int, in text: NSString) -> Int {
        var location = 0
        var currentLine = 1
        while currentLine < line, location < text.length {
            let range = text.range(of: "\n", range: NSRange(location: location, length: text.length - location))
            guard range.location != NSNotFound else { break }
            location = range.location + 1
            currentLine += 1
        }
        let lineEnd = text.lineRange(for: NSRange(location: location, length: 0))
        return min(location + max(0, column - 1), NSMaxRange(lineEnd), text.length)
    }

    private func configureWordWrap(on textView: NSTextView, scrollView: NSScrollView, wordWrap: Bool) {
        guard textView.textContainer?.widthTracksTextView != wordWrap || scrollView.hasHorizontalScroller == wordWrap else { return }
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

    private var styleKey: StyleKey {
        StyleKey(
            language: tab.language,
            isDark: preferences.theme.isDark,
            fontFamily: preferences.fontFamily,
            effectiveFontSize: max(10, CGFloat(preferences.fontSize) * CGFloat(preferences.zoomPercentage) / 100.0),
            liveMarkdown: preferences.liveMarkdownStyling && tab.language == .markdown,
            isLarge: (tab.content as NSString).length > Self.largeFileThreshold
        )
    }

    /// Updates colors/fonts and re-highlights the whole document only when the style actually changed.
    @discardableResult
    private func applyStyle(to textView: EditorTextView, coordinator: Coordinator) -> Bool {
        let key = styleKey
        guard coordinator.styleKey != key else { return false }
        coordinator.styleKey = key
        coordinator.palette = EditorPalette(key: key)
        let palette = coordinator.palette

        textView.backgroundColor = palette.background
        textView.currentLineHighlightColor = palette.currentLine
        textView.insertionPointColor = palette.caret
        textView.typingAttributes = palette.baseAttributes
        textView.selectedTextAttributes = [.backgroundColor: palette.selection]
        textView.textContainer?.lineFragmentPadding = key.liveMarkdown ? 8 : 5
        if let ruler = coordinator.ruler {
            ruler.gutterBackground = palette.background
            ruler.numberColor = palette.lineNumber
            ruler.currentNumberColor = palette.currentLineNumber
            ruler.numberFont = NSFont.monospacedDigitSystemFont(ofSize: max(10, key.effectiveFontSize - 2), weight: .regular)
            ruler.needsDisplay = true
        }

        guard let storage = textView.textStorage else { return true }
        storage.beginEditing()
        coordinator.highlight(storage, in: NSRange(location: 0, length: storage.length))
        storage.endEditing()
        textView.needsDisplay = true
        return true
    }

    /// Search matches are drawn as temporary layout attributes, so they never touch the text storage.
    func applySearchHighlights(to textView: EditorTextView) {
        guard let layoutManager = textView.layoutManager else { return }
        let length = (textView.string as NSString).length
        layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: NSRange(location: 0, length: length))
        let matchBg = NSColor.systemYellow.withAlphaComponent(0.28)
        let activeMatchBg = NSColor.systemCyan.withAlphaComponent(0.45)
        for range in searchHighlights where NSMaxRange(range) <= length {
            layoutManager.addTemporaryAttribute(
                .backgroundColor,
                value: range == focusedMatchRange ? activeMatchBg : matchBg,
                forCharacterRange: range
            )
        }
    }

    public final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate, NSLayoutManagerDelegate {
        var parent: CodeEditorView
        weak var textView: EditorTextView?
        weak var ruler: LineNumberRulerView?
        var undoManager: UndoManager?
        var isProgrammaticUpdate = false
        var lastFocusedMatchRange: NSRange?
        var lastRevealID: UUID?
        var styleKey: StyleKey?
        var palette = EditorPalette(key: StyleKey(language: .plainText, isDark: true, fontFamily: "SF Mono",
                                                  effectiveFontSize: 13, liveMarkdown: false, isLarge: false))
        /// The content most recently pushed to (or received from) the binding.
        var lastSyncedContent = ""
        private var pendingSync: DispatchWorkItem?
        private var pendingFoldRefresh: DispatchWorkItem?
        private var needsFullRestyle = false
        private var occurrenceRanges: [NSRange] = []

        init(_ parent: CodeEditorView) {
            self.parent = parent
        }

        private var isLarge: Bool { styleKey?.isLarge ?? false }

        /// Updates this editor's tab by id, so a closed or reordered tab is never written through a stale index.
        private func updateTab(_ change: (inout DocumentTab) -> Void) {
            let id = parent.tab.id
            MainActor.assumeIsolated {
                let store = WorkspaceStore.shared
                guard let index = store.tabs.firstIndex(where: { $0.id == id }) else { return }
                change(&store.tabs[index])
            }
        }

        /// Folded text must never leak into newly typed characters.
        public func textView(_ textView: NSTextView, shouldChangeTypingAttributes oldAttributes: [String: Any] = [:],
                             toAttributes newAttributes: [NSAttributedString.Key: Any] = [:]) -> [NSAttributedString.Key: Any] {
            var attributes = newAttributes
            attributes.removeValue(forKey: .macNotepadFolded)
            return attributes
        }

        // MARK: Highlighting

        public func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            // Adding or removing a ``` fence changes the styling of everything after it.
            if styleKey?.liveMarkdown == true {
                let old = (textView.string as NSString).substring(with: affectedCharRange)
                if old.contains("```") || (replacementString ?? "").contains("```") { needsFullRestyle = true }
            }
            return true
        }

        /// Re-highlights only the lines touched by an edit, before layout runs.
        public func textStorage(_ textStorage: NSTextStorage, willProcessEditing editedMask: NSTextStorageEditActions,
                                range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            if needsFullRestyle {
                needsFullRestyle = false
                highlight(textStorage, in: NSRange(location: 0, length: textStorage.length))
                return
            }
            let lines = (textStorage.string as NSString).lineRange(for: editedRange)
            highlight(textStorage, in: lines)
        }

        func highlight(_ storage: NSTextStorage, in range: NSRange) {
            guard range.length > 0 else { return }
            let key = styleKey
            // Keep folds across re-styling.
            var folded: [NSRange] = []
            if textView?.hasFolds == true {
                storage.enumerateAttribute(.macNotepadFolded, in: range) { value, r, _ in if value != nil { folded.append(r) } }
            }
            storage.setAttributes(palette.baseAttributes, range: range)
            if key?.isLarge == true {
                // Large files: plain text only, so typing stays instant.
            } else if key?.liveMarkdown == true, let style = palette.markdownStyle {
                MarkdownStyler.style(storage, in: range, style: style)
            } else {
                let language = key?.language ?? parent.tab.language
                SyntaxHighlighter.tokens(in: storage.string, range: range, language: language) { kind, tokenRange in
                    storage.addAttributes(palette.attributes(for: kind), range: tokenRange)
                }
            }
            for r in folded { storage.addAttribute(.macNotepadFolded, value: true, range: r) }
        }

        // MARK: Folding (null glyphs + zero-advance newlines hide folded text)

        public func layoutManager(_ layoutManager: NSLayoutManager, shouldGenerateGlyphs glyphs: UnsafePointer<CGGlyph>,
                                  properties props: UnsafePointer<NSLayoutManager.GlyphProperty>,
                                  characterIndexes charIndexes: UnsafePointer<Int>, font aFont: NSFont,
                                  forGlyphRange glyphRange: NSRange) -> Int {
            guard textView?.hasFolds == true, let storage = layoutManager.textStorage else { return 0 }
            let count = glyphRange.length
            let modified = UnsafeMutablePointer<NSLayoutManager.GlyphProperty>.allocate(capacity: count)
            defer { modified.deallocate() }
            var changed = false
            for i in 0..<count {
                let index = charIndexes[i]
                if index < storage.length, storage.attribute(.macNotepadFolded, at: index, effectiveRange: nil) != nil {
                    modified[i] = .null
                    changed = true
                } else {
                    modified[i] = props[i]
                }
            }
            guard changed else { return 0 }
            layoutManager.setGlyphs(glyphs, properties: modified, characterIndexes: charIndexes, font: aFont, forGlyphRange: glyphRange)
            return count
        }

        public func layoutManager(_ layoutManager: NSLayoutManager, shouldUse action: NSLayoutManager.ControlCharacterAction,
                                  forControlCharacterAt charIndex: Int) -> NSLayoutManager.ControlCharacterAction {
            if textView?.hasFolds == true, let storage = layoutManager.textStorage, charIndex < storage.length,
               storage.attribute(.macNotepadFolded, at: charIndex, effectiveRange: nil) != nil {
                return .zeroAdvancement
            }
            return action
        }

        func refreshFoldRegions() {
            guard let textView else { return }
            textView.foldRegions = isLarge ? [] : FoldingService.regions(in: textView.string, language: parent.tab.language)
            ruler?.needsDisplay = true
        }

        private func scheduleFoldRefresh() {
            pendingFoldRefresh?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.refreshFoldRegions() }
            pendingFoldRefresh = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }

        // MARK: Text changes

        public func undoManager(for view: NSTextView) -> UndoManager? {
            undoManager
        }

        public func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? EditorTextView else { return }
            ruler?.needsDisplay = true
            scheduleFoldRefresh()
            guard !isProgrammaticUpdate else { return }
            if isLarge {
                // Big files: publish the text after a short pause instead of copying megabytes per keystroke.
                pendingSync?.cancel()
                let work = DispatchWorkItem { [weak self] in self?.syncContent() }
                pendingSync = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
                updateTab { if !$0.isDirty { $0.isDirty = true } }
            } else {
                syncContent()
            }
            updateCursorPosition(textView)
        }

        private func syncContent() {
            guard let textView else { return }
            pendingSync = nil
            let content = textView.string
            lastSyncedContent = content
            updateTab {
                $0.content = content
                $0.isDirty = true
                $0.lastModified = Date()
            }
        }

        func flushPendingSync() {
            if let pending = pendingSync {
                pending.cancel()
                syncContent()
            }
        }

        public func textViewDidChangeSelection(_ notification: Notification) {
            guard !isProgrammaticUpdate, let textView = notification.object as? EditorTextView else { return }
            unfoldIfCaretIsHidden(textView)
            updateCursorPosition(textView)
            updateOccurrenceHighlights(textView)
            textView.needsDisplay = true
            ruler?.needsDisplay = true
        }

        private func unfoldIfCaretIsHidden(_ textView: EditorTextView) {
            guard textView.hasFolds, let storage = textView.textStorage else { return }
            let caret = textView.selectedRange().location
            guard caret > 0, caret < storage.length else { return }
            var effective = NSRange()
            if storage.attribute(.macNotepadFolded, at: caret, longestEffectiveRange: &effective,
                                 in: NSRange(location: 0, length: storage.length)) != nil, caret > effective.location {
                textView.setFolded(FoldRegion(startLine: 0, hiddenRange: effective), false)
            }
        }

        @objc func scrollViewDidScroll(_ notification: Notification) {
            ruler?.needsDisplay = true
        }

        /// Notepad++-style: highlight other occurrences of the selected word, and the bracket matching the caret.
        private func updateOccurrenceHighlights(_ textView: EditorTextView) {
            guard let layoutManager = textView.layoutManager else { return }
            if !occurrenceRanges.isEmpty {
                for range in occurrenceRanges where NSMaxRange(range) <= (textView.string as NSString).length {
                    layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
                }
                occurrenceRanges.removeAll()
                parent.applySearchHighlights(to: textView)
            }
            guard !isLarge, textView.selectedRanges.count == 1, let container = textView.textContainer else { return }
            let text = textView.string as NSString
            let selection = textView.selectedRange()
            var ranges: [NSRange] = []

            if selection.length == 0, selection.location > 0 {
                let previous = text.character(at: selection.location - 1)
                if let match = Self.matchingBracket(for: selection.location - 1, char: previous, in: text) {
                    ranges.append(NSRange(location: selection.location - 1, length: 1))
                    ranges.append(NSRange(location: match, length: 1))
                }
            } else if selection.length > 1, selection.length < 100 {
                let needle = text.substring(with: selection)
                if !needle.contains("\n"), needle.trimmingCharacters(in: .whitespaces) == needle {
                    let visibleGlyphs = layoutManager.glyphRange(forBoundingRect: textView.visibleRect, in: container)
                    let visible = layoutManager.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
                    var search = visible
                    while search.length > 0 {
                        let found = text.range(of: needle, options: [], range: search)
                        if found.location == NSNotFound { break }
                        if found != selection { ranges.append(found) }
                        search = NSRange(location: NSMaxRange(found), length: NSMaxRange(visible) - NSMaxRange(found))
                    }
                }
            }
            for range in ranges {
                layoutManager.addTemporaryAttribute(.backgroundColor, value: palette.occurrence, forCharacterRange: range)
            }
            occurrenceRanges = ranges
        }

        static func matchingBracket(for index: Int, char: unichar, in text: NSString) -> Int? {
            let pairs: [unichar: (unichar, Int)] = [0x28: (0x29, 1), 0x5B: (0x5D, 1), 0x7B: (0x7D, 1),
                                                     0x29: (0x28, -1), 0x5D: (0x5B, -1), 0x7D: (0x7B, -1)]
            guard let (partner, direction) = pairs[char] else { return nil }
            var depth = 0
            var i = index
            var steps = 0
            while i >= 0, i < text.length, steps < 50_000 {
                let c = text.character(at: i)
                if c == char { depth += 1 } else if c == partner { depth -= 1; if depth == 0 { return i } }
                i += direction
                steps += 1
            }
            return nil
        }

        private func updateCursorPosition(_ textView: NSTextView) {
            let range = textView.selectedRange()
            let position = TextMetrics.lineAndColumn(at: range.location, in: textView.string as NSString)
            let selected = textView.selectedRanges.reduce(0) { $0 + $1.rangeValue.length }
            updateTab { tab in
                if tab.cursorLine != position.line { tab.cursorLine = position.line }
                if tab.cursorColumn != position.column { tab.cursorColumn = position.column }
                if tab.selectedCharacterCount != selected { tab.selectedCharacterCount = selected }
            }
        }
    }
}

/// Editor colors and fonts for one theme + font size (Notepad++ / Xcode Dark inspired).
struct EditorPalette {
    let background: NSColor
    let currentLine: NSColor
    let caret: NSColor
    let selection: NSColor
    let occurrence: NSColor
    let lineNumber: NSColor
    let currentLineNumber: NSColor
    let baseAttributes: [NSAttributedString.Key: Any]
    let markdownStyle: MarkdownStyler.Style?
    private let tokenAttributes: [SyntaxTokenKind: [NSAttributedString.Key: Any]]

    init(key: CodeEditorView.StyleKey) {
        let isDark = key.isDark
        let size = key.effectiveFontSize
        let monoFont: NSFont = {
            if key.fontFamily != "SF Mono", let custom = NSFont(name: key.fontFamily, size: size) {
                return custom
            }
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }()
        let boldFont = key.fontFamily == "SF Mono"
            ? NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
            : NSFontManager.shared.convert(monoFont, toHaveTrait: .boldFontMask)

        background = isDark
            ? NSColor(calibratedRed: 0.098, green: 0.106, blue: 0.125, alpha: 1.0) // #191B20
            : NSColor(calibratedRed: 0.99, green: 0.99, blue: 0.995, alpha: 1.0)
        currentLine = isDark ? NSColor.white.withAlphaComponent(0.035) : NSColor.black.withAlphaComponent(0.03)
        caret = isDark ? .systemCyan : .systemBlue
        selection = isDark ? NSColor.systemBlue.withAlphaComponent(0.38) : NSColor.systemBlue.withAlphaComponent(0.22)
        occurrence = isDark ? NSColor.white.withAlphaComponent(0.13) : NSColor.black.withAlphaComponent(0.09)
        lineNumber = isDark ? NSColor.white.withAlphaComponent(0.3) : NSColor.black.withAlphaComponent(0.3)
        currentLineNumber = isDark ? NSColor.white.withAlphaComponent(0.9) : NSColor.black.withAlphaComponent(0.85)

        let textColor = isDark
            ? NSColor(calibratedRed: 0.86, green: 0.88, blue: 0.92, alpha: 1.0)
            : NSColor(calibratedWhite: 0.14, alpha: 1.0)
        func color(_ dark: (CGFloat, CGFloat, CGFloat), _ light: (CGFloat, CGFloat, CGFloat)) -> NSColor {
            let c = isDark ? dark : light
            return NSColor(calibratedRed: c.0, green: c.1, blue: c.2, alpha: 1.0)
        }

        if key.liveMarkdown {
            // Notes read best in a proportional font with generous line spacing.
            let bodyFont = NSFont.systemFont(ofSize: (size + 1.5).rounded())
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 4
            paragraph.paragraphSpacing = 3
            baseAttributes = [.font: bodyFont, .foregroundColor: textColor, .paragraphStyle: paragraph]
            markdownStyle = MarkdownStyler.Style(
                bodyFont: bodyFont,
                monoFont: NSFont.monospacedSystemFont(ofSize: (size * 0.95).rounded(), weight: .regular),
                text: textColor,
                heading: isDark ? .white : NSColor(calibratedWhite: 0.05, alpha: 1),
                marker: isDark ? NSColor.white.withAlphaComponent(0.28) : NSColor.black.withAlphaComponent(0.28),
                accent: color((0.35, 0.83, 0.90), (0.04, 0.44, 0.64)),
                muted: isDark ? NSColor.white.withAlphaComponent(0.5) : NSColor.black.withAlphaComponent(0.5),
                codeBackground: isDark ? NSColor.white.withAlphaComponent(0.06) : NSColor.black.withAlphaComponent(0.05),
                highlight: NSColor.systemYellow.withAlphaComponent(isDark ? 0.3 : 0.4),
                tagBackground: color((0.35, 0.83, 0.90), (0.04, 0.44, 0.64)).withAlphaComponent(0.14),
                paragraph: paragraph)
        } else {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3.0
            baseAttributes = [.font: monoFont, .foregroundColor: textColor, .paragraphStyle: paragraph]
            markdownStyle = nil
        }

        tokenAttributes = [
            .function: [.foregroundColor: color((0.35, 0.83, 0.90), (0.05, 0.45, 0.65))], // #5AD4E6
            .type: [.foregroundColor: color((0.48, 0.85, 0.92), (0.12, 0.42, 0.68))],
            .keyword: [.foregroundColor: color((1.0, 0.42, 0.70), (0.68, 0.12, 0.54)), .font: boldFont], // #FF6BB3
            .literal: [.foregroundColor: color((0.68, 0.55, 0.98), (0.40, 0.20, 0.78))], // #AD8CFA
            .string: [.foregroundColor: color((0.92, 0.58, 0.42), (0.76, 0.28, 0.14)), .font: monoFont], // #EB946B
            .comment: [.foregroundColor: isDark
                ? NSColor(calibratedRed: 0.45, green: 0.52, blue: 0.58, alpha: 1.0)
                : NSColor(calibratedWhite: 0.45, alpha: 1.0), .font: monoFont]
        ]
    }

    func attributes(for kind: SyntaxTokenKind) -> [NSAttributedString.Key: Any] {
        tokenAttributes[kind] ?? [:]
    }
}
#endif
