#if canImport(AppKit)
import AppKit

/// Notion-style live Markdown: notes are set in a proportional font with sized headings, real bold/italic,
/// styled checkboxes, quotes, code and tables, while the Markdown syntax stays visible but dimmed.
enum MarkdownStyler {
    struct Style {
        let bodyFont: NSFont
        let monoFont: NSFont
        let text: NSColor
        let heading: NSColor
        let marker: NSColor
        let accent: NSColor
        let muted: NSColor
        let codeBackground: NSColor
        let highlight: NSColor
        let tagBackground: NSColor
        let paragraph: NSParagraphStyle

        func headingFont(level: Int) -> NSFont {
            let scale: CGFloat = [1.75, 1.4, 1.2, 1.08, 1.0, 1.0][max(0, min(5, level - 1))]
            return NSFont.systemFont(ofSize: (bodyFont.pointSize * scale).rounded(), weight: level <= 2 ? .bold : .semibold)
        }
    }

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        // Patterns are constants; a failure here is a programming error caught by the test suite.
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let bold = regex("(\\*\\*|__)(?=\\S)(.+?)(?<=\\S)\\1")
    private static let italic = regex("(?<![\\*\\w])(\\*|_)(?=[^\\s\\*_])(.+?)(?<=[^\\s\\*_])\\1(?![\\*\\w])")
    private static let strike = regex("(~~)(?=\\S)(.+?)(?<=\\S)~~")
    private static let mark = regex("(==)(?=\\S)(.+?)(?<=\\S)==")
    private static let code = regex("(`+)([^`]+?)\\1")
    private static let link = regex("(!?\\[)([^\\]]+)(\\]\\()([^)\\s]+)(\\))")
    private static let url = regex("(?<![\\(\\w])https?://[^\\s)>\\]]+")
    private static let tag = regex("(?:^|(?<=\\s))#[A-Za-z][\\w/-]*")
    private static let listMarker = regex("^(\\s*)([-*+]|\\d+[.)])(\\s+)(\\[[ xX]\\]\\s+)?")

    /// Whether `location` is inside a ``` fenced block (counts fences that start a line before it).
    static func isInsideFence(at location: Int, in text: NSString) -> Bool {
        var inside = false
        var search = 0
        while search < location {
            let found = text.range(of: "```", range: NSRange(location: search, length: location - search))
            if found.location == NSNotFound { break }
            if found.location == 0 || text.character(at: found.location - 1) == 0x0A { inside.toggle() }
            search = found.location + 3
        }
        return inside
    }

    static func style(_ storage: NSTextStorage, in range: NSRange, style: Style) {
        let text = storage.string as NSString
        var inFence = isInsideFence(at: range.location, in: text)
        var location = range.location
        while location < NSMaxRange(range) {
            let lineRange = text.lineRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(lineRange)
            var content = lineRange
            if content.length > 0, text.character(at: NSMaxRange(content) - 1) == 0x0A { content.length -= 1 }
            let line = text.substring(with: content)

            if line.hasPrefix("```") {
                storage.addAttributes([.font: style.monoFont, .foregroundColor: style.marker], range: content)
                inFence.toggle()
                continue
            }
            if inFence {
                storage.addAttributes([.font: style.monoFont, .backgroundColor: style.codeBackground], range: lineRange)
                continue
            }
            styleLine(storage, line: line, range: content, style: style)
        }
    }

