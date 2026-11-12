import XCTest
import AppKit
@testable import MacNotepad

/// Drives the real `EditorTextView` (no window needed) to verify the editing commands.
final class EditorBehaviorTests: XCTestCase {
    private func editor(_ text: String, language: SyntaxLanguage = .markdown, caret: Int? = nil, selection: NSRange? = nil) -> EditorTextView {
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
        let tv = editor(original, language: .swift, selection: NSRange(location: 0, length: (original as NSString).length))
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
        let tv = editor("a\nb", language: .swift, selection: NSRange(location: 0, length: 3))
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
        let tv = editor("func a() {}", language: .swift, caret: 10)
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

    // MARK: Notepad-style Markdown formatting

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
}

/// Markdown styling, session storage, and URL handling tests.
final class NotepadSessionAndMarkdownTests: XCTestCase {
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
        let legacy = #"{"theme":"Light","fontSize":15,"wordWrap":false}"#
        let prefs = try JSONDecoder().decode(EditorPreferences.self, from: Data(legacy.utf8))
        XCTAssertEqual(prefs.theme, .light)
        XCTAssertEqual(prefs.fontSize, 15)
        XCTAssertFalse(prefs.wordWrap)
        XCTAssertTrue(prefs.liveMarkdownStyling, "New options get defaults")
    }

    @MainActor
    func testURLSchemeNewTab() throws {
        let store = WorkspaceStore.shared
        let before = store.tabs.count
        store.handle(url: URL(string: "macnotepad://new?title=Idea.md&text=Hello%20world")!)
        XCTAssertEqual(store.tabs.count, before + 1)
        XCTAssertEqual(store.activeTab?.content, "Hello world")
        XCTAssertEqual(store.activeTab?.language, .markdown)
    }
}
