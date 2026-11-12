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

    private func makeDummyWordDocument() throws -> URL {
        let docxURL = tempDir.appendingPathComponent("Report.docx")
        try "fake docx binary content".write(to: docxURL, atomically: true, encoding: .utf8)
        return docxURL
    }

    private func sha(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    func testOpeningWordDocumentThrowsRefusal() throws {
        let docx = try makeDummyWordDocument()
        XCTAssertThrowsError(try FileService.openTab(at: docx)) { error in
            guard case FileServiceError.refusingToOverwriteRichDocument(let name) = error else {
                XCTFail("Expected refusingToOverwriteRichDocument, got \(error)")
                return
            }
            XCTAssertEqual(name, "Report.docx")
        }
    }

    func testPlainTextWritesToRichDocumentsAreRefused() throws {
        let docx = try makeDummyWordDocument()
        let originalHash = try sha(docx)
        var tab = DocumentTab(title: "x", content: "plain text")
        XCTAssertThrowsError(try FileService.write(&tab, to: docx))
        XCTAssertEqual(try sha(docx), originalHash)
    }

    func testSymlinkToRichDocumentCannotBypassTheOverwriteGuard() throws {
        let docx = try makeDummyWordDocument()
        let originalHash = try sha(docx)
        let link = tempDir.appendingPathComponent("innocent.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: docx)

        var tab = DocumentTab(title: "x", content: "plain text")
        XCTAssertThrowsError(try FileService.write(&tab, to: link))
        XCTAssertEqual(try sha(docx), originalHash, "The .docx behind the symlink must be untouched")
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