    private static func styleLine(_ storage: NSTextStorage, line: String, range: NSRange, style: Style) {
        guard range.length > 0 else { return }
        let ns = line as NSString
        let local = NSRange(location: 0, length: ns.length)
        func abs(_ r: NSRange) -> NSRange { NSRange(location: range.location + r.location, length: r.length) }

        // Headings
        if let heading = MarkdownService.headingLevel(of: line) {
            storage.addAttributes([.font: style.headingFont(level: heading.level), .foregroundColor: style.heading], range: range)
            storage.addAttribute(.foregroundColor, value: style.marker, range: NSRange(location: range.location, length: min(range.length, heading.level + 1)))
            styleInline(storage, line: ns, offset: range.location, style: style)
            return
        }

        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Divider
        if ["---", "***", "___"].contains(trimmed.replacingOccurrences(of: " ", with: "")) {
            storage.addAttributes([.foregroundColor: style.marker, .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                                   .strikethroughColor: style.marker], range: range)
            return
        }

        // Tables stay monospaced so columns line up.
        if trimmed.hasPrefix("|") {
            storage.addAttribute(.font, value: style.monoFont, range: range)
            var search = 0
            while search < ns.length {
                let pipe = ns.range(of: "|", range: NSRange(location: search, length: ns.length - search))
                if pipe.location == NSNotFound { break }
                storage.addAttribute(.foregroundColor, value: style.marker, range: abs(pipe))
                search = pipe.location + 1
            }
            if MarkdownService.isTableSeparator(line) { storage.addAttribute(.foregroundColor, value: style.marker, range: range) }
            styleInline(storage, line: ns, offset: range.location, style: style)
            return
        }

        // Quotes and callouts
        if trimmed.hasPrefix(">") {
            let italic = NSFontManager.shared.convert(style.bodyFont, toHaveTrait: .italicFontMask)
            storage.addAttributes([.foregroundColor: style.muted, .font: italic], range: range)
            if let gt = line.firstIndex(of: ">") {
                storage.addAttribute(.foregroundColor, value: style.accent, range: abs(NSRange(gt...gt, in: line)))
            }
            styleInline(storage, line: ns, offset: range.location, style: style)
            return
        }

        // Lists and to-dos
        if let match = listMarker.firstMatch(in: line, range: local) {
            storage.addAttribute(.foregroundColor, value: style.accent, range: abs(match.range(at: 2)))
            let checkbox = match.range(at: 4)
            if checkbox.location != NSNotFound {
                let box = ns.substring(with: checkbox).lowercased()
                storage.addAttributes([.foregroundColor: style.accent, .font: style.monoFont], range: abs(checkbox))
                if box.hasPrefix("[x]") {
                    let rest = NSRange(location: NSMaxRange(checkbox), length: ns.length - NSMaxRange(checkbox))
                    storage.addAttributes([.foregroundColor: style.muted, .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: abs(rest))
                }
            }
        }

        styleInline(storage, line: ns, offset: range.location, style: style)
    }

    private static func styleInline(_ storage: NSTextStorage, line ns: NSString, offset: Int, style: Style) {
        let line = ns as String
        let local = NSRange(location: 0, length: ns.length)
        func abs(_ r: NSRange) -> NSRange { NSRange(location: offset + r.location, length: r.length) }
        func dim(_ r: NSRange) { if r.location != NSNotFound { storage.addAttribute(.foregroundColor, value: style.marker, range: abs(r)) } }
        func addTrait(_ trait: NSFontTraitMask, _ r: NSRange) {
            storage.enumerateAttribute(.font, in: abs(r)) { value, sub, _ in
                let font = (value as? NSFont) ?? style.bodyFont
                storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: trait), range: sub)
            }
        }

        var codeRanges: [NSRange] = []
        for m in code.matches(in: line, range: local) {
            codeRanges.append(m.range)
            storage.addAttributes([.font: style.monoFont, .backgroundColor: style.codeBackground], range: abs(m.range))
            dim(NSRange(location: m.range.location, length: m.range(at: 1).length))
            dim(NSRange(location: NSMaxRange(m.range) - m.range(at: 1).length, length: m.range(at: 1).length))
        }
        func inCode(_ r: NSRange) -> Bool { codeRanges.contains { NSIntersectionRange($0, r).length > 0 } }

        for m in bold.matches(in: line, range: local) where !inCode(m.range) {
            addTrait(.boldFontMask, m.range(at: 2))
            dim(m.range(at: 1)); dim(NSRange(location: NSMaxRange(m.range) - 2, length: 2))
        }
        for m in italic.matches(in: line, range: local) where !inCode(m.range) {
            addTrait(.italicFontMask, m.range(at: 2))
            dim(m.range(at: 1)); dim(NSRange(location: NSMaxRange(m.range) - 1, length: 1))
        }
        for m in strike.matches(in: line, range: local) where !inCode(m.range) {
            storage.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: abs(m.range(at: 2)))
            dim(m.range(at: 1)); dim(NSRange(location: NSMaxRange(m.range) - 2, length: 2))
        }
        for m in mark.matches(in: line, range: local) where !inCode(m.range) {
            storage.addAttribute(.backgroundColor, value: style.highlight, range: abs(m.range(at: 2)))
            dim(m.range(at: 1)); dim(NSRange(location: NSMaxRange(m.range) - 2, length: 2))
        }
        for m in link.matches(in: line, range: local) where !inCode(m.range) {
            storage.addAttributes([.foregroundColor: style.accent, .underlineStyle: NSUnderlineStyle.single.rawValue], range: abs(m.range(at: 2)))
            dim(m.range(at: 1)); dim(m.range(at: 3)); dim(m.range(at: 4)); dim(m.range(at: 5))
        }
        for m in url.matches(in: line, range: local) where !inCode(m.range) {
            storage.addAttributes([.foregroundColor: style.accent, .underlineStyle: NSUnderlineStyle.single.rawValue], range: abs(m.range))
        }
        for m in tag.matches(in: line, range: local) where !inCode(m.range) {
            storage.addAttributes([.foregroundColor: style.accent, .backgroundColor: style.tagBackground], range: abs(m.range))
        }
    }

    /// If `index` falls on a `[ ]` / `[x]` checkbox, returns the range of the character to flip.
    static func checkboxToggleRange(at index: Int, in text: NSString) -> NSRange? {
        guard index <= text.length else { return nil }
        let lineRange = text.lineRange(for: NSRange(location: min(index, max(0, text.length - 1)), length: 0))
        let line = text.substring(with: lineRange)
        guard let m = listMarker.firstMatch(in: line, range: NSRange(location: 0, length: (line as NSString).length)),
              m.range(at: 4).location != NSNotFound else { return nil }
        let box = NSRange(location: lineRange.location + m.range(at: 4).location, length: 3)
        guard index >= box.location, index <= NSMaxRange(box) else { return nil }
        return NSRange(location: box.location + 1, length: 1)
    }
}
#endif
