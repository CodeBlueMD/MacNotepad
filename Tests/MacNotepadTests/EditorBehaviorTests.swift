import XCTest
import AppKit
@testable import MacNotepad

/// Drives the real `EditorTextView` (no window needed) to verify the editing commands.
final class EditorBehaviorTests: XCTestCase {
    private func editor(_ text: String, language: SyntaxLanguage = .swift, caret: Int? = nil, selection: NSRange? = nil) -> EditorTextView {
        let tv = EditorTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tv.isRichText = false
        tv.allowsUndo = true
        tv.language = language
        tv.autoCloseBrackets = true
        tv.string = text
        if let selection { tv.setSelectedRange(selection) }
        else { tv.setSelectedRange(NSRange(location: caret ?? 0, length: 0)) }
        return tv
    }

    private func type(_ tv: EditorTextView, _ text: String) {
        tv.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    // MARK: Line tools

    func testDuplicateMoveAndDeleteLines() {
        let tv = editor("a\nb\nc", caret: 2)
        tv.duplicateLines(nil)
        XCTAssertEqual(tv.string, "a\nb\nb\nc")

        let up = editor("a\nb\nc", caret: 4)
        up.moveLinesUp(nil)
        XCTAssertEqual(up.string, "a\nc\nb")

        let down = editor("a\nb\nc", caret: 0)
        down.moveLinesDown(nil)
        XCTAssertEqual(down.string, "b\na\nc")

        let del = editor("a\nb\nc", caret: 2)
        del.deleteLines(nil)
        XCTAssertEqual(del.string, "a\nc")
    }

    func testToggleCommentRoundTrips() {
        let original = "let x = 1\nlet y = 2"
        let tv = editor(original, selection: NSRange(location: 0, length: (original as NSString).length))
        tv.toggleLineComment(nil)
        XCTAssertEqual(tv.string, "// let x = 1\n// let y = 2")
        tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
        tv.toggleLineComment(nil)
        XCTAssertEqual(tv.string, original)

        let py = editor("print(1)", language: .python)
        py.toggleLineComment(nil)
        XCTAssertEqual(py.string, "# print(1)")
    }

    func testIndentAndOutdent() {
        let tv = editor("a\nb", selection: NSRange(location: 0, length: 3))
        tv.indentLines(nil)
        XCTAssertEqual(tv.string, "    a\n    b")
        tv.outdentLines(nil)
        XCTAssertEqual(tv.string, "a\nb")
    }

    // MARK: Typing helpers

    func testAutoClosingBracketsAndStepOver() {
        let tv = editor("", caret: 0)
        type(tv, "(")
        XCTAssertEqual(tv.string, "()")
        XCTAssertEqual(tv.selectedRange().location, 1)
        type(tv, ")")
        XCTAssertEqual(tv.string, "()")
        XCTAssertEqual(tv.selectedRange().location, 2)

        let del = editor("", caret: 0)
        type(del, "[")
        del.deleteBackward(nil)
        XCTAssertEqual(del.string, "", "Backspace inside an empty pair removes both characters")

        let wrap = editor("value", selection: NSRange(location: 0, length: 5))
        type(wrap, "\"")
        XCTAssertEqual(wrap.string, "\"value\"")
    }

    func testSmartIndentInsideBraces() {
        let tv = editor("func a() {}", caret: 10)
        tv.insertNewline(nil)
        XCTAssertEqual(tv.string, "func a() {\n    \n}")
        XCTAssertEqual(tv.selectedRange().location, 15)
    }

    func testMarkdownListContinuationAndExit() {
        let todo = editor("- [x] done", language: .markdown, caret: 10)
        todo.insertNewline(nil)
        XCTAssertEqual(todo.string, "- [x] done\n- [ ] ", "New to-dos start unchecked")

        let numbered = editor("1. one", language: .markdown, caret: 6)
        numbered.insertNewline(nil)
        XCTAssertEqual(numbered.string, "1. one\n2. ")

        let exit = editor("- item\n- ", language: .markdown, caret: 9)
        exit.insertNewline(nil)
        XCTAssertEqual(exit.string, "- item\n", "Enter on an empty bullet ends the list")
    }

    func testMultiCursorTyping() {
        let tv = editor("ab\nab\nab", selection: NSRange(location: 0, length: 2))
        tv.selectAllOccurrences(nil)
        XCTAssertEqual(tv.selectedRanges.count, 3)
        type(tv, "X")
        XCTAssertEqual(tv.string, "X\nX\nX")

        let next = editor("foo bar foo baz foo", selection: NSRange(location: 0, length: 3))
        next.selectNextOccurrence(nil)
        next.selectNextOccurrence(nil)
        XCTAssertEqual(next.selectedRanges.count, 3)

        let ends = editor("a\nbb\nccc", selection: NSRange(location: 0, length: 8))
        ends.addCursorsToLineEnds(nil)
        type(ends, ";")
        XCTAssertEqual(ends.string, "a;\nbb;\nccc;")
    }

    // MARK: Notion-style Markdown formatting

    func testInlineFormattingToggles() {
        let tv = editor("make this bold", language: .markdown, selection: NSRange(location: 10, length: 4))
        tv.toggleBold(nil)
        XCTAssertEqual(tv.string, "make this **bold**")
        tv.toggleBold(nil)
        XCTAssertEqual(tv.string, "make this bold")

        let code = editor("run ls now", language: .markdown, selection: NSRange(location: 4, length: 2))
        code.toggleInlineCode(nil)
        XCTAssertEqual(code.string, "run `ls` now")
    }

    func testBlockTypes() {
        let tv = editor("Title", language: .markdown, caret: 2)
        tv.makeHeading2(nil)
        XCTAssertEqual(tv.string, "## Title")
        tv.makeTodo(nil)
        XCTAssertEqual(tv.string, "- [ ] Title")
        tv.toggleCheckbox(nil)
        XCTAssertEqual(tv.string, "- [x] Title")
        tv.makeBodyText(nil)
        XCTAssertEqual(tv.string, "Title")

        let list = editor("a\nb\nc", language: .markdown, selection: NSRange(location: 0, length: 5))
        list.makeNumbered(nil)
        XCTAssertEqual(list.string, "1. a\n2. b\n3. c")
    }

    func testCheckboxHitTesting() {
        let text = "- [ ] buy milk" as NSString
        XCTAssertEqual(MarkdownStyler.checkboxToggleRange(at: 3, in: text), NSRange(location: 3, length: 1))
        XCTAssertNil(MarkdownStyler.checkboxToggleRange(at: 10, in: text))
    }

    // MARK: Folding

    func testFoldRegions() {
        let swift = "struct A {\n    func b() {\n        print(1)\n    }\n}\n"
        let regions = FoldingService.regions(in: swift, language: .swift)
        XCTAssertEqual(regions.map(\.startLine), [1, 2])

        let md = "# One\ntext\n\n## Two\nmore\n# Three\nend"
        let mdRegions = FoldingService.regions(in: md, language: .markdown)
        XCTAssertEqual(mdRegions.map(\.startLine), [1, 4, 6])
        let hidden = (md as NSString).substring(with: mdRegions[0].hiddenRange)
        XCTAssertTrue(hidden.contains("## Two") && hidden.contains("more") && !hidden.contains("# Three"))

        let py = "def f():\n    return 1\n\nx = 2"
        XCTAssertEqual(FoldingService.regions(in: py, language: .python).map(\.startLine), [1])
    }

    func testFoldingHidesTextAndUnfoldRestores() {
        let code = "func a() {\n    one()\n    two()\n}\n"
        let tv = editor(code)
        tv.foldRegions = FoldingService.regions(in: code, language: .swift)
        tv.toggleFold(startingAtLine: 1)
        XCTAssertTrue(tv.hasFolds)
        XCTAssertEqual(tv.string, code, "Folding never changes the text")
        tv.unfoldAll(nil)
        XCTAssertFalse(tv.hasFolds)
    }
}

/// Markdown engine, outlines, palette ranking and app-level wiring.
final class NotesFeatureTests: XCTestCase {
    func testMarkdownToHTML() {
        let html = MarkdownService.html(from: """
        # Title
        Some **bold** and `code` and a [link](https://a.b).

        - [x] done
        - [ ] todo

        | A | B |
        | --- | --- |
        | 1 | 2 |

        > 💡 Callout
        """)
        XCTAssertTrue(html.contains("<h1 id=\"title\">Title</h1>"))
        XCTAssertTrue(html.contains("<strong>bold</strong>"))
        XCTAssertTrue(html.contains("<code>code</code>"))
        XCTAssertTrue(html.contains("<a href=\"https://a.b\">link</a>"))
        XCTAssertTrue(html.contains("type=\"checkbox\" disabled checked"))
        XCTAssertTrue(html.contains("<td>1</td><td>2</td>"))
        XCTAssertTrue(html.contains("class=\"callout\""))
    }

