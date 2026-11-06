#if canImport(AppKit)
import AppKit

extension NSAttributedString.Key {
    /// Marks characters hidden by a code fold.
    static let macNotepadFolded = NSAttributedString.Key("MacNotepadFolded")
}

/// The editing surface: Notepad++ line tools, multi-cursor editing, smart Enter/Tab for code and Markdown,
/// auto-closing brackets, code folding, Notion-style formatting commands and the `/` block menu.
public final class EditorTextView: NSTextView {
    public var currentLineHighlightColor: NSColor = NSColor.white.withAlphaComponent(0.04)
    var language: SyntaxLanguage = .plainText
    var autoCloseBrackets = true
    /// Current fold candidates (recomputed after edits).
    var foldRegions: [FoldRegion] = []
    /// Called after folding changes so the gutter can redraw.
    var onFoldingChanged: (() -> Void)?
    /// True while any text is folded; lets layout skip fold checks entirely otherwise.
    private(set) var hasFolds = false

    /// Additional empty carets for multi-cursor editing (NSTextView itself only supports one empty caret).
    private(set) var extraCarets: [Int] = []
    private var isUpdatingCarets = false

    private var isMarkdown: Bool { language == .markdown }
    private var hasMultipleCursors: Bool { selectedRanges.count > 1 || !extraCarets.isEmpty }

    /// Every caret/selection, primary first.
    var allCursorRanges: [NSRange] {
        selectedRanges.map(\.rangeValue) + extraCarets.map { NSRange(location: $0, length: 0) }
    }

    /// Places one caret at each location (multi-cursor).
    func setCarets(_ locations: [Int]) {
        let sorted = Array(Set(locations.map { min(max(0, $0), nsText.length) })).sorted()
        guard let first = sorted.first else { return }
        isUpdatingCarets = true
        setSelectedRange(NSRange(location: first, length: 0))
        isUpdatingCarets = false
        extraCarets = Array(sorted.dropFirst())
        needsDisplay = true
    }

