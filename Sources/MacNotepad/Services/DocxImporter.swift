import Foundation

/// Reads a .docx (Office Open XML) package directly and converts it to Markdown.
/// AppKit's .docx reader flattens lists and tables into plain paragraphs, so this parses
/// `word/document.xml` itself: heading styles, numbered/bulleted lists (with nesting),
/// bold/italic/strikethrough runs, hyperlinks and tables.
enum DocxImporter {
    static func markdown(from url: URL) -> String? {
        guard let documentData = unzip(url, entry: "word/document.xml"),
              let document = try? XMLDocument(data: documentData) else { return nil }
        let numbering = unzip(url, entry: "word/numbering.xml").flatMap { try? XMLDocument(data: $0) }
        let relationships = unzip(url, entry: "word/_rels/document.xml.rels").flatMap { try? XMLDocument(data: $0) }
        let styles = unzip(url, entry: "word/styles.xml").flatMap { try? XMLDocument(data: $0) }
        let reader = Reader(numbering: numbering, relationships: relationships, styles: styles)
        guard let body = document.rootElement()?.firstChild(named: "body") else { return nil }
        return reader.convert(body: body)
    }

    private static func unzip(_ url: URL, entry: String) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, entry]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 && !data.isEmpty ? data : nil
    }

    private struct Paragraph {
        var text: String
        var plain: String
        var headingLevel: Int?
        var list: (level: Int, ordered: Bool)?
        var maxFontSize: Int
        var isQuote: Bool
    }

    private final class Reader {
        /// numId → (level → is ordered)
        private var listFormats: [String: [Int: Bool]] = [:]
        private var links: [String: String] = [:]
        /// styleId → heading level, from the style's outline level or name.
        private var headingStyles: [String: Int] = [:]

        init(numbering: XMLDocument?, relationships: XMLDocument?, styles: XMLDocument?) {
            if let root = numbering?.rootElement() {
                var abstractFormats: [String: [Int: Bool]] = [:]
                for abstract in root.children(named: "abstractNum") {
                    guard let id = abstract.wAttr("abstractNumId") else { continue }
                    var levels: [Int: Bool] = [:]
                    for lvl in abstract.children(named: "lvl") {
                        let level = Int(lvl.wAttr("ilvl") ?? "0") ?? 0
                        let format = lvl.firstChild(named: "numFmt")?.wAttr("val") ?? "bullet"
                        levels[level] = format != "bullet" && format != "none"
                    }
                    abstractFormats[id] = levels
                }
                for num in root.children(named: "num") {
                    guard let numId = num.wAttr("numId"),
                          let abstractId = num.firstChild(named: "abstractNumId")?.wAttr("val") else { continue }
                    listFormats[numId] = abstractFormats[abstractId] ?? [:]
                }
            }
            for rel in relationships?.rootElement()?.children(named: "Relationship") ?? [] {
                if let id = rel.attribute(forName: "Id")?.stringValue, let target = rel.attribute(forName: "Target")?.stringValue {
                    links[id] = target
                }
            }
            for style in styles?.rootElement()?.children(named: "style") ?? [] {
                guard let id = style.wAttr("styleId") else { continue }
                let name = (style.firstChild(named: "name")?.wAttr("val") ?? id).lowercased()
                if name == "title" { headingStyles[id] = 1; continue }
                if let outline = style.firstChild(named: "pPr")?.firstChild(named: "outlineLvl")?.wAttr("val"),
                   let level = Int(outline), level < 6 {
                    headingStyles[id] = level + 1
                } else if name.hasPrefix("heading "), let level = Int(name.dropFirst(8)), (1...6).contains(level) {
                    headingStyles[id] = level
                }
            }
        }

        func convert(body: XMLElement) -> String {
            var blocks: [Any] = [] // Paragraph or [[String]] (table)
            func collect(_ container: XMLElement) {
                for child in container.elementChildren {
                    switch child.localName {
                    case "p": blocks.append(paragraph(child))
                    case "tbl": blocks.append(table(child))
                    // Content controls (cover pages, tables of contents, template fields) wrap ordinary paragraphs.
                    case "sdt", "sdtContent", "customXml", "ins", "moveTo": collect(child)
                    default: continue
                    }
                }
            }
            collect(body)

            // Body size = most common run size among normal paragraphs, for size-based headings.
            var sizeCounts: [Int: Int] = [:]
            for case let p as Paragraph in blocks where p.maxFontSize > 0 { sizeCounts[p.maxFontSize, default: 0] += p.plain.count }
            let bodySize = sizeCounts.max { $0.value < $1.value }?.key ?? 24

            var lines: [String] = []
            func blank() { if let last = lines.last, !last.isEmpty { lines.append("") } }
            // Running number for each list level, so "1." "2." "3." come back in order.
            var listCounters: [Int: Int] = [:]

            for block in blocks {
                if let rows = block as? [[String]] {
                    guard !rows.isEmpty else { continue }
                    blank()
                    let width = rows.map(\.count).max() ?? 0
                    for (i, row) in rows.enumerated() {
                        // Header cells are bold anyway in Markdown tables.
                        let cells = i == 0 ? row.map { Self.stripWrapping($0, "**") } : row
                        let padded = cells + Array(repeating: "", count: width - cells.count)
                        lines.append("| " + padded.joined(separator: " | ") + " |")
                        if i == 0 { lines.append("|" + Array(repeating: " --- |", count: width).joined()) }
                    }
                    lines.append("")
                    continue
                }
                guard var p = block as? Paragraph else { continue }
                let plain = p.plain.trimmingCharacters(in: .whitespaces)
                if plain.isEmpty { blank(); continue }

                // Lists written as literal markers ("•\tItem", "1\tItem") by some exporters.
                if p.list == nil, let marker = Self.literalListMarker(p.text) {
                    p.list = (marker.level, marker.ordered)
                    p.text = marker.rest
                }

                if let list = p.list {
                    if let last = lines.last, !last.isEmpty, !Self.isListLine(last) { lines.append("") }
                    if lines.last.map({ !Self.isListLine($0) }) ?? true { listCounters.removeAll() }
                    listCounters = listCounters.filter { $0.key <= list.level }
                    var marker = "- "
                    if list.ordered {
                        let n = (listCounters[list.level] ?? 0) + 1
                        listCounters[list.level] = n
                        marker = "\(n). "
                    } else {
                        listCounters[list.level] = nil
                    }
                    var body = p.text.trimmingCharacters(in: .whitespaces)
                    // To-dos exported as ☐ / ☑ come back as Markdown checkboxes.
                    if body.hasPrefix("☐ ") { body = "[ ] " + body.dropFirst(2); marker = "- " }
                    else if body.hasPrefix("☑ ") { body = "[x] " + body.dropFirst(2); marker = "- " }
                    lines.append(String(repeating: "  ", count: list.level) + marker + body)
                    continue
                }
                listCounters.removeAll()

                var level = p.headingLevel
                if level == nil, p.maxFontSize > 0, plain.count < 120 {
                    let ratio = Double(p.maxFontSize) / Double(bodySize)
                    if ratio >= 1.6 { level = 1 } else if ratio >= 1.3 { level = 2 } else if ratio >= 1.15 { level = 3 }
                }
                blank()
                if let level {
                    lines.append(String(repeating: "#", count: level) + " " + plain)
                } else if p.isQuote {
                    lines.append("> " + p.text.trimmingCharacters(in: .whitespaces))
                } else {
                    lines.append(p.text.trimmingCharacters(in: .whitespaces))
                }
                lines.append("")
            }

            var text = lines.joined(separator: "\n")
            while text.contains("\n\n\n") { text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
            return text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        }

        static func stripWrapping(_ text: String, _ marker: String) -> String {
            guard text.count > marker.count * 2, text.hasPrefix(marker), text.hasSuffix(marker) else { return text }
            return String(text.dropFirst(marker.count).dropLast(marker.count))
        }

        static func isListLine(_ line: String) -> Bool {
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("- ") || t.range(of: "^\\d+\\. ", options: .regularExpression) != nil
        }

        static func literalListMarker(_ text: String) -> (level: Int, ordered: Bool, rest: String)? {
            let tabs = text.prefix { $0 == "\t" }.count
            let body = text.dropFirst(tabs)
            guard let regex = try? NSRegularExpression(pattern: "^([•◦▪▫‣⁃●○■□–-]|\\d{1,3}[.)]?)\\t") else { return nil }
            let ns = String(body) as NSString
            guard let match = regex.firstMatch(in: String(body), range: NSRange(location: 0, length: ns.length)) else { return nil }
            let marker = ns.substring(with: match.range(at: 1))
            return (max(0, tabs - 1), marker.first?.isNumber == true, ns.substring(from: match.range.length))
        }

        private func paragraph(_ p: XMLElement) -> Paragraph {
            let pPr = p.firstChild(named: "pPr")
            let styleId = pPr?.firstChild(named: "pStyle")?.wAttr("val") ?? ""
            var heading = headingStyles[styleId]
            if heading == nil {
                let lower = styleId.lowercased()
                if lower == "title" { heading = 1 }
                else if lower.hasPrefix("heading"), let n = Int(lower.dropFirst(7)), (1...6).contains(n) { heading = n }
            }
            var list: (Int, Bool)?
            if let numPr = pPr?.firstChild(named: "numPr"), let numId = numPr.firstChild(named: "numId")?.wAttr("val"), numId != "0" {
                let level = Int(numPr.firstChild(named: "ilvl")?.wAttr("val") ?? "0") ?? 0
                list = (level, listFormats[numId]?[level] ?? false)
            }

            var text = ""
            var plain = ""
            var maxSize = 0
            func appendRuns(in element: XMLElement, link: String?) {
                for child in element.elementChildren {
                    switch child.localName {
                    case "r":
                        let (runText, runPlain, size) = run(child)
                        maxSize = max(maxSize, runPlain.trimmingCharacters(in: .whitespaces).isEmpty ? 0 : size)
                        plain += runPlain
                        if let link, !runPlain.trimmingCharacters(in: .whitespaces).isEmpty {
                            text += "[\(runText)](\(link))"
                        } else {
                            text += runText
                        }
                    case "hyperlink":
                        let target = child.attribute(forLocalName: "id", uri: Self.relNS).flatMap { links[$0.stringValue ?? ""] }
                            ?? child.wAttr("anchor").map { "#\($0)" }
                        appendRuns(in: child, link: target)
                    case "ins", "moveTo", "customXml", "smartTag", "sdt", "sdtContent", "fldSimple":
                        appendRuns(in: child, link: link)
                    default:
                        continue
                    }
                }
            }
            appendRuns(in: p, link: nil)
            let quote = styleId.lowercased().contains("quote")
            return Paragraph(text: Self.mergeMarkers(text), plain: plain, headingLevel: heading, list: list, maxFontSize: maxSize, isQuote: quote)
        }

        private static let relNS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"

        private func run(_ r: XMLElement) -> (String, String, Int) {
            let rPr = r.firstChild(named: "rPr")
            func on(_ name: String) -> Bool {
                guard let el = rPr?.firstChild(named: name) else { return false }
                let val = el.wAttr("val") ?? "true"
                return val != "0" && val != "false" && val != "none"
            }
            var raw = ""
            for child in r.elementChildren {
                switch child.localName {
                case "t": raw += child.stringValue ?? ""
                case "tab": raw += "\t"
                case "br", "cr": raw += " "
                default: continue
                }
            }
            let size = Int(rPr?.firstChild(named: "sz")?.wAttr("val") ?? "") ?? 0
            guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return (raw, raw, size) }
            let leading = String(raw.prefix { $0 == " " || $0 == "\t" })
            let trailing = String(raw.reversed().prefix { $0 == " " || $0 == "\t" }.reversed())
            var core = raw.trimmingCharacters(in: .whitespaces)
            if on("b") { core = "**\(core)**" }
            if on("i") { core = "*\(core)*" }
            if on("strike") || on("dstrike") { core = "~~\(core)~~" }
            return (leading + core + trailing, raw, size)
        }

        /// "**a****b**" → "**ab**" when adjacent runs share formatting.
        static func mergeMarkers(_ text: String) -> String {
            text.replacingOccurrences(of: "****", with: "").replacingOccurrences(of: "~~~~", with: "")
        }

        private func table(_ tbl: XMLElement) -> [[String]] {
            tbl.children(named: "tr").map { row in
                row.children(named: "tc").map { cell in
                    cell.children(named: "p")
                        .map { paragraph($0).text.trimmingCharacters(in: .whitespaces) }
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                        .replacingOccurrences(of: "|", with: "\\|")
                }
            }
        }
    }
}

private extension XMLNode {
    var elementChildren: [XMLElement] { (children ?? []).compactMap { $0 as? XMLElement } }
}

private extension XMLElement {
    func children(named name: String) -> [XMLElement] { elementChildren.filter { $0.localName == name } }
    func firstChild(named name: String) -> XMLElement? { elementChildren.first { $0.localName == name } }
    /// Reads a `w:`-prefixed attribute regardless of the namespace prefix used.
    func wAttr(_ name: String) -> String? {
        (attributes ?? []).first { $0.localName == name }?.stringValue
    }
}
