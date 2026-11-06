import Foundation

/// Writes Markdown as a native Word document: real Heading 1–6 styles (so Word's navigation pane works),
/// bulleted/numbered/to-do lists with nesting, tables, quotes, code blocks, links and inline emphasis.
enum DocxExporter {
    static func write(markdown: String, title: String, to url: URL) throws {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("macnotepad-docx-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staging) }
        try fm.createDirectory(at: staging.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: staging.appendingPathComponent("word/_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: staging.appendingPathComponent("docProps"), withIntermediateDirectories: true)

        var builder = Builder()
        builder.convert(markdown)

        let files: [String: String] = [
            "[Content_Types].xml": contentTypes,
            "_rels/.rels": rootRels,
            "docProps/core.xml": coreProps(title: title),
            "word/document.xml": "\(xmlHeader)<w:document \(ns)><w:body>\(builder.body)<w:sectPr><w:pgSz w:w=\"12240\" w:h=\"15840\"/><w:pgMar w:top=\"1440\" w:right=\"1440\" w:bottom=\"1440\" w:left=\"1440\" w:header=\"720\" w:footer=\"720\" w:gutter=\"0\"/></w:sectPr></w:body></w:document>",
            "word/styles.xml": styles,
            "word/numbering.xml": numbering(orderedLists: builder.orderedLists),
            "word/_rels/document.xml.rels": documentRels(links: builder.links),
        ]
        for (path, xml) in files {
            try xml.write(to: staging.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }

        let output = fm.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).docx")
        defer { try? fm.removeItem(at: output) }
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = staging
        zip.arguments = ["-q", "-X", "-r", output.path, "[Content_Types].xml", "_rels", "docProps", "word"]
        zip.standardError = Pipe()
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw DocumentConverterError.exportFailed("Could not package .docx") }
        if fm.fileExists(atPath: url.path) {
            // Swap in place so the existing file survives if anything goes wrong.
            _ = try fm.replaceItemAt(url, withItemAt: output)
        } else {
            try fm.copyItem(at: output, to: url)
        }
    }

    // MARK: - Markdown → WordprocessingML

    private struct Builder {
        var body = ""
        var links: [String] = []
        /// Each separate numbered list gets its own Word numbering so it restarts at 1.
        var orderedLists = 0
        var inOrderedList = false

        mutating func convert(_ markdown: String) {
            let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
            var i = 0
            var paragraph: [String] = []
            func flush(_ b: inout Builder) {
                guard !paragraph.isEmpty else { return }
                b.body += b.para(style: nil, runs: b.inlineRuns(paragraph.joined(separator: " ")))
                paragraph.removeAll()
            }
            while i < lines.count {
                let line = lines[i]
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("```") {
                    flush(&self)
                    i += 1
                    while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                        body += para(style: "Code", runs: run(lines[i], code: true))
                        i += 1
                    }
                    i += 1
                    continue
                }
                if t.isEmpty { flush(&self); i += 1; continue }
                if MarkdownService.listItem(line) == nil { inOrderedList = false }
                if let h = MarkdownService.headingLevel(of: t) {
                    flush(&self)
                    body += para(style: "Heading\(h.level)", runs: inlineRuns(h.title))
                    i += 1; continue
                }
                if ["---", "***", "___"].contains(t.replacingOccurrences(of: " ", with: "")) {
                    flush(&self)
                    body += "<w:p><w:pPr><w:pBdr><w:bottom w:val=\"single\" w:sz=\"6\" w:space=\"1\" w:color=\"BFBFBF\"/></w:pBdr></w:pPr></w:p>"
                    i += 1; continue
                }
                if t.hasPrefix("|"), i + 1 < lines.count, MarkdownService.isTableSeparator(lines[i + 1]) {
                    flush(&self)
                    var rows = [MarkdownService.tableCells(t)]
                    i += 2
                    while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                        rows.append(MarkdownService.tableCells(lines[i].trimmingCharacters(in: .whitespaces)))
                        i += 1
                    }
                    body += table(rows)
                    continue
                }
                if t.hasPrefix(">") {
                    flush(&self)
                    var text = String(t.dropFirst())
                    if text.hasPrefix(" ") { text.removeFirst() }
                    body += para(style: "Quote", runs: inlineRuns(text))
                    i += 1; continue
                }
                if let item = MarkdownService.listItem(line) {
                    flush(&self)
                    let level = min(8, item.indent / 2)
                    var text = item.text
                    if let done = item.task { text = (done ? "☑ " : "☐ ") + text }
                    if item.ordered && !inOrderedList {
                        orderedLists += 1
                        inOrderedList = true
                    } else if !item.ordered && level == 0 {
                        inOrderedList = false
                    }
                    let numId = item.ordered ? 1 + orderedLists : 1
                    body += "<w:p><w:pPr><w:pStyle w:val=\"ListParagraph\"/><w:numPr><w:ilvl w:val=\"\(level)\"/><w:numId w:val=\"\(numId)\"/></w:numPr></w:pPr>\(inlineRuns(text))</w:p>"
                    i += 1; continue
                }
                paragraph.append(t)
                i += 1
            }
            flush(&self)
        }

        func para(style: String?, runs: String) -> String {
            let pPr = style.map { "<w:pPr><w:pStyle w:val=\"\($0)\"/></w:pPr>" } ?? ""
            return "<w:p>\(pPr)\(runs)</w:p>"
        }

        func run(_ text: String, bold: Bool = false, italic: Bool = false, strike: Bool = false, code: Bool = false, link: Bool = false) -> String {
            var rPr = ""
            if link { rPr += "<w:rStyle w:val=\"Hyperlink\"/>" }
            if code { rPr += "<w:rFonts w:ascii=\"Menlo\" w:hAnsi=\"Menlo\" w:cs=\"Menlo\"/><w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F3F4F6\"/>" }
            if bold { rPr += "<w:b/>" }
            if italic { rPr += "<w:i/>" }
            if strike { rPr += "<w:strike/>" }
            return "<w:r>\(rPr.isEmpty ? "" : "<w:rPr>\(rPr)</w:rPr>")<w:t xml:space=\"preserve\">\(escape(text))</w:t></w:r>"
        }

        /// Tokenizes inline Markdown (**bold**, *italic*, ~~strike~~, `code`, [links](url)) into Word runs.
        mutating func inlineRuns(_ text: String) -> String {
            var out = ""
            var bold = false, italic = false, strike = false
            var buffer = ""
            let chars = Array(text)
            var i = 0
            func emit(_ b: inout Builder) {
                if !buffer.isEmpty { out += b.run(buffer, bold: bold, italic: italic, strike: strike); buffer = "" }
            }
            while i < chars.count {
                let c = chars[i]
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                if c == "\\", let next { buffer.append(next); i += 2; continue }
                if c == "`", let close = chars[(i + 1)...].firstIndex(of: "`") {
                    emit(&self)
                    out += run(String(chars[(i + 1)..<close]), code: true)
                    i = close + 1; continue
                }
                if c == "[", let closeBracket = chars[i...].firstIndex(of: "]"),
                   closeBracket + 1 < chars.count, chars[closeBracket + 1] == "(",
                   let closeParen = chars[(closeBracket + 1)...].firstIndex(of: ")") {
                    emit(&self)
                    let label = String(chars[(i + 1)..<closeBracket])
                    let target = String(chars[(closeBracket + 2)..<closeParen])
                    links.append(target)
                    out += "<w:hyperlink r:id=\"rIdLink\(links.count)\">\(run(label, bold: bold, italic: italic, link: true))</w:hyperlink>"
                    i = closeParen + 1; continue
                }
                if (c == "*" || c == "_"), next == c { emit(&self); bold.toggle(); i += 2; continue }
                if c == "~", next == "~" { emit(&self); strike.toggle(); i += 2; continue }
                if c == "*" || (c == "_" && (i == 0 || !chars[i - 1].isLetter)) {
                    emit(&self); italic.toggle(); i += 1; continue
                }
                buffer.append(c)
                i += 1
            }
            emit(&self)
            return out
        }

        mutating func table(_ rows: [[String]]) -> String {
            let width = rows.map(\.count).max() ?? 1
            let border = "<w:tblBorders>" + ["top", "left", "bottom", "right", "insideH", "insideV"]
                .map { "<w:\($0) w:val=\"single\" w:sz=\"4\" w:space=\"0\" w:color=\"BFBFBF\"/>" }.joined() + "</w:tblBorders>"
            var xml = "<w:tbl><w:tblPr><w:tblW w:w=\"0\" w:type=\"auto\"/>\(border)<w:tblCellMar><w:left w:w=\"108\" w:type=\"dxa\"/><w:right w:w=\"108\" w:type=\"dxa\"/></w:tblCellMar></w:tblPr><w:tblGrid>"
            xml += String(repeating: "<w:gridCol/>", count: width) + "</w:tblGrid>"
            for (r, row) in rows.enumerated() {
                xml += "<w:tr>"
                for c in 0..<width {
                    let text = c < row.count ? row[c] : ""
                    let shade = r == 0 ? "<w:tcPr><w:shd w:val=\"clear\" w:color=\"auto\" w:fill=\"F3F4F6\"/></w:tcPr>" : ""
                    let runs = r == 0 ? run(text, bold: true) : inlineRuns(text)
                    xml += "<w:tc>\(shade)<w:p>\(runs)</w:p></w:tc>"
                }
                xml += "</w:tr>"
            }
            return xml + "</w:tbl><w:p/>"
        }

        func escape(_ s: String) -> String {
            // XML 1.0 forbids most control characters; Word reports such files as corrupt.
            String(String.UnicodeScalarView(s.unicodeScalars.filter { $0.value >= 0x20 || $0 == "\t" || $0 == "\n" }))
                .replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
    }

    // MARK: - Package parts

    private static let xmlHeader = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
    private static let ns = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\""

    private static let contentTypes = """
    \(xmlHeader)<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/><Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/></Types>
    """

    private static let rootRels = """
    \(xmlHeader)<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/></Relationships>
    """

    private static func coreProps(title: String) -> String {
        let safe = title.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        return "\(xmlHeader)<cp:coreProperties xmlns:cp=\"http://schemas.openxmlformats.org/package/2006/metadata/core-properties\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\"><dc:title>\(safe)</dc:title><dc:creator>MacNotepad</dc:creator></cp:coreProperties>"
    }

    private static func documentRels(links: [String]) -> String {
        var rels = "<Relationship Id=\"rIdStyles\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/><Relationship Id=\"rIdNumbering\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/numbering\" Target=\"numbering.xml\"/>"
        for (i, link) in links.enumerated() {
            let target = link.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            rels += "<Relationship Id=\"rIdLink\(i + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"\(target)\" TargetMode=\"External\"/>"
        }
        return "\(xmlHeader)<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\(rels)</Relationships>"
    }

    private static let styles: String = {
        func heading(_ level: Int, size: Int) -> String {
            "<w:style w:type=\"paragraph\" w:styleId=\"Heading\(level)\"><w:name w:val=\"heading \(level)\"/><w:basedOn w:val=\"Normal\"/><w:next w:val=\"Normal\"/><w:qFormat/><w:pPr><w:keepNext/><w:spacing w:before=\"\(level == 1 ? 360 : 240)\" w:after=\"120\"/><w:outlineLvl w:val=\"\(level - 1)\"/></w:pPr><w:rPr><w:b/><w:sz w:val=\"\(size)\"/></w:rPr></w:style>"
        }
        return """
        \(xmlHeader)<w:styles \(ns)><w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:cs="Calibri"/><w:sz w:val="22"/></w:rPr></w:rPrDefault><w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults><w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>\(heading(1, size: 40))\(heading(2, size: 32))\(heading(3, size: 27))\(heading(4, size: 24))\(heading(5, size: 22))\(heading(6, size: 22))<w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="40"/><w:contextualSpacing/></w:pPr></w:style><w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:pPr><w:pBdr><w:left w:val="single" w:sz="18" w:space="8" w:color="BFBFBF"/></w:pBdr><w:ind w:left="360"/></w:pPr><w:rPr><w:i/><w:color w:val="595959"/></w:rPr></w:style><w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Code"/><w:basedOn w:val="Normal"/><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/><w:shd w:val="clear" w:color="auto" w:fill="F3F4F6"/></w:pPr><w:rPr><w:rFonts w:ascii="Menlo" w:hAnsi="Menlo" w:cs="Menlo"/><w:sz w:val="19"/></w:rPr></w:style><w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:rPr><w:color w:val="0B6FA4"/><w:u w:val="single"/></w:rPr></w:style></w:styles>
        """
    }()

    private static func numbering(orderedLists: Int) -> String {
        func levels(ordered: Bool) -> String {
            (0..<9).map { lvl in
                let bullets = ["•", "◦", "▪"]
                let fmt = ordered ? (lvl % 3 == 0 ? "decimal" : lvl % 3 == 1 ? "lowerLetter" : "lowerRoman") : "bullet"
                let text = ordered ? "%\(lvl + 1)." : bullets[lvl % 3]
                return "<w:lvl w:ilvl=\"\(lvl)\"><w:start w:val=\"1\"/><w:numFmt w:val=\"\(fmt)\"/><w:lvlText w:val=\"\(text)\"/><w:lvlJc w:val=\"left\"/><w:pPr><w:ind w:left=\"\(720 * (lvl + 1))\" w:hanging=\"360\"/></w:pPr></w:lvl>"
            }.joined()
        }
        return "\(xmlHeader)<w:numbering \(ns)><w:abstractNum w:abstractNumId=\"0\">\(levels(ordered: false))</w:abstractNum><w:abstractNum w:abstractNumId=\"1\">\(levels(ordered: true))</w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"0\"/></w:num>" + (0..<max(1, orderedLists)).map { n in
            "<w:num w:numId=\"\(n + 2)\"><w:abstractNumId w:val=\"1\"/><w:lvlOverride w:ilvl=\"0\"><w:startOverride w:val=\"1\"/></w:lvlOverride></w:num>"
        }.joined() + "</w:numbering>"
    }
}
