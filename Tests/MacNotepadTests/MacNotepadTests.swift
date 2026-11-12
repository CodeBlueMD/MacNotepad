import XCTest
@testable import MacNotepad

final class MacNotepadTests: XCTestCase {
    func testDefaultSaveLocationUnderDocuments() {
        let prefs = EditorPreferences()
        XCTAssertTrue(prefs.defaultSaveDirectoryPath.hasSuffix("/Documents/MacNotepad"))
    }

    func testQuickSaveToDefaultDirectory() throws {
        let prefs = EditorPreferences(
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

    func testRegexFindAndReplace() {
        let sample = "user_01\nuser_02\nadmin_01"
        let opts = SearchOptions(query: "user_(\\d+)", replacement: "member-$1", useRegex: true)
        let matches = SearchEngine.findMatches(in: sample, options: opts)
        XCTAssertEqual(matches.count, 2)

        let replaced = SearchEngine.replaceAll(in: sample, options: opts)
        XCTAssertEqual(replaced.replacementsCount, 2)
        XCTAssertTrue(replaced.updatedText.contains("member-01"))
    }

    func testSingleMatchReplace() {
        let sample = "hello world hello"
        let matches = SearchEngine.findMatches(in: sample, options: SearchOptions(query: "hello"))
        XCTAssertEqual(matches.count, 2)
        let singleReplaced = SearchEngine.replace(in: sample, targetRange: matches[0].range, with: "greetings")
        XCTAssertEqual(singleReplaced, "greetings world hello")
    }

    func testLineAndColumnLookup() {
        let text = "ab\ncde\n" as NSString
        XCTAssertEqual(TextMetrics.lineAndColumn(at: 0, in: text).line, 1)
        XCTAssertEqual(TextMetrics.lineAndColumn(at: 5, in: text).line, 2)
        XCTAssertEqual(TextMetrics.lineAndColumn(at: 5, in: text).column, 3)
        XCTAssertEqual(TextMetrics.lineAndColumn(at: 7, in: text).line, 3)
        XCTAssertEqual(TextMetrics.lineAndColumn(at: 7, in: text).column, 1)
    }

    func testFindInFiles() throws {
        let text = """
        class Engine {
            func run() {
                print("ok")
            }
        }
        """
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try text.write(to: tempDir.appendingPathComponent("Engine.txt"), atomically: true, encoding: .utf8)
        let matches = SearchEngine.findInFiles(directoryURL: tempDir, options: SearchOptions(query: "func run"))
        XCTAssertEqual(matches.count, 1)
        XCTAssertEqual(matches.first?.lineNumber, 2)
    }
}
