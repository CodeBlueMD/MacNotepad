import Foundation
#if canImport(AppKit)
import AppKit
#endif

/// Small, dependency-free Markdown engine used for the live preview, exports, and note metadata.
/// Supports the Notion-style subset MacNotepad's editor writes: headings, lists, to-dos, quotes,
/// callouts, code blocks, tables, dividers, links, images, highlights and #tags.
public enum MarkdownService {

    // MARK: - Note metadata

    /// Heading lines (level, text, 1-based line number) for the outline sidebar.
    public static func headings(in text: String) -> [(level: Int, title: String, line: Int)] {
        var result: [(Int, String, Int)] = []
        var inFence = false
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            if line.hasPrefix("```") { inFence.toggle(); continue }
            guard !inFence, let heading = headingLevel(of: line) else { continue }
            result.append((heading.level, heading.title, index + 1))
        }
        return result
    }

    static func headingLevel(of line: String) -> (level: Int, title: String)? {
        var level = 0
        for ch in line { if ch == "#" { level += 1 } else { break } }
        guard (1...6).contains(level) else { return nil }
        let rest = line.dropFirst(level)
        guard rest.first == " " else { return nil }
        return (level, rest.trimmingCharacters(in: .whitespaces))
    }

    /// `#tags` used anywhere in a note (outside code), lowercased and de-duplicated in order.
    public static func tags(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "(?:^|\\s)#([A-Za-z][\\w/-]*)") else { return [] }
        var seen = Set<String>()
        var tags: [String] = []
        var inFence = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") { inFence.toggle(); continue }
            if inFence || headingLevel(of: line) != nil { continue }
            let ns = line as NSString
            for match in regex.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                let tag = ns.substring(with: match.range(at: 1)).lowercased()
                if seen.insert(tag).inserted { tags.append(tag) }
            }
        }
        return tags
    }

    /// Note title: first heading, else first non-empty line.
    public static func title(of text: String) -> String? {
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let heading = headingLevel(of: trimmed) { return heading.title }
            return String(trimmed.prefix(80))
        }
        return nil
    }

    /// Open and completed to-dos (`- [ ]` / `- [x]`).
    public static func taskCounts(in text: String) -> (open: Int, done: Int) {
        var open = 0, done = 0
        for line in text.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("- [ ] ") || t == "- [ ]" { open += 1 }
            if t.lowercased().hasPrefix("- [x] ") || t.lowercased() == "- [x]" { done += 1 }
        }
        return (open, done)
    }

    // MARK: - HTML rendering

    /// Renders Markdown to an HTML fragment.
    public static func html(from markdown: String) -> String {
        var html = ""
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var index = 0
        var paragraph: [String] = []
        var listStack: [String] = [] // "ul" / "ol"

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            html += "<p>" + paragraph.map(inline).joined(separator: "<br>\n") + "</p>\n"
            paragraph.removeAll()
        }
        func closeLists(to depth: Int = 0) {
            while listStack.count > depth { html += "</li></\(listStack.removeLast())>\n" }
        }

        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block
            if trimmed.hasPrefix("```") {
                flushParagraph(); closeLists()
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                index += 1
                while index < lines.count, !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(lines[index]); index += 1
                }
                let cls = lang.isEmpty ? "" : " class=\"language-\(escape(lang))\""
                html += "<pre><code\(cls)>\(escape(code.joined(separator: "\n")))</code></pre>\n"
                index += 1
                continue
            }

            if trimmed.isEmpty {
                flushParagraph(); closeLists()
                index += 1
                continue
            }

            if let heading = headingLevel(of: trimmed) {
                flushParagraph(); closeLists()
                let anchor = slug(heading.title)
                html += "<h\(heading.level) id=\"\(anchor)\">\(inline(heading.title))</h\(heading.level)>\n"
                index += 1
                continue
            }

            if ["---", "***", "___"].contains(trimmed.replacingOccurrences(of: " ", with: "")) {
                flushParagraph(); closeLists()
                html += "<hr>\n"
                index += 1
                continue
            }

            // Table: header row followed by a |---| separator row
            if trimmed.hasPrefix("|"), index + 1 < lines.count, isTableSeparator(lines[index + 1]) {
                flushParagraph(); closeLists()
                let header = tableCells(trimmed)
                html += "<table>\n<thead><tr>" + header.map { "<th>\(inline($0))</th>" }.joined() + "</tr></thead>\n<tbody>\n"
                index += 2
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    let cells = tableCells(lines[index].trimmingCharacters(in: .whitespaces))
                    html += "<tr>" + cells.map { "<td>\(inline($0))</td>" }.joined() + "</tr>\n"
                    index += 1
                }
                html += "</tbody></table>\n"
                continue
            }

            // Blockquote / callout
            if trimmed.hasPrefix(">") {
                flushParagraph(); closeLists()
                var quote: [String] = []
                while index < lines.count, lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    var body = String(lines[index].trimmingCharacters(in: .whitespaces).dropFirst())
                    if body.hasPrefix(" ") { body.removeFirst() }
                    quote.append(body)
                    index += 1
                }
                let isCallout = quote.first.map { $0.hasPrefix("💡") || $0.hasPrefix("⚠️") || $0.hasPrefix("📌") || $0.hasPrefix("[!") } ?? false
                let inner = MarkdownService.html(from: quote.joined(separator: "\n"))
                html += isCallout ? "<div class=\"callout\">\(inner)</div>\n" : "<blockquote>\(inner)</blockquote>\n"
                continue
            }

            // Lists (bulleted, numbered, to-do), nested by indentation
            if let item = listItem(line) {
                flushParagraph()
                let depth = item.indent / 2 + 1
                let kind = item.ordered ? "ol" : "ul"
                // Switching between bulleted and numbered at the same level starts a new list.
                if listStack.count >= depth, listStack[depth - 1] != kind {
                    closeLists(to: depth - 1)
                }
                let li = item.task != nil ? "<li class=\"task\">" : "<li>"
                if listStack.count < depth {
                    while listStack.count < depth {
                        listStack.append(kind)
                        html += "<\(kind)>\(li)"
                    }
                } else {
                    closeLists(to: depth)
                    html += "</li>\(li)"
                }
                if let done = item.task {
                    html += "<input type=\"checkbox\" disabled\(done ? " checked" : "")> "
                    html += done ? "<span class=\"done\">\(inline(item.text))</span>" : inline(item.text)
                } else {
                    html += inline(item.text)
                }
                index += 1
                continue
            }

            closeLists()
            paragraph.append(trimmed)
            index += 1
        }
        flushParagraph()
        closeLists()
        return html
    }

    /// Full standalone HTML document with MacNotepad's reading styles.
    public static func htmlDocument(from markdown: String, title: String, dark: Bool = false) -> String {
        """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><title>\(escape(title))</title>
        <style>\(stylesheet(dark: dark))</style></head>
        <body><article>\(html(from: markdown))</article></body></html>
        """
    }

    public static func stylesheet(dark: Bool) -> String {
        let fg = dark ? "#E3E6EC" : "#1F2328"
        let bg = dark ? "#191B20" : "#FFFFFF"
        let muted = dark ? "#8B95A3" : "#6A737D"
        let codeBg = dark ? "#23262E" : "#F3F4F6"
        let border = dark ? "#2F333C" : "#E1E4E8"
        let accent = dark ? "#5AD4E6" : "#0B6FA4"
        return """
        body { margin: 0; background: \(bg); color: \(fg); font: 15px/1.65 -apple-system, BlinkMacSystemFont, "Helvetica Neue", sans-serif; }
        article { max-width: 760px; margin: 0 auto; padding: 32px 40px 80px; }
        h1, h2, h3, h4 { line-height: 1.25; margin: 1.4em 0 0.5em; font-weight: 700; }
        h1 { font-size: 2em; } h2 { font-size: 1.5em; } h3 { font-size: 1.2em; }
        h1:first-child { margin-top: 0; }
        a { color: \(accent); text-decoration: none; } a:hover { text-decoration: underline; }
        code { font: 0.9em "SF Mono", Menlo, monospace; background: \(codeBg); padding: 2px 5px; border-radius: 4px; }
        pre { background: \(codeBg); padding: 14px 16px; border-radius: 8px; overflow-x: auto; }
        pre code { background: none; padding: 0; }
        blockquote { margin: 1em 0; padding: 2px 16px; border-left: 3px solid \(border); color: \(muted); }
        .callout { margin: 1em 0; padding: 10px 16px; border-radius: 8px; background: \(codeBg); border: 1px solid \(border); }
        .callout p { margin: 0.3em 0; }
        hr { border: none; border-top: 1px solid \(border); margin: 2em 0; }
        table { border-collapse: collapse; margin: 1em 0; }
        th, td { border: 1px solid \(border); padding: 6px 12px; text-align: left; }
        th { background: \(codeBg); }
        li.task { list-style: none; margin-left: -1.3em; }
        li.task input { -webkit-appearance: none; appearance: none; width: 14px; height: 14px; margin: 0 8px 0 -2px; vertical-align: -2px;
          border: 1.5px solid \(muted); border-radius: 4px; background: transparent; }
        li.task input:checked { background: \(accent); border-color: \(accent); }
        li.task input:checked::after { content: "✓"; display: block; color: \(bg); font-size: 11px; line-height: 12px; text-align: center; font-weight: 700; }
        .done { color: \(muted); text-decoration: line-through; }
        mark { background: rgba(255, 214, 0, 0.35); color: inherit; padding: 0 2px; border-radius: 3px; }
        .tag { color: \(accent); background: \(codeBg); border-radius: 10px; padding: 1px 8px; font-size: 0.85em; }
        img { max-width: 100%; border-radius: 6px; }
        """
    }

    static func listItem(_ line: String) -> (indent: Int, ordered: Bool, task: Bool?, text: String)? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let body = line.drop { $0 == " " || $0 == "\t" }
        var ordered = false
        var rest: Substring
        if let first = body.first, "-*+".contains(first), body.dropFirst().first == " " {
            rest = body.dropFirst(2)
        } else {
            let digits = body.prefix { $0.isNumber }
            guard !digits.isEmpty, digits.count < 10 else { return nil }
            let after = body.dropFirst(digits.count)
            guard after.first == "." || after.first == ")", after.dropFirst().first == " " else { return nil }
            ordered = true
            rest = after.dropFirst(2)
        }
        var task: Bool?
        if rest.hasPrefix("[ ] ") || rest == "[ ]" { task = false; rest = rest.dropFirst(min(4, rest.count)) }
        else if rest.lowercased().hasPrefix("[x] ") || rest.lowercased() == "[x]" { task = true; rest = rest.dropFirst(min(4, rest.count)) }
        return (indent, ordered, task, String(rest))
    }

    static func isTableSeparator(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("|"), t.contains("-") else { return false }
        return t.allSatisfy { "|-: ".contains($0) }
    }

    static func tableCells(_ row: String) -> [String] {
        var cells = row.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        if cells.first == "" { cells.removeFirst() }
        if cells.last == "" { cells.removeLast() }
        return cells
    }

    static func slug(_ text: String) -> String {
        text.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static let inlineRules: [(NSRegularExpression, String)] = {
        let rules: [(String, String)] = [
            ("!\\[([^\\]]*)\\]\\(([^)\\s]+)\\)", "<img alt=\"$1\" src=\"$2\">"),
            ("\\[([^\\]]+)\\]\\(([^)\\s]+)\\)", "<a href=\"$2\">$1</a>"),
            ("\\*\\*(?=\\S)(.+?)(?<=\\S)\\*\\*", "<strong>$1</strong>"),
            ("__(?=\\S)(.+?)(?<=\\S)__", "<strong>$1</strong>"),
            ("(?<![\\*\\w])\\*(?=\\S)(.+?)(?<=\\S)\\*(?![\\*\\w])", "<em>$1</em>"),
            ("(?<![_\\w])_(?=\\S)(.+?)(?<=\\S)_(?![_\\w])", "<em>$1</em>"),
            ("~~(?=\\S)(.+?)(?<=\\S)~~", "<del>$1</del>"),
            ("==(?=\\S)(.+?)(?<=\\S)==", "<mark>$1</mark>"),
            ("(?<![\\w\"=/>])(https?://[^\\s<]+[^\\s<.,;:!?)])", "<a href=\"$1\">$1</a>"),
            ("(^|\\s)#([A-Za-z][\\w/-]*)", "$1<span class=\"tag\">#$2</span>")
        ]
        return rules.compactMap { pattern, template in
            (try? NSRegularExpression(pattern: pattern)).map { ($0, template) }
        }
    }()

    /// Inline Markdown → HTML. Code spans are protected from the other rules.
    static func inline(_ text: String) -> String {
        var codeSpans: [String] = []
        var working = ""
        var parts = text.components(separatedBy: "`")
        if parts.count % 2 == 0 { parts[parts.count - 2] += "`" + parts.removeLast() } // unmatched backtick
        for (i, part) in parts.enumerated() {
            if i % 2 == 1 {
                codeSpans.append("<code>\(escape(part))</code>")
                working += "\u{0}\(codeSpans.count - 1)\u{0}"
            } else {
                working += escape(part)
            }
        }
        for (regex, template) in inlineRules {
            working = regex.stringByReplacingMatches(
                in: working, range: NSRange(location: 0, length: (working as NSString).length), withTemplate: template)
        }
        for (i, span) in codeSpans.enumerated() {
            working = working.replacingOccurrences(of: "\u{0}\(i)\u{0}", with: span)
        }
        return working
    }

    #if canImport(AppKit)
    // MARK: - Rich text bridges

    /// Renders Markdown as a styled attributed string (used for .docx/.rtf/.pdf export).
    public static func attributedString(from markdown: String, title: String) -> NSAttributedString? {
        let document = htmlDocument(from: markdown, title: title)
            .replacingOccurrences(of: "<input type=\"checkbox\" disabled checked> ", with: "☑ ")
            .replacingOccurrences(of: "<input type=\"checkbox\" disabled> ", with: "☐ ")
        guard let data = document.data(using: .utf8) else { return nil }
        return try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        )
    }

    /// Converts formatted text (from .docx/.rtf/.odt) to Markdown, keeping headings, bold/italic,
    /// strikethrough, links, bulleted/numbered lists and tables.
    public static func markdown(from attributed: NSAttributedString) -> String {
        let string = attributed.string as NSString
        guard string.length > 0 else { return "" }

        // Body text size = the most common font size, used to recognise headings.
        var sizeCounts: [CGFloat: Int] = [:]
        attributed.enumerateAttribute(.font, in: NSRange(location: 0, length: string.length)) { value, range, _ in
            if let font = value as? NSFont { sizeCounts[font.pointSize.rounded(), default: 0] += range.length }
        }
        let bodySize = sizeCounts.max { $0.value < $1.value }?.key ?? 12

        var output: [String] = []
        var tableRows: [[String]] = []
        var currentTable: NSTextTable?
        var currentRow = -1

        func flushTable() {
            guard !tableRows.isEmpty else { return }
            let width = tableRows.map(\.count).max() ?? 0
            for (i, row) in tableRows.enumerated() {
                let padded = row + Array(repeating: "", count: width - row.count)
                output.append("| " + padded.joined(separator: " | ") + " |")
                if i == 0 { output.append("|" + Array(repeating: " --- |", count: width).joined()) }
            }
            output.append("")
            tableRows.removeAll()
            currentTable = nil
            currentRow = -1
        }

        var location = 0
        while location < string.length {
            let paragraphRange = string.paragraphRange(for: NSRange(location: location, length: 0))
            location = NSMaxRange(paragraphRange)
            var contentRange = paragraphRange
            while contentRange.length > 0,
                  let scalar = UnicodeScalar(string.character(at: NSMaxRange(contentRange) - 1)),
                  CharacterSet.newlines.contains(scalar) {
                contentRange.length -= 1
            }

            let style = attributed.attribute(.paragraphStyle, at: paragraphRange.location, effectiveRange: nil) as? NSParagraphStyle
            var inlineText = inlineMarkdown(attributed, range: contentRange)

            // Tables
            if let cell = style?.textBlocks.compactMap({ $0 as? NSTextTableBlock }).first {
                if currentTable !== cell.table { flushTable(); currentTable = cell.table }
                if cell.startingRow != currentRow { tableRows.append([]); currentRow = cell.startingRow }
                let cleaned = inlineText.replacingOccurrences(of: "|", with: "\\|").trimmingCharacters(in: .whitespaces)
                if tableRows[tableRows.count - 1].count > cell.startingColumn {
                    tableRows[tableRows.count - 1][cell.startingColumn] += " " + cleaned
                } else {
                    tableRows[tableRows.count - 1].append(cleaned)
                }
                continue
            }
            flushTable()

            // Lists
            if let lists = style?.textLists, let list = lists.last {
                inlineText = stripListMarker(inlineText)
                let indent = String(repeating: "  ", count: max(0, lists.count - 1))
                let ordered = list.markerFormat.rawValue.contains("decimal")
                    || list.markerFormat.rawValue.contains("roman")
                    || list.markerFormat.rawValue.contains("alpha")
                output.append(indent + (ordered ? "1. " : "- ") + inlineText)
                continue
            }

            let plain = string.substring(with: contentRange).trimmingCharacters(in: .whitespaces)
            if plain.isEmpty {
                if output.last != "" { output.append("") }
                continue
            }

            // Headings by relative font size
            if let font = attributed.attribute(.font, at: contentRange.location, effectiveRange: nil) as? NSFont {
                let ratio = font.pointSize / bodySize
                let isBold = font.fontDescriptor.symbolicTraits.contains(.bold)
                var level = 0
                if ratio >= 1.6 { level = 1 } else if ratio >= 1.3 { level = 2 } else if ratio >= 1.1 && isBold { level = 3 }
                if level > 0 && plain.count < 120 {
                    if output.last != nil && output.last != "" { output.append("") }
                    output.append(String(repeating: "#", count: level) + " " + plain)
                    output.append("")
                    continue
                }
            }

            output.append(inlineText)
            output.append("")
        }
        flushTable()

        var text = output.joined(separator: "\n")
        while text.contains("\n\n\n") { text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    private static func stripListMarker(_ text: String) -> String {
        let pattern = "^\\s*(?:[•◦▪▫‣⁃●○■□–-]|\\(?[0-9a-zA-Z]{1,4}[.)])\\s*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        return regex.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Inline runs → Markdown emphasis/links, keeping spaces outside the markers.
    private static func inlineMarkdown(_ attributed: NSAttributedString, range: NSRange) -> String {
        var result = ""
        attributed.enumerateAttributes(in: range) { attrs, runRange, _ in
            let raw = (attributed.string as NSString).substring(with: runRange)
            guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { result += raw; return }
            let leading = String(raw.prefix { $0 == " " || $0 == "\t" })
            let trailing = String(raw.reversed().prefix { $0 == " " || $0 == "\t" })
            var core = raw.trimmingCharacters(in: .whitespaces)

            let traits = (attrs[.font] as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            if traits.contains(.bold) { core = "**\(core)**" }
            if traits.contains(.italic) { core = "*\(core)*" }
            if let strike = attrs[.strikethroughStyle] as? Int, strike != 0 { core = "~~\(core)~~" }
            if let link = attrs[.link] {
                let url = (link as? URL)?.absoluteString ?? "\(link)"
                core = "[\(core)](\(url))"
            }
            result += leading + core + String(trailing.reversed())
        }
        // Merge adjacent identical markers produced by split runs ("**a****b**" → "**ab**").
        return result.replacingOccurrences(of: "****", with: "").replacingOccurrences(of: "~~~~", with: "")
    }
    #endif
}
