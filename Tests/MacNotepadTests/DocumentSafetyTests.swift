import XCTest
import CryptoKit
@testable import MacNotepad

final class DocumentSafetyTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    /// Builds a .docx the way Microsoft Word structures it: heading styles, numbering definitions,
    /// formatted runs, a hyperlink and a real table.
    private func makeWordDocument() throws -> URL {
        let pkg = tempDir.appendingPathComponent("pkg")
        let fm = FileManager.default
        try fm.createDirectory(at: pkg.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: pkg.appendingPathComponent("word/_rels"), withIntermediateDirectories: true)
        let w = "xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\" xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\""
        func para(_ style: String?, _ runs: String, num: (Int, Int)? = nil) -> String {
            var pPr = ""
            if let style { pPr += "<w:pStyle w:val=\"\(style)\"/>" }
            if let num { pPr += "<w:numPr><w:ilvl w:val=\"\(num.1)\"/><w:numId w:val=\"\(num.0)\"/></w:numPr>" }
            return "<w:p><w:pPr>\(pPr)</w:pPr>\(runs)</w:p>"
        }
        func run(_ text: String, bold: Bool = false, italic: Bool = false) -> String {
            "<w:r><w:rPr>\(bold ? "<w:b/>" : "")\(italic ? "<w:i/>" : "")</w:rPr><w:t xml:space=\"preserve\">\(text)</w:t></w:r>"
        }
        func cell(_ text: String) -> String { "<w:tc>\(para(nil, run(text)))</w:tc>" }
        let body = [
            para("Title", run("Quarterly Plan")),
            para(nil, run("Intro with ") + run("bold words", bold: true) + run(" and ") + run("italic words", italic: true) + run(".")),
            para("Heading2", run("Goals")),
            para("ListParagraph", run("Ship the editor"), num: (1, 0)),
            para("ListParagraph", run("Nested detail"), num: (1, 1)),
            para("ListParagraph", run("Write docs"), num: (1, 0)),
            para("ListParagraph", run("First step"), num: (2, 0)),
            para("ListParagraph", run("Second step"), num: (2, 0)),
            para(nil, "<w:hyperlink r:id=\"rId9\">\(run("Project site"))</w:hyperlink>"),
            "<w:tbl><w:tr>\(cell("Name"))\(cell("Owner"))</w:tr><w:tr>\(cell("Notes app"))\(cell("Sutha"))</w:tr></w:tbl>",
        ].joined()
        let files: [String: String] = [
            "[Content_Types].xml": "<?xml version=\"1.0\"?><Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"><Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/><Default Extension=\"xml\" ContentType=\"application/xml\"/><Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/></Types>",
            "_rels/.rels": "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/></Relationships>",
            "word/_rels/document.xml.rels": "<?xml version=\"1.0\"?><Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\"><Relationship Id=\"rId9\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink\" Target=\"https://example.com\" TargetMode=\"External\"/></Relationships>",
            "word/document.xml": "<?xml version=\"1.0\"?><w:document \(w)><w:body>\(body)</w:body></w:document>",
            "word/styles.xml": "<?xml version=\"1.0\"?><w:styles \(w)><w:style w:styleId=\"Title\"><w:name w:val=\"Title\"/></w:style><w:style w:styleId=\"Heading2\"><w:name w:val=\"heading 2\"/><w:pPr><w:outlineLvl w:val=\"1\"/></w:pPr></w:style></w:styles>",
            "word/numbering.xml": "<?xml version=\"1.0\"?><w:numbering \(w)><w:abstractNum w:abstractNumId=\"10\"><w:lvl w:ilvl=\"0\"><w:numFmt w:val=\"bullet\"/></w:lvl><w:lvl w:ilvl=\"1\"><w:numFmt w:val=\"bullet\"/></w:lvl></w:abstractNum><w:abstractNum w:abstractNumId=\"20\"><w:lvl w:ilvl=\"0\"><w:numFmt w:val=\"decimal\"/></w:lvl></w:abstractNum><w:num w:numId=\"1\"><w:abstractNumId w:val=\"10\"/></w:num><w:num w:numId=\"2\"><w:abstractNumId w:val=\"20\"/></w:num></w:numbering>",
        ]
        for (path, xml) in files {
            try xml.write(to: pkg.appendingPathComponent(path), atomically: true, encoding: .utf8)
        }
        let docxURL = tempDir.appendingPathComponent("Plan.docx")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        zip.currentDirectoryURL = pkg
        zip.arguments = ["-q", "-r", docxURL.path, "."]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        return docxURL
    }

    /// A .docx written by macOS itself (textutil), which encodes lists as literal bullet characters.
    private func makeTextUtilDocument() throws -> URL {
        let html = "<html><body><h1>Trip Notes</h1><p>Pack <b>passport</b>.</p><ul><li>Book hotel</li><li>Rent car</li></ul></body></html>"
        let htmlURL = tempDir.appendingPathComponent("source.html")
        try html.write(to: htmlURL, atomically: true, encoding: .utf8)
        let docxURL = tempDir.appendingPathComponent("Trip.docx")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "docx", htmlURL.path, "-output", docxURL.path]
        try process.run()
        process.waitUntilExit()
        return docxURL
    }

    private func sha(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    func testOpeningWordDocumentKeepsStructureAsMarkdown() throws {
        let docx = try makeWordDocument()
        let tab = try FileService.openTab(at: docx)

        XCTAssertNil(tab.fileURL, "Imported documents must not be bound to the original file")
        XCTAssertEqual(tab.importedFrom, docx)
        XCTAssertEqual(tab.title, "Plan.md")
        XCTAssertEqual(tab.language, .markdown)
        XCTAssertTrue(tab.content.contains("# Quarterly Plan"), tab.content)
        XCTAssertTrue(tab.content.contains("## Goals"), tab.content)
        XCTAssertTrue(tab.content.contains("**bold words**"), tab.content)
        XCTAssertTrue(tab.content.contains("*italic words*"), tab.content)
        XCTAssertTrue(tab.content.contains("- Ship the editor"), tab.content)
        XCTAssertTrue(tab.content.contains("1. First step"), tab.content)
        XCTAssertTrue(tab.content.contains("| Name | Owner |"), tab.content)
        XCTAssertTrue(tab.content.contains("| Notes app | Sutha |"), tab.content)
        XCTAssertTrue(tab.content.contains("  - Nested detail"), tab.content)
        XCTAssertTrue(tab.content.contains("[Project site](https://example.com)"), tab.content)
    }

    func testTextUtilWordDocumentListsSurviveImport() throws {
        let content = try FileService.openTab(at: try makeTextUtilDocument()).content
        XCTAssertTrue(content.contains("# Trip Notes"), content)
        XCTAssertTrue(content.contains("**passport**"), content)
        XCTAssertTrue(content.contains("- Book hotel\n- Rent car"), content)
    }

    func testSavingAnImportedWordDocumentNeverTouchesTheOriginal() throws {
        let docx = try makeWordDocument()
        let originalHash = try sha(docx)

        var tab = try FileService.openTab(at: docx)
        tab.content += "\nAdded a line.\n"
        let prefs = EditorPreferences(defaultSaveDirectoryPath: tempDir.appendingPathComponent("Notes").path)
        let saved = try SessionManager.shared.quickSaveToDefaultDirectory(tab: &tab, preferences: prefs)

        XCTAssertEqual(saved.pathExtension, "md")
        XCTAssertEqual(try sha(docx), originalHash, "The .docx must be byte-for-byte unchanged")
        XCTAssertNotNil(try? NSAttributedString(url: docx, options: [:], documentAttributes: nil), "The .docx must still open")
    }

    func testPlainTextWritesToRichDocumentsAreRefused() throws {
        let docx = try makeWordDocument()
        let originalHash = try sha(docx)
        var tab = DocumentTab(title: "x", content: "plain text")
        XCTAssertThrowsError(try FileService.write(&tab, to: docx))
        XCTAssertEqual(try sha(docx), originalHash)
    }

    func testMarkdownExportsToFormattedWordAndBack() throws {
        let markdown = "# Meeting Notes\n\nSome **important** text.\n\n- [ ] Follow up\n- Second bullet\n\n1. one\n2. two\n3. three\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n"
        let docx = tempDir.appendingPathComponent("Export.docx")
        try DocumentConverterService.export(content: markdown, title: "Export", to: docx, format: .docx, isMarkdown: true)

        let reopened = try FileService.openTab(at: docx).content
        XCTAssertTrue(reopened.contains("# Meeting Notes"), reopened)
        XCTAssertTrue(reopened.contains("**important**"), reopened)
        XCTAssertTrue(reopened.contains("- [ ] Follow up"), reopened)
        XCTAssertTrue(reopened.contains("| 1 | 2 |"), reopened)
        XCTAssertTrue(reopened.contains("| A | B |"), "Header cells come back without extra bold markers: \(reopened)")
        XCTAssertTrue(reopened.contains("1. one\n2. two\n3. three"), reopened)

        for format in [ExportDocumentFormat.pdf, .rtf, .html, .doc] {
            let url = tempDir.appendingPathComponent("Export.\(format.fileExtension)")
            try DocumentConverterService.export(content: markdown, title: "Export", to: url, format: format, isMarkdown: true)
            let text = try DocumentConverterService.readDocumentContent(from: url)
            XCTAssertTrue(text.contains("Meeting Notes"), "\(format): \(text)")
        }
    }

    func testQuickSaveNeverOverwritesAnotherFileWithTheSameName() throws {
        let notes = tempDir.appendingPathComponent("Notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try "keep me".write(to: notes.appendingPathComponent("new 1.txt"), atomically: true, encoding: .utf8)

        var tab = DocumentTab(title: "new 1", content: "fresh")
        let saved = try SessionManager.shared.quickSaveToDefaultDirectory(
            tab: &tab, preferences: EditorPreferences(defaultSaveDirectoryPath: notes.path))
        XCTAssertEqual(saved.lastPathComponent, "new 1 2.txt")
        XCTAssertEqual(try String(contentsOf: notes.appendingPathComponent("new 1.txt"), encoding: .utf8), "keep me")
    }

    func testEncodingDetectionAndRoundTrip() throws {
        let samples: [(DocumentEncoding, String)] = [
            (.utf8, "café ünïcödé ✓"),
            (.utf8BOM, "with bom ✓"),
            (.utf16, "utf-16 text ✓"),
            (.windows1252, "naïve résumé – “quotes”"),
        ]
        for (encoding, text) in samples {
            let url = tempDir.appendingPathComponent("\(encoding.id).txt")
            var tab = DocumentTab(title: "t", content: text, encoding: encoding)
            try FileService.write(&tab, to: url)
            let reopened = try FileService.openTab(at: url)
            XCTAssertEqual(reopened.encoding, encoding, "detected encoding for \(encoding)")
            XCTAssertEqual(reopened.content, text)
        }
    }

    func testCRLFFilesKeepTheirLineEndings() throws {
        let url = tempDir.appendingPathComponent("win.txt")
        try "a\r\nb\r\n".write(to: url, atomically: true, encoding: .utf8)
        var tab = try FileService.openTab(at: url)
        XCTAssertEqual(tab.lineEnding, .crlf)
        XCTAssertEqual(tab.content, "a\nb\n")
        try FileService.write(&tab, to: url)
        XCTAssertEqual(try Data(contentsOf: url), Data("a\r\nb\r\n".utf8))
    }
}