    func testMixedListsRenderAsSeparateLists() {
        let html = MarkdownService.html(from: "- a\n  - nested\n1. one\n2. two")
        XCTAssertTrue(html.contains("<ol><li>one"), html)
    }

    func testHTMLIsEscaped() {
        XCTAssertFalse(MarkdownService.html(from: "<script>alert(1)</script>").contains("<script>"))
    }

    func testNoteMetadata() {
        let note = "# Plan\n#work #q1\n- [ ] a\n- [x] b\n```\n#notatag\n```"
        XCTAssertEqual(MarkdownService.title(of: note), "Plan")
        XCTAssertEqual(MarkdownService.tags(in: note), ["work", "q1"])
        XCTAssertEqual(MarkdownService.taskCounts(in: note).open, 1)
        XCTAssertEqual(MarkdownService.taskCounts(in: note).done, 1)
        XCTAssertEqual(MarkdownService.headings(in: "# A\n## B\ntext").map(\.title), ["A", "B"])
    }

    func testCodeOutline() {
        let swift = "struct A {\n    func run() {}\n}\nfinal class B {}"
        XCTAssertEqual(CodeOutline.symbols(in: swift, language: .swift).map(\.title), ["struct A", "func run", "class B"])
    }

    func testNotesLibraryScanAndFilter() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Work"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "# Launch\n#work\n- [ ] ship".write(to: dir.appendingPathComponent("Work/launch.md"), atomically: true, encoding: .utf8)
        try "# Groceries\n#home milk".write(to: dir.appendingPathComponent("list.md"), atomically: true, encoding: .utf8)

