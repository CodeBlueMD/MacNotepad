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
}
