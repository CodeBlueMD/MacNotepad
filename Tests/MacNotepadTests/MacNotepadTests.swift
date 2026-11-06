import XCTest
@testable import MacNotepad

final class MacNotepadTests: XCTestCase {
    func testDefaultSaveLocationUnderDocuments() {
        let prefs = EditorPreferences()
        XCTAssertTrue(prefs.defaultSaveDirectoryPath.hasSuffix("/Documents/MacNotepad"))
    }

    func testQuickSaveToDefaultDirectory() throws {
        var prefs = EditorPreferences(
            defaultSaveDirectoryPath: NSTemporaryDirectory() + "MacNotepadTestDocs",
            autoCreateDefaultSaveFolder: true
        )
        var tab = DocumentTab(title: "scratch-note", content: "Hello MacNotepad", isDirty: true, language: .markdown)
        let savedURL = try SessionManager.shared.quickSaveToDefaultDirectory(tab: &tab, preferences: prefs)
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedURL.path))
        XCTAssertEqual(savedURL.lastPathComponent, "scratch-note.md")
        XCTAssertFalse(tab.isDirty)
        try? FileManager.default.removeItem(at: savedURL.deletingLastPathComponent())
        _ = prefs
    }

    func testTextToolsJSONPrettyPrintAndBase64() throws {
        let rawJSON = "{\"b\":1,\"a\":2}"
        let pretty = try TextToolsService.apply(.jsonPrettyPrint, to: rawJSON)
        XCTAssertTrue(pretty.contains("\"a\" : 2"))

        let encoded = try TextToolsService.apply(.base64Encode, to: "MacNotepad")
        let decoded = try TextToolsService.apply(.base64Decode, to: encoded)
        XCTAssertEqual(decoded, "MacNotepad")
    }

    func testRegexFindAndReplace() {
        let sample = "user_01\nuser_02\nadmin_01"
        let opts = SearchOptions(query: "user_(\\d+)", replacement: "member-$1", useRegex: true)
        let matches = SearchEngine.findMatches(in: sample, options: opts)
        XCTAssertEqual(matches.count, 2)

        let replaced = SearchEngine.replaceAll(in: sample, options: opts)
        XCTAssertEqual(replaced.replacementsCount, 2)
        XCTAssertTrue(replaced.updatedText.contains("member-01"))
    }

    func testDiffEngineSideBySideComparison() {
        let left = "line 1\nline 2\nline 3"
        let right = "line 1\nline 2 updated\nline 3\nline 4"
        let result = DiffEngine.compare(left: left, right: right)
        XCTAssertEqual(result.summary.unchanged, 2)
        XCTAssertEqual(result.summary.modifications, 1)
        XCTAssertEqual(result.summary.additions, 1)
    }

    func testDOCXAndPDFConversionRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sampleContent = "MacNotepad Document Conversion Test\nLine 2: Supports DOCX and PDF!"

        // 1. Export & re-open DOCX
        let docxURL = tempDir.appendingPathComponent("sample.docx")
        try DocumentConverterService.export(content: sampleContent, title: "sample", to: docxURL, format: .docx)
        XCTAssertTrue(FileManager.default.fileExists(atPath: docxURL.path))
        let importedDOCX = try DocumentConverterService.readDocumentContent(from: docxURL)
        XCTAssertTrue(importedDOCX.contains("MacNotepad Document Conversion Test"))

        // 2. Export & re-open PDF
        let pdfURL = tempDir.appendingPathComponent("sample.pdf")
        try DocumentConverterService.export(content: sampleContent, title: "sample", to: pdfURL, format: .pdf)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pdfURL.path))
        let importedPDF = try DocumentConverterService.readDocumentContent(from: pdfURL)
        XCTAssertTrue(importedPDF.contains("MacNotepad Document Conversion Test"))

        // 3. Export & re-open RTF & HTML
        let rtfURL = tempDir.appendingPathComponent("sample.rtf")
        try DocumentConverterService.export(content: sampleContent, title: "sample", to: rtfURL, format: .rtf)
        let importedRTF = try DocumentConverterService.readDocumentContent(from: rtfURL)
        XCTAssertTrue(importedRTF.contains("MacNotepad Document Conversion Test"))

        let htmlURL = tempDir.appendingPathComponent("sample.html")
        try DocumentConverterService.export(content: sampleContent, title: "sample", to: htmlURL, format: .html)
        XCTAssertTrue(FileManager.default.fileExists(atPath: htmlURL.path))
    }

    func testCodeFoldingAndFindInFiles() throws {
        let swiftCode = """
        class Engine {
            func run() {
                print("ok")
            }
        }
        """
        let blocks = SyntaxHighlighter.detectFoldableBlocks(in: swiftCode)
        XCTAssertEqual(blocks.count, 2)

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try swiftCode.write(to: tempDir.appendingPathComponent("Engine.swift"), atomically: true, encoding: .utf8)
        let matches = SearchEngine.findInFiles(directoryURL: tempDir, options: SearchOptions(query: "func run"))
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.lineNumber, 2)
    }
}
