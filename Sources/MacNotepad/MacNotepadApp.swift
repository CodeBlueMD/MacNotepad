import Foundation
#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit

@main
struct MacNotepadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var store = WorkspaceStore.shared

    var body: some Scene {
        Window("MacNotepad", id: "main") {
            MainWorkspaceView()
                .frame(minWidth: 700, minHeight: 450)
        }
        .windowStyle(.hiddenTitleBar)
        .commands { MacNotepadCommands(store: store) }
    }
}

/// Handles Finder "Open With", `macnotepad://` links, the Dock menu, and saving the session on quit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Screenshot/demo helper: MACNOTEPAD_WINDOW_SIZE=1440x900 sizes and centers the main window.
        if let size = ProcessInfo.processInfo.environment["MACNOTEPAD_WINDOW_SIZE"]?.split(separator: "x").compactMap({ Double($0) }),
           size.count == 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                guard let window = NSApp.windows.first(where: { $0.canBecomeMain }), let screen = NSScreen.main else { return }
                let frame = NSRect(x: screen.visibleFrame.midX - size[0] / 2, y: screen.visibleFrame.midY - size[1] / 2, width: size[0], height: size[1])
                window.setFrame(frame, display: true)
                window.makeKeyAndOrderFront(nil)
            }
        }
        // Demo helper: MACNOTEPAD_OPEN="/a.md|/b.md" opens files as tabs (the last one is selected).
        if let paths = ProcessInfo.processInfo.environment["MACNOTEPAD_OPEN"], !paths.isEmpty {
            let urls = paths.split(separator: "|").map { URL(fileURLWithPath: String($0)) }
            Task { @MainActor in WorkspaceStore.shared.open(urls: urls) }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for url in urls { WorkspaceStore.shared.handle(url: url) }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let store = WorkspaceStore.shared
            guard store.confirmQuit() else { return .terminateCancel }
            store.saveSessionNow()
            return .terminateNow
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "New Tab", action: #selector(dockNewTab), keyEquivalent: "").target = self
        return menu
    }

    @objc private func dockNewTab() {
        Task { @MainActor in
            WorkspaceStore.shared.newTab()
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

/// Sends an editor command down the responder chain to the focused `EditorTextView`.
func sendEditorAction(_ selector: Selector) {
    NSApp.sendAction(selector, to: nil, from: nil)
}

/// The macOS menu bar: File, Edit, Line, Format, View, Tabs, and Document, with standard shortcuts.
struct MacNotepadCommands: Commands {
    @ObservedObject var store: WorkspaceStore

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { store.showSettingsSheet = true }
                .keyboardShortcut(",", modifiers: .command)
        }

        CommandGroup(replacing: .newItem) {
            Button("New Tab") { store.newTab() }
                .keyboardShortcut("n", modifiers: .command)
            Divider()
            Button("Open…") { store.openFilePanel() }
                .keyboardShortcut("o", modifiers: .command)
            Menu("Open Recent") {
                ForEach(store.preferences.recentFilePaths, id: \.self) { path in
                    Button((path as NSString).abbreviatingWithTildeInPath) { store.open(urls: [URL(fileURLWithPath: path)]) }
                }
                if !store.preferences.recentFilePaths.isEmpty { Divider() }
                Button("Clear Menu") { store.clearRecents() }
                    .disabled(store.preferences.recentFilePaths.isEmpty)
            }
        }

        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") { store.closeActiveTab() }
                .keyboardShortcut("w", modifiers: .command)
            Button("Reopen Closed Tab") { store.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Button("Save") { store.save() }
                .keyboardShortcut("s", modifiers: .command)
            Button("Save As…") { store.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Save All") { store.saveAll() }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Divider()
            Button("Reveal in Finder") { store.revealActiveFileInFinder() }
            Button("Copy File Path") { store.copyActiveFilePath() }
        }

        CommandGroup(after: .textEditing) {
            Divider()
            Button("Find & Replace…") { withAnimation { store.showFindBar.toggle() } }
                .keyboardShortcut("f", modifiers: .command)
            Button("Go to Line…") { sendEditorAction(#selector(EditorTextView.goToLine(_:))) }
                .keyboardShortcut("l", modifiers: .command)
        }

        CommandMenu("Line") {
            Button("Toggle Comment") { sendEditorAction(#selector(EditorTextView.toggleLineComment(_:))) }
                .keyboardShortcut("/", modifiers: .command)
            Button("Duplicate Line") { sendEditorAction(#selector(EditorTextView.duplicateLines(_:))) }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("Delete Line") { sendEditorAction(#selector(EditorTextView.deleteLines(_:))) }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Button("Move Line Up") { sendEditorAction(#selector(EditorTextView.moveLinesUp(_:))) }
                .keyboardShortcut(.upArrow, modifiers: .option)
            Button("Move Line Down") { sendEditorAction(#selector(EditorTextView.moveLinesDown(_:))) }
                .keyboardShortcut(.downArrow, modifiers: .option)
            Divider()
            Button("Indent") { sendEditorAction(#selector(EditorTextView.indentLines(_:))) }
                .keyboardShortcut("]", modifiers: .command)
            Button("Outdent") { sendEditorAction(#selector(EditorTextView.outdentLines(_:))) }
                .keyboardShortcut("[", modifiers: .command)
        }

        CommandMenu("Format") {
            Button("Bold") { sendEditorAction(#selector(EditorTextView.toggleBold(_:))) }
                .keyboardShortcut("b", modifiers: .command)
            Button("Italic") { sendEditorAction(#selector(EditorTextView.toggleItalic(_:))) }
                .keyboardShortcut("i", modifiers: .command)
            Button("Strikethrough") { sendEditorAction(#selector(EditorTextView.toggleStrikethrough(_:))) }
                .keyboardShortcut("x", modifiers: [.command, .shift])
            Button("Highlight") { sendEditorAction(#selector(EditorTextView.toggleHighlight(_:))) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Inline Code") { sendEditorAction(#selector(EditorTextView.toggleInlineCode(_:))) }
                .keyboardShortcut("e", modifiers: .command)
            Button("Link…") { sendEditorAction(#selector(EditorTextView.insertLink(_:))) }
                .keyboardShortcut("k", modifiers: .command)
            Divider()
            Button("Text") { sendEditorAction(#selector(EditorTextView.makeBodyText(_:))) }
                .keyboardShortcut("0", modifiers: [.command, .option])
            Button("Heading 1") { sendEditorAction(#selector(EditorTextView.makeHeading1(_:))) }
                .keyboardShortcut("1", modifiers: [.command, .option])
            Button("Heading 2") { sendEditorAction(#selector(EditorTextView.makeHeading2(_:))) }
                .keyboardShortcut("2", modifiers: [.command, .option])
            Button("Heading 3") { sendEditorAction(#selector(EditorTextView.makeHeading3(_:))) }
                .keyboardShortcut("3", modifiers: [.command, .option])
            Button("To-do List") { sendEditorAction(#selector(EditorTextView.makeTodo(_:))) }
                .keyboardShortcut("4", modifiers: [.command, .option])
            Button("Bulleted List") { sendEditorAction(#selector(EditorTextView.makeBullet(_:))) }
                .keyboardShortcut("5", modifiers: [.command, .option])
            Button("Numbered List") { sendEditorAction(#selector(EditorTextView.makeNumbered(_:))) }
                .keyboardShortcut("6", modifiers: [.command, .option])
            Button("Quote") { sendEditorAction(#selector(EditorTextView.makeQuote(_:))) }
                .keyboardShortcut("7", modifiers: [.command, .option])
            Divider()
            Button("Toggle Checkbox") { sendEditorAction(#selector(EditorTextView.toggleCheckbox(_:))) }
                .keyboardShortcut(.return, modifiers: .command)
            Button("Insert Today's Date") { sendEditorAction(#selector(EditorTextView.insertDate(_:))) }
                .keyboardShortcut(";", modifiers: [.command, .shift])
        }

        CommandGroup(after: .sidebar) {
            Toggle("Live Markdown Styling", isOn: $store.preferences.liveMarkdownStyling)
            Toggle("Show Line Numbers", isOn: $store.preferences.showLineNumbers)
            Toggle("Show Invisibles", isOn: $store.preferences.showWhitespace)
                .keyboardShortcut("i", modifiers: [.command, .option])
            Toggle("Word Wrap", isOn: $store.preferences.wordWrap)
                .keyboardShortcut("z", modifiers: [.command, .option])
            Picker("Theme", selection: $store.preferences.theme) {
                ForEach(AppTheme.allCases) { Text($0.rawValue).tag($0) }
            }
            Divider()
            Button("Zoom In") { store.preferences.zoomPercentage = min(300, store.preferences.zoomPercentage + 10) }
                .keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out") { store.preferences.zoomPercentage = max(50, store.preferences.zoomPercentage - 10) }
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { store.preferences.zoomPercentage = 100 }
                .keyboardShortcut("0", modifiers: .command)
            Divider()
            Toggle("Focus Mode", isOn: $store.focusMode)
                .keyboardShortcut("f", modifiers: [.command, .option])
        }

        CommandMenu("Tabs") {
            Button("Next Tab") { store.selectTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { store.selectTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            ForEach(1..<10) { n in
                Button("Tab \(n)") { store.selectTab(number: n) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")), modifiers: .command)
            }
        }

        CommandMenu("Document") {
            Menu("Reopen with Encoding") {
                ForEach(DocumentEncoding.allCases) { encoding in
                    Button(encoding.rawValue) { store.reopenActiveTab(with: encoding) }
                }
            }
            Menu("Convert Encoding To") {
                ForEach(DocumentEncoding.allCases) { encoding in
                    Button(encoding.rawValue) {
                        if let idx = store.activeTabIndex { store.tabs[idx].encoding = encoding; store.tabs[idx].isDirty = true }
                    }
                }
            }
            Menu("Line Endings") {
                ForEach(LineEnding.allCases) { ending in
                    Button(ending == .lf ? "macOS / Unix (LF)" : "Windows (CRLF)") {
                        if let idx = store.activeTabIndex { store.tabs[idx].lineEnding = ending; store.tabs[idx].isDirty = true }
                    }
                }
            }
            Divider()
            Button("Install Command Line Tool (mnp)…") { CommandLineInstaller.install(store: store) }
        }
    }
}
#else
@main
struct MacNotepadCLI {
    static func main() {
        let prefs = SessionManager.shared.loadPreferences()
        print("MacNotepad Core Engine Ready — Default Save Location: \(prefs.defaultSaveDirectoryPath)")
    }
}
#endif