        let library = NotesLibrary.scan(dir)
        XCTAssertEqual(library.allNotes.count, 2)
        XCTAssertEqual(library.subfolders.first?.name, "Work")
        XCTAssertEqual(library.subfolders.first?.notes.first?.title, "Launch")
        XCTAssertEqual(library.subfolders.first?.notes.first?.openTasks, 1)
        XCTAssertEqual(NotesLibrary.filter(library.allNotes, query: "milk", tag: nil).map(\.title), ["Groceries"])
        XCTAssertEqual(NotesLibrary.filter(library.allNotes, query: "", tag: "work").map(\.title), ["Launch"])
    }

    func testCommandPaletteFuzzyRanking() {
        XCTAssertNotNil(CommandPaletteView.score("Toggle Markdown Preview", "tmp"))
        XCTAssertNil(CommandPaletteView.score("Save", "xyz"))
        XCTAssertGreaterThan(CommandPaletteView.score("Save", "save")!, CommandPaletteView.score("Save As…", "sv")!)
    }

    func testSessionDoesNotDuplicateSavedFiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("big.txt")
        try "on disk".write(to: url, atomically: true, encoding: .utf8)

        let clean = try FileService.openTab(at: url)
        let dirty = DocumentTab(title: "new 1", content: "unsaved", isDirty: true)
        let compact = SessionManager.compactForSession([clean, dirty])
        XCTAssertEqual(compact[0].content, "", "Clean file-backed tabs are reloaded from disk instead")
        XCTAssertEqual(compact[0].contentStoredOnDisk, true)
        XCTAssertEqual(compact[1].content, "unsaved", "Unsaved tabs are always kept")
    }

    func testOldPreferencesStillLoad() throws {
        let legacy = #"{"theme":"Light","fontSize":15,"wordWrap":false,"enableCodeFolding":true}"#
        let prefs = try JSONDecoder().decode(EditorPreferences.self, from: Data(legacy.utf8))
        XCTAssertEqual(prefs.theme, .light)
        XCTAssertEqual(prefs.fontSize, 15)
        XCTAssertFalse(prefs.wordWrap)
        XCTAssertTrue(prefs.liveMarkdownStyling, "New options get defaults")
    }

    @MainActor
    func testURLSchemeAndInbox() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        setenv("MACNOTEPAD_DATA_DIR", dir.path, 1)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = WorkspaceStore.shared
        store.preferences.defaultSaveDirectoryPath = dir.appendingPathComponent("Notes").path

        let before = store.tabs.count
        store.handle(url: URL(string: "macnotepad://new?title=Idea.md&text=Hello%20world")!)
        XCTAssertEqual(store.tabs.count, before + 1)
        XCTAssertEqual(store.activeTab?.content, "Hello world")
        XCTAssertEqual(store.activeTab?.language, .markdown)

        store.handle(url: URL(string: "macnotepad://append?text=Buy%20milk")!)
        let inbox = try String(contentsOf: dir.appendingPathComponent("Notes/Inbox.md"), encoding: .utf8)
        XCTAssertTrue(inbox.contains("Buy milk"))
    }
}