    public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        if !isUpdatingCarets && !extraCarets.isEmpty {
            extraCarets = []
            needsDisplay = true
        }
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
    }
    private var nsText: NSString { string as NSString }

    // MARK: - Focus

    /// Gives keyboard focus back to the editor in the main window (after the palette or find bar closes).
    static func focusInMainWindow() {
        guard let window = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) else { return }
        func find(_ view: NSView) -> EditorTextView? {
            if let editor = view as? EditorTextView { return editor }
            for sub in view.subviews { if let found = find(sub) { return found } }
            return nil
        }
        if let content = window.contentView, let editor = find(content) {
            window.makeFirstResponder(editor)
        }
    }

    /// New editors (window open, tab switch) take keyboard focus unless something else already has it.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // Runs after SwiftUI's own initial focus pass, which would otherwise pick the sidebar search field.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            let responder = window.firstResponder
            if responder == nil || responder === window || !(responder is NSTextView) || (responder as? NSTextView)?.isFieldEditor == true {
                window.makeFirstResponder(self)
            }
        }
    }

    // MARK: - Drawing

    public override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard selectedRanges.count == 1, let layoutManager, let textContainer else { return }
        let selected = selectedRange()
        guard selected.location <= nsText.length else { return }

        var lineRect: NSRect
        if selected.location == nsText.length, layoutManager.extraLineFragmentTextContainer != nil {
            lineRect = layoutManager.extraLineFragmentRect
        } else {
            let lineRange = nsText.lineRange(for: NSRange(location: selected.location, length: 0))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: lineRange.location, length: min(1, lineRange.length)), actualCharacterRange: nil)
            lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphRange.location, effectiveRange: nil)
        }
        lineRect.origin.x = 0
        lineRect.origin.y += textContainerInset.height
        lineRect.size.width = bounds.width
        currentLineHighlightColor.setFill()
        lineRect.fill()
    }

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if !extraCarets.isEmpty, let layoutManager, let textContainer {
            (insertionPointColor ?? .textColor).setFill()
            for caret in extraCarets {
                var rect: NSRect
                if caret >= nsText.length, layoutManager.extraLineFragmentTextContainer != nil {
                    rect = layoutManager.extraLineFragmentRect
                } else {
                    let glyph = layoutManager.glyphIndexForCharacter(at: min(caret, max(0, nsText.length - 1)))
                    rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
                    if caret >= nsText.length { rect.origin.x = rect.maxX }
                }
                NSRect(x: rect.minX + textContainerInset.width, y: rect.minY + textContainerInset.height,
                       width: 2, height: rect.height).fill()
            }
        }
        // "⋯" pill after each folded line.
        for rect in foldPlaceholderRects() where rect.intersects(dirtyRect) {
            let path = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
            NSColor.systemGray.withAlphaComponent(0.25).setFill()
            path.fill()
            let label = "⋯" as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .bold), .foregroundColor: NSColor.secondaryLabelColor]
            let size = label.size(withAttributes: attrs)
            label.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attrs)
        }
    }

    private func foldPlaceholderRects() -> [NSRect] {
        guard hasFolds, let layoutManager, let textContainer, let storage = textStorage, storage.length > 0 else { return [] }
        var rects: [NSRect] = []
        storage.enumerateAttribute(.macNotepadFolded, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard value != nil, range.location > 0 else { return }
            let anchor = layoutManager.glyphIndexForCharacter(at: range.location - 1)
            var rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: anchor, length: 1), in: textContainer)
            rect.origin.x += rect.width + textContainerInset.width + 6
            rect.origin.y += textContainerInset.height + 2
            rect.size = NSSize(width: 26, height: max(12, rect.height - 4))
            rects.append(rect)
        }
        return rects
    }

    // MARK: - Mouse

    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if event.modifierFlags.contains([.command, .option]) {
            // ⌥⌘-click adds another caret.
            let index = characterIndexForInsertion(at: point)
            setCarets(allCursorRanges.map(\.location) + [index])
            return
        }
        if let fold = foldPlaceholderRects().firstIndex(where: { $0.contains(point) }) {
            unfoldAll(nth: fold)
            return
        }
        if isMarkdown, event.clickCount == 1, !event.modifierFlags.contains(.shift) {
            let index = characterIndexForInsertion(at: point)
            if let flip = MarkdownStyler.checkboxToggleRange(at: index, in: nsText) {
                let current = nsText.substring(with: flip)
                replace(flip, with: current == " " ? "x" : " ", select: nil)
                return
            }
        }
        super.mouseDown(with: event)
    }

    // MARK: - Typing

    private static let pairs: [String: String] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'", "`": "`"]

    public override func insertText(_ insertString: Any, replacementRange: NSRange) {
        guard let typed = (insertString as? String) ?? (insertString as? NSAttributedString)?.string else {
            super.insertText(insertString, replacementRange: replacementRange)
            return
        }

        // Multiple cursors: type into every selection.
        if hasMultipleCursors, replacementRange.location == NSNotFound {
            replaceEachSelection { _ in typed }
            return
        }

        let selection = selectedRange()
        if autoCloseBrackets, typed.count == 1, replacementRange.location == NSNotFound, language != .plainText {
            // Step over an auto-inserted closing character.
            if selection.length == 0, Self.pairs.values.contains(typed), selection.location < nsText.length,
               nsText.substring(with: NSRange(location: selection.location, length: 1)) == typed {
                setSelectedRange(NSRange(location: selection.location + 1, length: 0))
                return
            }
            if let close = Self.pairs[typed], shouldAutoPair(typed, at: selection) {
                if selection.length > 0 {
                    let inner = nsText.substring(with: selection)
                    replace(selection, with: typed + inner + close, select: NSRange(location: selection.location + 1, length: selection.length))
                } else {
                    replace(selection, with: typed + close, select: NSRange(location: selection.location + 1, length: 0))
                }
                return
            }
        }

        super.insertText(insertString, replacementRange: replacementRange)

        // Notion-style "/" at the start of an empty line opens the block menu.
        if isMarkdown, typed == "/" {
            let caret = selectedRange().location
            let lineStart = nsText.lineRange(for: NSRange(location: caret, length: 0)).location
            let before = nsText.substring(with: NSRange(location: lineStart, length: caret - lineStart))
            if before.trimmingCharacters(in: .whitespaces) == "/" { showSlashMenu(nil) }
        }
    }

    private func shouldAutoPair(_ char: String, at selection: NSRange) -> Bool {
        if selection.length > 0 { return char != "'" || !isMarkdown }
        let next = selection.location < nsText.length ? nsText.character(at: selection.location) : 0x20
        if let scalar = UnicodeScalar(next), CharacterSet.alphanumerics.contains(scalar) { return false }
        if char == "\"" || char == "'" || char == "`" {
            if isMarkdown && char != "`" { return false }
            let prev = selection.location > 0 ? nsText.character(at: selection.location - 1) : 0x20
            if let scalar = UnicodeScalar(prev), CharacterSet.alphanumerics.contains(scalar) { return false }
        }
        return true
    }

    public override func deleteBackward(_ sender: Any?) {
        if hasMultipleCursors {
            replaceEachSelection(deletingBackward: true) { _ in "" }
            return
        }
        let sel = selectedRange()
        if autoCloseBrackets, sel.length == 0, sel.location > 0, sel.location < nsText.length {
            let prev = nsText.substring(with: NSRange(location: sel.location - 1, length: 1))
            let next = nsText.substring(with: NSRange(location: sel.location, length: 1))
            if Self.pairs[prev] == next {
                replace(NSRange(location: sel.location - 1, length: 2), with: "", select: NSRange(location: sel.location - 1, length: 0))
                return
            }
        }
        super.deleteBackward(sender)
    }

    public override func insertNewline(_ sender: Any?) {
        guard selectedRanges.count == 1 else { super.insertNewline(sender); return }
        let sel = selectedRange()
        let lineRange = nsText.lineRange(for: NSRange(location: sel.location, length: 0))
        let beforeCaret = nsText.substring(with: NSRange(location: lineRange.location, length: sel.location - lineRange.location))
        let indent = String(beforeCaret.prefix { $0 == " " || $0 == "\t" })

        if isMarkdown, let item = MarkdownService.listItem(beforeCaret) {
            if item.text.trimmingCharacters(in: .whitespaces).isEmpty {
                // Enter on an empty list item ends the list (outdents first if nested).
                if item.indent > 0 {
                    let unit = beforeCaret.hasPrefix("\t") ? 1 : min(beforeCaret.prefix { $0 == " " }.count, 2)
                    replace(NSRange(location: lineRange.location, length: unit), with: "", select: NSRange(location: sel.location - unit, length: 0))
                } else {
                    replace(NSRange(location: lineRange.location, length: sel.location - lineRange.location), with: "", select: nil)
                }
                return
            }
            var marker: String
            if item.ordered {
                let number = Int(beforeCaret.trimmingCharacters(in: .whitespaces).prefix { $0.isNumber }) ?? 1
                marker = "\(number + 1). "
            } else {
                marker = String(beforeCaret.trimmingCharacters(in: .whitespaces).prefix(1)) + " "
            }
            if item.task != nil { marker += "[ ] " }
            insertPlain("\n" + indent + marker)
            return
        }
        if isMarkdown, beforeCaret.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
            if beforeCaret.trimmingCharacters(in: .whitespaces) == ">" {
                replace(NSRange(location: lineRange.location, length: sel.location - lineRange.location), with: "", select: nil)
            } else {
                insertPlain("\n" + indent + "> ")
            }
            return
        }

        if !isMarkdown && language != .plainText {
            let trimmed = beforeCaret.trimmingCharacters(in: .whitespaces)
            let unit = indentUnit
            let opensBlock = trimmed.hasSuffix("{") || trimmed.hasSuffix("[") || trimmed.hasSuffix("(") || (language == .python && trimmed.hasSuffix(":"))
            if opensBlock {
                let next = sel.location < nsText.length ? nsText.substring(with: NSRange(location: sel.location, length: 1)) : ""
                if ["}", "]", ")"].contains(next) {
                    let insert = "\n" + indent + unit + "\n" + indent
                    replace(sel, with: insert, select: NSRange(location: sel.location + 1 + (indent + unit as NSString).length, length: 0))
                } else {
                    insertPlain("\n" + indent + unit)
                }
                return
            }
        }
        insertPlain("\n" + indent)
    }

    private var indentUnit: String {
        if isMarkdown { return "  " }
        if string.contains("\n\t") { return "\t" }
        return language == .json || language == .html || language == .javascript || language == .css ? "  " : "    "
    }

    public override func insertTab(_ sender: Any?) {
        let sel = selectedRange()
        let lines = nsText.lineRange(for: sel)
        let multiLine = nsText.substring(with: sel).contains("\n")
        if multiLine || (isMarkdown && MarkdownService.listItem(nsText.substring(with: lines)) != nil) {
            indentLines(sender)
        } else if language != .plainText {
            insertPlain(indentUnit)
        } else {
            super.insertTab(sender)
        }
    }

    public override func insertBacktab(_ sender: Any?) {
        outdentLines(sender)
    }

    public override func cancelOperation(_ sender: Any?) {
        if hasMultipleCursors {
            setSelectedRange(NSRange(location: selectedRange().location, length: 0))
        } else {
            super.cancelOperation(sender)
        }
    }

    // MARK: - Edit helpers (all undoable)

    private func insertPlain(_ text: String) {
        let sel = selectedRange()
        replace(sel, with: text, select: NSRange(location: sel.location + (text as NSString).length, length: 0))
    }

    func replace(_ range: NSRange, with text: String, select: NSRange?) {
        guard shouldChangeText(in: range, replacementString: text) else { return }
        textStorage?.replaceCharacters(in: range, with: text)
        didChangeText()
        if let select { setSelectedRange(select) }
    }

    /// Replaces every selection (multi-cursor) in one undo step, keeping a caret after each insertion.
    private func replaceEachSelection(deletingBackward: Bool = false, _ makeText: (String) -> String) {
        var ranges = allCursorRanges.sorted { $0.location < $1.location }
        if deletingBackward {
            ranges = ranges.map { $0.length == 0 && $0.location > 0 ? NSRange(location: $0.location - 1, length: 1) : $0 }
        }
        let replacements = ranges.map { makeText(nsText.substring(with: $0)) }
        guard shouldChangeText(inRanges: ranges.map { NSValue(range: $0) }, replacementStrings: replacements) else { return }
        textStorage?.beginEditing()
        for (range, text) in zip(ranges, replacements).reversed() {
            textStorage?.replaceCharacters(in: range, with: text)
        }
        textStorage?.endEditing()
        didChangeText()
        var shift = 0
        var carets: [Int] = []
        for (range, text) in zip(ranges, replacements) {
            let length = (text as NSString).length
            carets.append(range.location + shift + length)
            shift += length - range.length
        }
        setCarets(carets)
    }

    /// Range covering all whole lines touched by the selection (without the final newline of the document).
    private func selectedLineBlock() -> NSRange {
        let sel = selectedRanges.map(\.rangeValue).reduce(selectedRange()) { NSUnionRange($0, $1) }
        var adjusted = sel
        // A selection ending at the start of a line doesn't include that line.
        if adjusted.length > 0, NSMaxRange(adjusted) <= nsText.length, NSMaxRange(adjusted) > 0,
           nsText.character(at: NSMaxRange(adjusted) - 1) == 0x0A {
            adjusted.length -= 1
        }
        return nsText.lineRange(for: adjusted)
    }

    /// Applies `transform` to each line of the selected block and reselects the block.
    private func transformLines(_ transform: ([String]) -> [String]) {
        let block = selectedLineBlock()
        var text = nsText.substring(with: block)
        let hadNewline = text.hasSuffix("\n")
        if hadNewline { text.removeLast() }
        var newText = transform(text.components(separatedBy: "\n")).joined(separator: "\n")
        if hadNewline { newText += "\n" }
        let length = (newText as NSString).length - (hadNewline ? 1 : 0)
        replace(block, with: newText, select: NSRange(location: block.location, length: max(0, length)))
    }

    // MARK: - Line commands (Notepad++)

    @objc func goToLine(_ sender: Any?) {
        let alert = NSAlert()
        alert.messageText = "Go to Line"
        alert.informativeText = "Enter a line number (or line:column)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "e.g. 42 or 42:7"
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let parts = field.stringValue.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard let line = parts.first else { return }
        var location = 0
        var current = 1
        while current < line, location < nsText.length {
            let nl = nsText.range(of: "\n", range: NSRange(location: location, length: nsText.length - location))
            if nl.location == NSNotFound { break }
            location = nl.location + 1
            current += 1
        }
        let lineEnd = NSMaxRange(nsText.lineRange(for: NSRange(location: location, length: 0)))
        let column = parts.count > 1 ? max(1, parts[1]) - 1 : 0
        let target = NSRange(location: min(location + column, lineEnd, nsText.length), length: 0)
        setSelectedRange(target)
        scrollRangeToVisible(target)
        window?.makeFirstResponder(self)
    }

    private var commentSyntax: (prefix: String, suffix: String)? {
        switch language {
        case .swift, .javascript: return ("// ", "")
        case .python, .bash: return ("# ", "")
        case .sql: return ("-- ", "")
        case .css: return ("/* ", " */")
        case .html, .markdown: return ("<!-- ", " -->")
        default: return nil
        }
    }

    @objc func toggleLineComment(_ sender: Any?) {
        guard let syntax = commentSyntax else { NSSound.beep(); return }
        transformLines { lines in
            let nonEmpty = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            let trimmedPrefix = syntax.prefix.trimmingCharacters(in: .whitespaces)
            let allCommented = !nonEmpty.isEmpty && nonEmpty.allSatisfy { $0.trimmingCharacters(in: .whitespaces).hasPrefix(trimmedPrefix) }
            let minIndent = nonEmpty.map { $0.prefix { $0 == " " || $0 == "\t" }.count }.min() ?? 0
            return lines.map { line in
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
                if allCommented {
                    var l = line
                    if let r = l.range(of: syntax.prefix) ?? l.range(of: trimmedPrefix) { l.removeSubrange(r) }
                    let trimmedSuffix = syntax.suffix.trimmingCharacters(in: .whitespaces)
                    if !trimmedSuffix.isEmpty, let r = l.range(of: syntax.suffix, options: .backwards) ?? l.range(of: trimmedSuffix, options: .backwards) {
                        l.removeSubrange(r)
                    }
                    return l
                }
                let idx = line.index(line.startIndex, offsetBy: minIndent)
                return String(line[..<idx]) + syntax.prefix + String(line[idx...]) + syntax.suffix
            }
        }
    }

    @objc func duplicateLines(_ sender: Any?) {
        let block = selectedLineBlock()
        let text = nsText.substring(with: block)
        let sel = selectedRange()
        // The copy goes below and the selection moves with it, like Notepad++/Xcode.
        if text.hasSuffix("\n") {
            replace(NSRange(location: NSMaxRange(block), length: 0), with: text,
                    select: NSRange(location: sel.location + block.length, length: sel.length))
        } else {
            replace(NSRange(location: NSMaxRange(block), length: 0), with: "\n" + text,
                    select: NSRange(location: sel.location + block.length + 1, length: sel.length))
        }
    }

    @objc func deleteLines(_ sender: Any?) {
        var block = selectedLineBlock()
        if NSMaxRange(block) == nsText.length, block.location > 0, !nsText.substring(with: block).hasSuffix("\n") {
            block = NSRange(location: block.location - 1, length: block.length + 1) // remove the preceding newline instead
        }
        replace(block, with: "", select: NSRange(location: min(block.location, nsText.length - block.length), length: 0))
    }

    @objc func moveLinesUp(_ sender: Any?) { moveLines(up: true) }
    @objc func moveLinesDown(_ sender: Any?) { moveLines(up: false) }

    private func moveLines(up: Bool) {
        let block = selectedLineBlock()
        let sel = selectedRange()
        if up {
            guard block.location > 0 else { NSSound.beep(); return }
            let prev = nsText.lineRange(for: NSRange(location: block.location - 1, length: 0))
            var blockText = nsText.substring(with: block)
            var prevText = nsText.substring(with: prev)
            if !blockText.hasSuffix("\n") { blockText += "\n"; prevText.removeLast() } // block was the last line
            let combined = NSRange(location: prev.location, length: NSMaxRange(block) - prev.location)
            replace(combined, with: blockText + prevText, select: NSRange(location: sel.location - prev.length, length: sel.length))
        } else {
            guard NSMaxRange(block) < nsText.length else { NSSound.beep(); return }
            let next = nsText.lineRange(for: NSRange(location: NSMaxRange(block), length: 0))
            var blockText = nsText.substring(with: block)
            var nextText = nsText.substring(with: next)
            if !nextText.hasSuffix("\n") { nextText += "\n"; blockText.removeLast() } // next was the last line
            let combined = NSRange(location: block.location, length: NSMaxRange(next) - block.location)
            replace(combined, with: nextText + blockText, select: NSRange(location: sel.location + (nextText as NSString).length, length: sel.length))
        }
    }

    @objc func indentLines(_ sender: Any?) {
        let unit = indentUnit
        transformLines { $0.map { $0.isEmpty ? $0 : unit + $0 } }
    }

    @objc func outdentLines(_ sender: Any?) {
        let width = indentUnit == "\t" ? 1 : (indentUnit as NSString).length
        transformLines { lines in
            lines.map { line in
                if line.hasPrefix("\t") { return String(line.dropFirst()) }
                let spaces = line.prefix { $0 == " " }.count
                return String(line.dropFirst(min(spaces, width)))
            }
        }
    }

    // MARK: - Multi-cursor

    private func wordRange(at location: Int) -> NSRange {
        let range = selectionRange(forProposedRange: NSRange(location: location, length: 0), granularity: .selectByWord)
        return range
    }

    @objc func selectNextOccurrence(_ sender: Any?) {
        var ranges = selectedRanges.map(\.rangeValue)
        guard let last = ranges.last else { return }
        if last.length == 0 {
            let word = wordRange(at: last.location)
            guard word.length > 0 else { return }
            ranges[ranges.count - 1] = word
            selectedRanges = ranges.map { NSValue(range: $0) }
            return
        }
        let needle = nsText.substring(with: last)
        var found = nsText.range(of: needle, range: NSRange(location: NSMaxRange(last), length: nsText.length - NSMaxRange(last)))
        if found.location == NSNotFound {
            found = nsText.range(of: needle, range: NSRange(location: 0, length: last.location))
        }
        guard found.location != NSNotFound, !ranges.contains(found) else { NSSound.beep(); return }
        ranges.append(found)
        selectedRanges = ranges.map { NSValue(range: $0) }
        scrollRangeToVisible(found)
    }

    @objc func selectAllOccurrences(_ sender: Any?) {
        var sel = selectedRange()
        if sel.length == 0 { sel = wordRange(at: sel.location) }
        guard sel.length > 0 else { return }
        let needle = nsText.substring(with: sel)
        var ranges: [NSValue] = []
        var search = NSRange(location: 0, length: nsText.length)
        while true {
            let found = nsText.range(of: needle, range: search)
            if found.location == NSNotFound { break }
            ranges.append(NSValue(range: found))
            search = NSRange(location: NSMaxRange(found), length: nsText.length - NSMaxRange(found))
        }
        if !ranges.isEmpty { selectedRanges = ranges }
    }

    @objc func addCursorsToLineEnds(_ sender: Any?) {
        let block = selectedLineBlock()
        var carets: [Int] = []
        var location = block.location
        while location < NSMaxRange(block) {
            let line = nsText.lineRange(for: NSRange(location: location, length: 0))
            var end = NSMaxRange(line)
            if end > line.location, nsText.character(at: end - 1) == 0x0A { end -= 1 }
            carets.append(end)
            location = NSMaxRange(line)
            if line.length == 0 { break }
        }
        if !carets.isEmpty { setCarets(carets) }
    }

    // MARK: - Folding

    private func region(containingLine line: Int) -> FoldRegion? {
        foldRegions.filter { $0.startLine <= line && NSMaxRange($0.hiddenRange) > 0 }
            .filter { region in
                let regionEndLine = TextMetrics.lineNumber(at: NSMaxRange(region.hiddenRange), in: nsText)
                return line <= regionEndLine
            }
            .max { $0.startLine < $1.startLine }
    }

    func isFolded(_ region: FoldRegion) -> Bool {
        guard let storage = textStorage, NSMaxRange(region.hiddenRange) <= storage.length, region.hiddenRange.length > 0 else { return false }
        return storage.attribute(.macNotepadFolded, at: region.hiddenRange.location, effectiveRange: nil) != nil
    }

    func setFolded(_ region: FoldRegion, _ folded: Bool) {
        guard let storage = textStorage, NSMaxRange(region.hiddenRange) <= storage.length else { return }
        if folded { hasFolds = true }
        storage.beginEditing()
        if folded {
            storage.addAttribute(.macNotepadFolded, value: true, range: region.hiddenRange)
        } else {
            storage.removeAttribute(.macNotepadFolded, range: region.hiddenRange)
        }
        storage.endEditing()
        if !folded {
            var any = false
            storage.enumerateAttribute(.macNotepadFolded, in: NSRange(location: 0, length: storage.length)) { value, _, stop in
                if value != nil { any = true; stop.pointee = true }
            }
            hasFolds = any
        }
        layoutManager?.invalidateGlyphs(forCharacterRange: region.hiddenRange, changeInLength: 0, actualCharacterRange: nil)
        layoutManager?.invalidateLayout(forCharacterRange: region.hiddenRange, actualCharacterRange: nil)
        if folded, NSLocationInRange(selectedRange().location, region.hiddenRange) {
            setSelectedRange(NSRange(location: region.hiddenRange.location, length: 0))
        }
        needsDisplay = true
        onFoldingChanged?()
    }

    func toggleFold(startingAtLine line: Int) {
        guard let region = foldRegions.first(where: { $0.startLine == line }) else { return }
        setFolded(region, !isFolded(region))
    }

    @objc func foldAtCursor(_ sender: Any?) {
        let line = TextMetrics.lineNumber(at: selectedRange().location, in: nsText)
        if let region = region(containingLine: line) { setFolded(region, true) } else { NSSound.beep() }
    }

    @objc func unfoldAtCursor(_ sender: Any?) {
        let line = TextMetrics.lineNumber(at: selectedRange().location, in: nsText)
        if let region = foldRegions.first(where: { $0.startLine == line && isFolded($0) }) ?? region(containingLine: line) {
            setFolded(region, false)
        }
    }

    @objc func foldAll(_ sender: Any?) {
        // Fold outermost regions only, so unfolding reveals the next level.
        var covered = NSRange(location: 0, length: 0)
        for region in foldRegions.sorted(by: { $0.hiddenRange.location < $1.hiddenRange.location }) {
            if NSLocationInRange(region.hiddenRange.location, covered) { continue }
            setFolded(region, true)
            covered = region.hiddenRange
        }
    }

    @objc func unfoldAll(_ sender: Any?) {
        guard let storage = textStorage else { return }
        let all = NSRange(location: 0, length: storage.length)
        storage.removeAttribute(.macNotepadFolded, range: all)
        hasFolds = false
        layoutManager?.invalidateGlyphs(forCharacterRange: all, changeInLength: 0, actualCharacterRange: nil)
        layoutManager?.invalidateLayout(forCharacterRange: all, actualCharacterRange: nil)
        needsDisplay = true
        onFoldingChanged?()
    }

    private func unfoldAll(nth index: Int) {
        guard let storage = textStorage else { return }
        var n = 0
        storage.enumerateAttribute(.macNotepadFolded, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            guard value != nil, range.location > 0 else { return }
            if n == index {
                setFolded(FoldRegion(startLine: 0, hiddenRange: range), false)
                stop.pointee = true
            }
            n += 1
        }
    }

    // MARK: - Markdown formatting (Notion-style)

    private func toggleWrap(_ marker: String) {
        let markerLength = (marker as NSString).length
        replaceEachSelectionWrapping(marker: marker, markerLength: markerLength)
    }

    private func replaceEachSelectionWrapping(marker: String, markerLength: Int) {
        var sel = selectedRange()
        if sel.length == 0 {
            let word = wordRange(at: sel.location)
            if word.length > 0 && !nsText.substring(with: word).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sel = word }
        }
        let inner = nsText.substring(with: sel)
        // Unwrap if already wrapped (either inside or just outside the selection).
        if inner.hasPrefix(marker), inner.hasSuffix(marker), (inner as NSString).length >= markerLength * 2 {
            let stripped = String(inner.dropFirst(marker.count).dropLast(marker.count))
            replace(sel, with: stripped, select: NSRange(location: sel.location, length: (stripped as NSString).length))
            return
        }
        if sel.location >= markerLength, NSMaxRange(sel) + markerLength <= nsText.length,
           nsText.substring(with: NSRange(location: sel.location - markerLength, length: markerLength)) == marker,
           nsText.substring(with: NSRange(location: NSMaxRange(sel), length: markerLength)) == marker {
            let outer = NSRange(location: sel.location - markerLength, length: sel.length + markerLength * 2)
            replace(outer, with: inner, select: NSRange(location: outer.location, length: sel.length))
            return
        }
        replace(sel, with: marker + inner + marker, select: NSRange(location: sel.location + markerLength, length: sel.length))
    }

    @objc func toggleBold(_ sender: Any?) { toggleWrap("**") }
    @objc func toggleItalic(_ sender: Any?) { toggleWrap("*") }
    @objc func toggleStrikethrough(_ sender: Any?) { toggleWrap("~~") }
    @objc func toggleHighlight(_ sender: Any?) { toggleWrap("==") }
    @objc func toggleInlineCode(_ sender: Any?) { toggleWrap("`") }

    @objc func insertLink(_ sender: Any?) {
        let sel = selectedRange()
        let label = sel.length > 0 ? nsText.substring(with: sel) : "link"
        let pasteboard = NSPasteboard.general.string(forType: .string) ?? ""
        let url = pasteboard.hasPrefix("http") && !pasteboard.contains(" ") ? pasteboard : "https://"
        let text = "[\(label)](\(url))"
        let urlStart = sel.location + (label as NSString).length + 3
        replace(sel, with: text, select: NSRange(location: urlStart, length: (url as NSString).length))
    }

    /// Replaces the block-level prefix (heading, list, quote, to-do) of each selected line.
    private func setLinePrefix(_ prefix: String, numbered: Bool = false) {
        transformLines { lines in
            var n = 0
            let allHave = lines.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty || Self.stripBlockPrefix($0).prefix == prefix || (numbered && Self.stripBlockPrefix($0).isNumbered) }
            return lines.map { line in
                guard !line.trimmingCharacters(in: .whitespaces).isEmpty || lines.count == 1 else { return line }
                let parts = Self.stripBlockPrefix(line)
                if allHave && !prefix.isEmpty { return parts.indent + parts.body } // toggle off
                n += 1
                return parts.indent + (numbered ? "\(n). " : prefix) + parts.body
            }
        }
    }

    static func stripBlockPrefix(_ line: String) -> (indent: String, prefix: String, body: String, isNumbered: Bool) {
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        var body = String(line.dropFirst(indent.count))
        let patterns = ["^#{1,6} ", "^[-*+] \\[[ xX]\\] ", "^[-*+] ", "^\\d+[.)] ", "^> "]
        for pattern in patterns {
            if let r = body.range(of: pattern, options: .regularExpression) {
                let prefix = String(body[r])
                body.removeSubrange(r)
                let normalized = prefix.hasPrefix("- [") || prefix.hasPrefix("* [") ? "- [ ] " : prefix
                return (indent, normalized, body, pattern == "^\\d+[.)] ")
            }
        }
        return (indent, "", body, false)
    }

    @objc func makeBodyText(_ sender: Any?) { transformLines { $0.map { let p = Self.stripBlockPrefix($0); return p.indent + p.body } } }
    @objc func makeHeading1(_ sender: Any?) { setLinePrefix("# ") }
    @objc func makeHeading2(_ sender: Any?) { setLinePrefix("## ") }
    @objc func makeHeading3(_ sender: Any?) { setLinePrefix("### ") }
    @objc func makeTodo(_ sender: Any?) { setLinePrefix("- [ ] ") }
    @objc func makeBullet(_ sender: Any?) { setLinePrefix("- ") }
    @objc func makeNumbered(_ sender: Any?) { setLinePrefix("1. ", numbered: true) }
    @objc func makeQuote(_ sender: Any?) { setLinePrefix("> ") }

    @objc func toggleCheckbox(_ sender: Any?) {
        transformLines { lines in
            lines.map { line in
                if let r = line.range(of: "^(\\s*[-*+] )\\[ \\]", options: .regularExpression) {
                    return line.replacingCharacters(in: r, with: line[r].replacingOccurrences(of: "[ ]", with: "[x]"))
                }
                if let r = line.range(of: "^(\\s*[-*+] )\\[[xX]\\]", options: .regularExpression) {
                    return line.replacingCharacters(in: r, with: line[r].replacingOccurrences(of: "[x]", with: "[ ]").replacingOccurrences(of: "[X]", with: "[ ]"))
                }
                let p = Self.stripBlockPrefix(line)
                return p.indent + "- [ ] " + p.body
            }
        }
    }

    @objc func insertTable(_ sender: Any?) {
        insertBlock("| Column 1 | Column 2 | Column 3 |\n| --- | --- | --- |\n|  |  |  |\n|  |  |  |\n", selectOffset: 2, selectLength: 8)
    }

    @objc func insertDivider(_ sender: Any?) { insertBlock("---\n", selectOffset: 4, selectLength: 0) }

    @objc func insertDate(_ sender: Any?) {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        insertPlain(formatter.string(from: Date()))
    }

    /// Inserts a block on its own line (replacing a lone "/" trigger if present).
    private func insertBlock(_ block: String, selectOffset: Int, selectLength: Int) {
        let sel = selectedRange()
        let line = nsText.lineRange(for: NSRange(location: sel.location, length: 0))
        let lineText = nsText.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
        let replaceRange: NSRange
        var text = block
        if lineText.isEmpty || lineText == "/" {
            var r = line
            if r.length > 0, nsText.character(at: NSMaxRange(r) - 1) == 0x0A { r.length -= 1 }
            replaceRange = r
            if text.hasSuffix("\n") && NSMaxRange(line) < nsText.length { text.removeLast() }
        } else {
            replaceRange = NSRange(location: NSMaxRange(line), length: 0)
            if !nsText.substring(with: line).hasSuffix("\n") { text = "\n" + text }
        }
        let base = replaceRange.location + (text.hasPrefix("\n") && !block.hasPrefix("\n") ? 1 : 0)
        replace(replaceRange, with: text, select: NSRange(location: min(base + selectOffset, replaceRange.location + (text as NSString).length), length: selectLength))
    }

    // MARK: - Slash menu

    private struct SlashItem {
        let title: String
        let symbol: String
        let apply: (EditorTextView) -> Void
    }

    private var slashItems: [SlashItem] {
        [
            SlashItem(title: "Text", symbol: "textformat") { $0.applySlash(prefix: "") },
            SlashItem(title: "Heading 1", symbol: "textformat.size.larger") { $0.applySlash(prefix: "# ") },
            SlashItem(title: "Heading 2", symbol: "textformat.size") { $0.applySlash(prefix: "## ") },
            SlashItem(title: "Heading 3", symbol: "textformat.size.smaller") { $0.applySlash(prefix: "### ") },
            SlashItem(title: "To-do List", symbol: "checkmark.square") { $0.applySlash(prefix: "- [ ] ") },
            SlashItem(title: "Bulleted List", symbol: "list.bullet") { $0.applySlash(prefix: "- ") },
            SlashItem(title: "Numbered List", symbol: "list.number") { $0.applySlash(prefix: "1. ") },
            SlashItem(title: "Quote", symbol: "text.quote") { $0.applySlash(prefix: "> ") },
            SlashItem(title: "Callout", symbol: "lightbulb") { $0.applySlash(prefix: "> 💡 ") },
            SlashItem(title: "Code Block", symbol: "chevron.left.forwardslash.chevron.right") {
                $0.insertBlock("```\n\n```\n", selectOffset: 4, selectLength: 0)
            },
            SlashItem(title: "Table", symbol: "tablecells") { $0.insertTable(nil) },
            SlashItem(title: "Divider", symbol: "minus") { $0.insertDivider(nil) },
            SlashItem(title: "Today's Date", symbol: "calendar") { tv in
                tv.applySlash(prefix: "")
                tv.insertDate(nil)
            },
        ]
    }

    @objc func showSlashMenu(_ sender: Any?) {
        let menu = NSMenu(title: "Insert Block")
        menu.autoenablesItems = false
        let header = NSMenuItem(title: "Insert block", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        for (index, item) in slashItems.enumerated() {
            let menuItem = NSMenuItem(title: item.title, action: #selector(slashItemChosen(_:)), keyEquivalent: "")
            menuItem.tag = index
            menuItem.target = self
            menuItem.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
            menu.addItem(menuItem)
        }
        guard let layoutManager, let textContainer else { return }
        let caret = min(selectedRange().location, max(0, nsText.length - 1))
        let glyph = layoutManager.glyphIndexForCharacter(at: caret)
        var rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        rect.origin.x += textContainerInset.width
        rect.origin.y += textContainerInset.height
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY + 4), in: self)
    }

    @objc private func slashItemChosen(_ sender: NSMenuItem) {
        guard slashItems.indices.contains(sender.tag) else { return }
        slashItems[sender.tag].apply(self)
    }

    /// Turns the current line (minus a "/" trigger) into a block with `prefix`.
    private func applySlash(prefix: String) {
        let sel = selectedRange()
        var line = nsText.lineRange(for: NSRange(location: sel.location, length: 0))
        if line.length > 0, nsText.character(at: NSMaxRange(line) - 1) == 0x0A { line.length -= 1 }
        var text = nsText.substring(with: line)
        if let slash = text.range(of: "/", options: .backwards) { text.removeSubrange(slash) }
        let parts = Self.stripBlockPrefix(text)
        let newLine = parts.indent + prefix + parts.body.trimmingCharacters(in: .whitespaces)
        replace(line, with: newLine, select: NSRange(location: line.location + (newLine as NSString).length, length: 0))
    }
}
#endif
