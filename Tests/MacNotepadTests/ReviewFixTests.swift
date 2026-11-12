import XCTest
import AppKit
@testable import MacNotepad

/// Regression tests for issues found in code review and session lifecycle.
final class ReviewFixTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testSavingThroughASymlinkUpdatesTheTarget() throws {
        let target = dir.appendingPathComponent("real.txt")
        let link = dir.appendingPathComponent("link.txt")
        try "old".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        var tab = try FileService.openTab(at: link)
        tab.content = "new"
        try FileService.write(&tab, to: link)

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "new")
        XCTAssertNotNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path), "The link must stay a link")
        XCTAssertEqual(tab.fileURL, link)

        // Changes to the real file are seen through the link.
        Thread.sleep(forTimeInterval: 1.1)
        try "changed elsewhere".write(to: target, atomically: true, encoding: .utf8)
        XCTAssertNotEqual(FileService.modificationDate(of: link), tab.fileModificationDate)
    }

    func testUndecodableWindows1252FallsBackToLatin1AndStillSaves() throws {
        let url = dir.appendingPathComponent("legacy.txt")
        try Data([0x63, 0x61, 0x66, 0xE9, 0x20, 0x81]).write(to: url) // "café " + byte undefined in CP1252
        var tab = try FileService.openTab(at: url)
        XCTAssertEqual(tab.encoding, .isoLatin1)
        XCTAssertNoThrow(try FileService.write(&tab, to: url))
    }

    func testMajorityLineEndingWins() {
        XCTAssertEqual(LineEnding.detect(in: "a\nb\nc\r\nd\n"), .lf)
        XCTAssertEqual(LineEnding.detect(in: "a\r\nb\r\nc\n"), .crlf)
    }

    func testOneBadTabDoesNotLoseTheWholeSession() throws {
        setenv("MACNOTEPAD_DATA_DIR", dir.path, 1)
        let good = DocumentTab(title: "keep me", content: "unsaved work", isDirty: true)
        let goodJSON = String(data: try JSONEncoder().encode(good), encoding: .utf8)!
        let broken = #"{"title":"future","language":"Klingon"}"#
        try "[\(goodJSON),\(broken)]".write(to: SessionManager.shared.sessionFileURL, atomically: true, encoding: .utf8)

        let tabs = SessionManager.shared.loadSession()
        XCTAssertEqual(tabs.map(\.content), ["unsaved work"])
        let backups = try FileManager.default.contentsOfDirectory(atPath: SessionManager.shared.appSupportDirectoryURL.path)
            .filter { $0.hasPrefix("session-tabs.unreadable-") }
        XCTAssertEqual(backups.count, 1, "The original session file is kept aside")
    }

    func testNestedTabListItemOutdentsOnEnter() {
        let tv = EditorTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.language = .markdown
        tv.string = "- a\n\t- "
        tv.setSelectedRange(NSRange(location: 7, length: 0))
        tv.insertNewline(nil)
        XCTAssertEqual(tv.string, "- a\n- ")
    }

    func testSessionRestorePreservesMultipleTabs() throws {
        setenv("MACNOTEPAD_DATA_DIR", dir.path, 1)
        let tab1 = DocumentTab(title: "Tab 1", content: "First note", isDirty: true)
        let tab2 = DocumentTab(title: "Tab 2", content: "Second note", isDirty: false)
        SessionManager.shared.saveSession(tabs: [tab1, tab2])

        let restored = SessionManager.shared.loadSession()
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored[0].title, "Tab 1")
        XCTAssertEqual(restored[0].content, "First note")
        XCTAssertEqual(restored[1].title, "Tab 2")
    }
}
