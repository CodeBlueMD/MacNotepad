import XCTest
import AppKit
@testable import MacNotepad

/// Regression tests for issues found in code review.
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

    @MainActor
    func testInboxAppendKeepsExistingNonUTF8Content() throws {
        setenv("MACNOTEPAD_DATA_DIR", dir.path, 1)
        let store = WorkspaceStore.shared
        let notes = dir.appendingPathComponent("Notes")
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        store.preferences.defaultSaveDirectoryPath = notes.path
        let inbox = notes.appendingPathComponent("Inbox.md")
        try "# Inbox\n\n- earlier thought ✓\n".data(using: .utf16)!.write(to: inbox)

        store.appendToInbox("new thought")
        let tab = try FileService.openTab(at: inbox)
        XCTAssertTrue(tab.content.contains("earlier thought ✓"), tab.content)
        XCTAssertTrue(tab.content.contains("new thought"), tab.content)
        XCTAssertEqual(tab.encoding, .utf16, "The file keeps its encoding")
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

    func testSeparateNumberedListsRestartAndControlCharactersAreStripped() throws {
        let url = dir.appendingPathComponent("lists.docx")
        try DocxExporter.write(markdown: "1. a\n2. b\n\nBreak\u{0C} here\n\n1. c\n2. d\n", title: "Lists", to: url)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-p", url.path, "word/document.xml"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let xml = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        process.waitUntilExit()
        XCTAssertTrue(xml.contains("w:numId w:val=\"2\"") && xml.contains("w:numId w:val=\"3\""), "Two lists, two numberings")
        XCTAssertFalse(xml.contains("\u{0C}"))
        XCTAssertNotNil(try? XMLDocument(data: Data(xml.utf8)), "document.xml must be well-formed")

        let reopened = try FileService.openTab(at: url).content
        XCTAssertTrue(reopened.contains("1. c\n2. d"), reopened)
    }

    func testFoldedAttributeNeverBecomesATypingAttribute() {
        let coordinator = CodeEditorView.Coordinator(CodeEditorView(tab: .constant(DocumentTab(title: "t")), preferences: EditorPreferences()))
        let result = coordinator.textView(NSTextView(), shouldChangeTypingAttributes: [:],
                                          toAttributes: [.macNotepadFolded: true, .foregroundColor: NSColor.red])
        XCTAssertNil(result[.macNotepadFolded])
        XCTAssertNotNil(result[.foregroundColor])
    }

    func testNestedTabListItemOutdentsOnEnter() {
        let tv = EditorTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        tv.language = .markdown
        tv.string = "- a\n\t- "
        tv.setSelectedRange(NSRange(location: 7, length: 0))
        tv.insertNewline(nil)
        XCTAssertEqual(tv.string, "- a\n- ")
    }

    @MainActor
    func testNotepadStyleDefaultsAndAutomaticOutline() {
        XCTAssertFalse(EditorPreferences().showSidebar, "Opens like Notepad: no library panel")
        let store = WorkspaceStore.shared
        store.preferences.showOutline = false
        store.preferences.autoOutlineForMarkdown = true
        XCTAssertTrue(store.isOutlineVisible(for: DocumentTab(title: "a.md", content: "# Plan\ntext", language: .markdown)))
        XCTAssertFalse(store.isOutlineVisible(for: DocumentTab(title: "a.md", content: "no headings", language: .markdown)))
        XCTAssertFalse(store.isOutlineVisible(for: DocumentTab(title: "a.txt", content: "# not markdown", language: .plainText)))
        store.preferences.showOutline = true
        XCTAssertTrue(store.isOutlineVisible(for: DocumentTab(title: "a.swift", content: "func a() {}", language: .swift)))
        store.preferences.showOutline = false
    }
}
