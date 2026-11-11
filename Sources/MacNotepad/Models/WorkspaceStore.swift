#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// App-wide state shared by the main window, the menu bar, the menu-bar quick note, Finder "Open With",
/// the `macnotepad://` URL scheme and the `mnp` command-line tool.
@MainActor
public final class WorkspaceStore: ObservableObject {
    public static let shared = WorkspaceStore()

    @Published public var tabs: [DocumentTab] {
        didSet {
            if preferences.persistentUnsavedTabs { SessionManager.shared.scheduleSessionSave(tabs: tabs) }
        }
    }
    @Published public var activeTabID: UUID?
    @Published public var preferences: EditorPreferences {
        didSet {
            guard preferences != oldValue else { return }
            SessionManager.shared.savePreferences(preferences)
        }
    }

    // Window UI state that menu commands can toggle.
    @Published public var showFindBar = false
    @Published public var searchOptions = SearchOptions(query: "")
    @Published public var currentMatchIndex = 0
    @Published public var isDiffMode = false
    @Published public var compareLeftTabID: UUID?
    @Published public var compareRightTabID: UUID?
    @Published public var showTextToolsMenu = false
    @Published public var showSettingsSheet = false
    @Published public var showFindInFilesSheet = false
    @Published public var showCommandPalette = false
    /// Distraction-free writing: hides the toolbar, tab strip, sidebars and status bar, and centres the text column.
    /// Session-only, so the app always reopens with its normal chrome.
    @Published public var focusMode = false
    @Published public var findInFilesResults: [SearchMatch] = []
    @Published public var statusBannerMessage: String?
    /// Tabs whose file changed on disk while they had unsaved edits.
    @Published public var externallyChangedTabIDs: Set<UUID> = []
    /// Bumped whenever notes are created, saved or deleted so the library sidebar rescans.
    @Published public var libraryRevision = 0

    private var fileWatchTimer: Timer?

    /// Recently closed tabs (newest last) for Reopen Closed Tab.
    private var closedTabs: [DocumentTab] = []

    init() {
        let prefs = SessionManager.shared.loadPreferences()
        preferences = prefs
        // With Hot Exit off, an old session file is ignored rather than resurrected.
        tabs = prefs.persistentUnsavedTabs ? SessionManager.shared.loadSession() : SessionManager.defaultStarterTabs()
        activeTabID = tabs.first?.id
        SessionManager.shared.ensureDefaultSaveDirectory(preferences: preferences)
        fileWatchTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForExternalChanges() }
        }
    }

    public var activeTabIndex: Int? {
        guard let id = activeTabID ?? tabs.first?.id else { return nil }
        return tabs.firstIndex { $0.id == id }
    }

    public var activeTab: DocumentTab? { activeTabIndex.map { tabs[$0] } }

    /// The outline shows when turned on, or automatically for Markdown notes with headings.
    public func isOutlineVisible(for tab: DocumentTab?) -> Bool {
        guard let tab, !isDiffMode else { return false }
        if preferences.showOutline { return true }
        return preferences.autoOutlineForMarkdown && tab.language == .markdown
            && !MarkdownService.headings(in: tab.content).isEmpty
    }

    /// Hiding the outline also stops it appearing automatically, so the choice sticks.
    public func toggleOutline() {
        if isOutlineVisible(for: activeTab) {
            preferences.showOutline = false
            preferences.autoOutlineForMarkdown = false
        } else {
            preferences.showOutline = true
        }
    }

    public var notesDirectory: URL {
        SessionManager.shared.ensureDefaultSaveDirectory(preferences: preferences)
    }

    // MARK: - Tabs

    @discardableResult
    public func newTab(title: String? = nil, content: String = "", language: SyntaxLanguage = .plainText, cursorAtEnd: Bool = false) -> UUID {
        let name = title ?? nextScratchTitle()
        var tab = DocumentTab(title: name, content: content, isDirty: !content.isEmpty, language: language)
        if cursorAtEnd {
            let lines = content.components(separatedBy: "\n")
            tab.cursorLine = lines.count
            tab.cursorColumn = ((lines.last ?? "") as NSString).length + 1
        }
        tabs.append(tab)
        activeTabID = tab.id
        isDiffMode = false
        return tab.id
    }

    /// New Markdown note, optionally inside a library folder.
    public func newNote(in folder: URL? = nil, title: String = "Untitled") {
        let id = newTab(title: "\(title).md", content: "# \(title)\n\n", language: .markdown, cursorAtEnd: true)
        if let folder, let idx = tabs.firstIndex(where: { $0.id == id }) {
            tabs[idx].pendingFolder = folder
        }
    }

    private func nextScratchTitle() -> String {
        var n = 1
        let titles = Set(tabs.map(\.title))
        while titles.contains("new \(n)") { n += 1 }
        return "new \(n)"
    }

    /// Closes a tab. Tabs with unsaved changes ask first (Save / Don't Save / Cancel).
    public func closeTab(_ id: UUID, confirmIfDirty: Bool = true) {
        CodeEditorView.flushPendingEdits()
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        if confirmIfDirty, tabs[idx].isDirty, !tabs[idx].content.isEmpty || tabs[idx].fileURL != nil {
            let alert = NSAlert()
            alert.messageText = "Save changes to “\(tabs[idx].title)”?"
            alert.informativeText = "Your changes will be lost if you don't save them."
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Don't Save")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                activeTabID = id
                save()
                guard let i = tabs.firstIndex(where: { $0.id == id }), !tabs[i].isDirty else { return } // save failed or cancelled
            case .alertSecondButtonReturn:
                return
            default:
                break
            }
        }
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        closedTabs.append(tabs[idx])
        if closedTabs.count > 20 { closedTabs.removeFirst() }
        CodeEditorView.forgetUndoHistory(for: id)
        let wasActive = (activeTabID ?? tabs.first?.id) == id
        tabs.remove(at: idx)
        externallyChangedTabIDs.remove(id)
        if tabs.isEmpty {
            newTab()
        } else if wasActive {
            activeTabID = tabs[min(idx, tabs.count - 1)].id
        }
    }

    public func reopenClosedTab() {
        guard let tab = closedTabs.popLast() else { NSSound.beep(); return }
        tabs.append(tab)
        activeTabID = tab.id
        isDiffMode = false
    }

    public func closeActiveTab() {
        if let id = activeTabID ?? tabs.first?.id { closeTab(id) }
    }

    public func moveTab(_ id: UUID, before targetID: UUID) {
        guard id != targetID, let from = tabs.firstIndex(where: { $0.id == id }),
              let to = tabs.firstIndex(where: { $0.id == targetID }) else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: from < to ? to - 1 : to)
    }

    public func selectTab(offset: Int) {
        guard let idx = activeTabIndex, !tabs.isEmpty else { return }
        activeTabID = tabs[(idx + offset + tabs.count) % tabs.count].id
    }

    public func selectTab(number: Int) {
        guard !tabs.isEmpty else { return }
        activeTabID = tabs[min(number, tabs.count) - 1].id
    }

    // MARK: - Opening

    public func open(urls: [URL], line: Int? = nil) {
        for url in urls {
            if let existing = tabs.first(where: { $0.fileURL?.standardizedFileURL == url.standardizedFileURL }) {
                activeTabID = existing.id
                if let line, let idx = tabs.firstIndex(where: { $0.id == existing.id }) { tabs[idx].cursorLine = line; tabs[idx].cursorColumn = 1 }
                continue
            }
            do {
                var tab = try FileService.openTab(at: url)
                if let line { tab.cursorLine = line; tab.cursorColumn = 1 }
                tabs.append(tab)
                activeTabID = tab.id
                addRecent(url)
                if tab.importedFrom != nil {
                    flashStatus("Imported \(url.lastPathComponent) as a note. The original file won't be changed.")
                } else if tab.encoding != .utf8 {
                    flashStatus("Opened \(url.lastPathComponent) (\(tab.encoding.rawValue))")
                } else {
                    flashStatus("Opened \(url.lastPathComponent)")
                }
            } catch {
                flashStatus(error.localizedDescription)
            }
        }
        isDiffMode = false
        NSApp?.activate(ignoringOtherApps: true)
    }

    public func openFilePanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = notesDirectory
        if panel.runModal() == .OK { open(urls: panel.urls) }
    }

    public func addRecent(_ url: URL) {
        var recents = preferences.recentFilePaths.filter { $0 != url.path }
        recents.insert(url.path, at: 0)
        preferences.recentFilePaths = Array(recents.prefix(15))
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    public func clearRecents() {
        preferences.recentFilePaths = []
        NSDocumentController.shared.clearRecentDocuments(nil)
    }

    /// Re-reads the active file using a different encoding (e.g. a legacy file that was mis-detected).
    public func reopenActiveTab(with encoding: DocumentEncoding) {
        guard let idx = activeTabIndex, let url = tabs[idx].fileURL else {
            flashStatus("Save the file first to reopen it with another encoding")
            return
        }
        guard let reloaded = try? FileService.openTab(at: url, forcedEncoding: encoding) else {
            flashStatus("Couldn't read \(url.lastPathComponent) as \(encoding.rawValue)")
            return
        }
        tabs[idx].content = reloaded.content
        tabs[idx].encoding = encoding
        tabs[idx].isDirty = false
        flashStatus("Reopened as \(encoding.rawValue)")
    }

    // MARK: - Saving

    /// ⌘S: saves to the tab's file, or into the notes folder for new notes and imported documents.
    public func save() {
        CodeEditorView.flushPendingEdits()
        guard let idx = activeTabIndex else { return }
        do {
            let url: URL
            if tabs[idx].fileURL == nil, let folder = tabs[idx].pendingFolder {
                var tab = tabs[idx]
                let fileName = tab.title.contains(".") ? tab.title : "\(tab.title).\(tab.language.defaultFileExtension)"
                url = FileService.uniqueURL(in: folder, fileName: suggestedNoteFileName(for: tab) ?? fileName)
                try FileService.write(&tab, to: url)
                tab.pendingFolder = nil
                tabs[idx] = tab
            } else {
                if tabs[idx].fileURL == nil, let name = suggestedNoteFileName(for: tabs[idx]) {
                    tabs[idx].title = name
                }
                url = try SessionManager.shared.quickSaveToDefaultDirectory(tab: &tabs[idx], preferences: preferences)
            }
            externallyChangedTabIDs.remove(tabs[idx].id)
            addRecent(url)
            libraryRevision += 1
            flashStatus("Saved \(url.lastPathComponent)")
        } catch {
            flashStatus("Save failed: \(error.localizedDescription)")
        }
    }

    /// Untitled Markdown notes are named after their first heading when first saved.
    private func suggestedNoteFileName(for tab: DocumentTab) -> String? {
        guard tab.fileURL == nil, tab.language == .markdown,
              tab.title.hasPrefix("Untitled") || tab.title.hasPrefix("new ") || tab.title.hasPrefix("Quick Note"),
              let title = MarkdownService.title(of: tab.content) else { return nil }
        let safe = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespaces)
        return safe.isEmpty ? nil : "\(safe.prefix(80)).md"
    }

    public func saveAs() {
        guard let idx = activeTabIndex else { return }
        let panel = NSSavePanel()
        panel.directoryURL = tabs[idx].fileURL?.deletingLastPathComponent() ?? notesDirectory
        panel.nameFieldStringValue = tabs[idx].title.contains(".")
            ? tabs[idx].title
            : "\(tabs[idx].title).\(tabs[idx].language.defaultFileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try FileService.write(&tabs[idx], to: url)
            tabs[idx].importedFrom = nil
            tabs[idx].pendingFolder = nil
            addRecent(url)
            libraryRevision += 1
            flashStatus("Saved \(url.lastPathComponent)")
        } catch {
            flashStatus(error.localizedDescription)
        }
    }

    public func saveAll() {
        let current = activeTabID
        for tab in tabs where tab.isDirty && tab.fileURL != nil {
            activeTabID = tab.id
            save()
        }
        activeTabID = current
    }

    public func convertActiveTab(to format: ExportDocumentFormat, useSavePanel: Bool) {
        guard let tab = activeTab else { return }
        let baseName = tab.baseName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        let fileName = "\(baseName.isEmpty ? "document" : baseName).\(format.fileExtension)"
        let destination: URL
        if useSavePanel {
            let panel = NSSavePanel()
            panel.directoryURL = notesDirectory
            panel.nameFieldStringValue = fileName
            guard panel.runModal() == .OK, let chosen = panel.url else { return }
            destination = chosen
        } else {
            destination = FileService.uniqueURL(in: notesDirectory, fileName: fileName)
        }
        if let source = tab.importedFrom, source.standardizedFileURL == destination.standardizedFileURL {
            flashStatus("Choose a different name so the original \(source.lastPathComponent) is kept")
            return
        }
        do {
            try DocumentConverterService.export(
                content: tab.content, title: tab.baseName, to: destination, format: format,
                fontFamily: preferences.fontFamily, fontSize: preferences.fontSize,
                isMarkdown: tab.language == .markdown)
            flashStatus("Exported \(destination.lastPathComponent)")
            if !useSavePanel { NSWorkspace.shared.activateFileViewerSelecting([destination]) }
        } catch {
            flashStatus(error.localizedDescription)
        }
    }

    public func copyActiveFilePath() {
        guard let tab = activeTab else { return }
        let path = tab.fileURL?.path ?? notesDirectory.appendingPathComponent(tab.title).path
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        flashStatus("Copied path to clipboard")
    }

    public func revealActiveFileInFinder() {
        if let url = activeTab?.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        else { NSWorkspace.shared.open(notesDirectory) }
    }

    // MARK: - External changes

    /// Clean tabs reload silently when their file changes on disk; edited tabs get a Reload / Keep banner.
    public func checkForExternalChanges() {
        for idx in tabs.indices {
            guard let url = tabs[idx].fileURL, let known = tabs[idx].fileModificationDate else { continue }
            // Any difference counts: tools like `cp -p` or sync clients can set an older date.
            guard let current = FileService.modificationDate(of: url), abs(current.timeIntervalSince(known)) > 0.001 else { continue }
            if tabs[idx].isDirty {
                externallyChangedTabIDs.insert(tabs[idx].id)
            } else {
                reloadTab(tabs[idx].id, announce: true)
            }
        }
    }

    public func reloadTab(_ id: UUID, announce: Bool = false) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }), let url = tabs[idx].fileURL,
              let reloaded = try? FileService.openTab(at: url, forcedEncoding: tabs[idx].encoding) else { return }
        tabs[idx].content = reloaded.content
        tabs[idx].isDirty = false
        tabs[idx].fileModificationDate = reloaded.fileModificationDate
        externallyChangedTabIDs.remove(id)
        if announce { flashStatus("\(tabs[idx].title) changed on disk and was reloaded") }
    }

    public func keepLocalVersion(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }), let url = tabs[idx].fileURL else { return }
        tabs[idx].fileModificationDate = FileService.modificationDate(of: url)
        externallyChangedTabIDs.remove(id)
    }

    // MARK: - Quick capture, URL scheme, CLI

    /// Appends a timestamped entry to Inbox.md in the notes folder (used by the menu-bar quick note).
    public func appendToInbox(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let inbox = notesDirectory.appendingPathComponent("Inbox.md")
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
        do {
            var note: DocumentTab
            if FileManager.default.fileExists(atPath: inbox.path) {
                // Read with encoding detection; if it can't be read, stop rather than replace it.
                note = try FileService.openTab(at: inbox)
            } else {
                note = DocumentTab(title: "Inbox.md", content: "# Inbox\n", language: .markdown)
            }
            if !note.content.hasSuffix("\n") { note.content += "\n" }
            note.content += "\n- \(stamp) — \(trimmed)\n"
            try FileService.write(&note, to: inbox)
            if let idx = tabs.firstIndex(where: { $0.fileURL?.standardizedFileURL == inbox.standardizedFileURL }), !tabs[idx].isDirty {
                reloadTab(tabs[idx].id)
            }
            libraryRevision += 1
        } catch {
            flashStatus("Couldn't write Inbox.md: \(error.localizedDescription)")
        }
    }

    /// Opens a fresh quick note tab and brings the window forward (global ⌃⌥N hotkey).
    public func startQuickNote() {
        let stamp = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short)
        newTab(title: "Quick Note.md", content: "# Quick Note — \(stamp)\n\n", language: .markdown, cursorAtEnd: true)
        NSApp?.activate(ignoringOtherApps: true)
        NSApp?.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }

    /// Handles `macnotepad://` links (Shortcuts, Raycast, scripts, the `mnp` CLI):
    /// - `macnotepad://new?title=…&text=…`
    /// - `macnotepad://open?path=/abs/file&line=12`
    /// - `macnotepad://append?text=…` (adds to Inbox.md)
    /// - `macnotepad://quicknote`
    public func handle(url: URL) {
        if url.isFileURL { open(urls: [url]); return }
        guard url.scheme == "macnotepad" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ key: String) -> String? { items.first { $0.name == key }?.value }
        switch url.host {
        case "new":
            let text = value("text") ?? ""
            let title = value("title")
            let isMarkdown = title?.hasSuffix(".md") ?? true
            newTab(title: title ?? "Untitled.md", content: text, language: isMarkdown ? .markdown : .plainText, cursorAtEnd: true)
        case "open":
            if let path = value("path") {
                open(urls: [URL(fileURLWithPath: (path as NSString).expandingTildeInPath)], line: value("line").flatMap(Int.init))
            }
        case "append":
            if let text = value("text") { appendToInbox(text); flashStatus("Added to Inbox.md") }
        case "quicknote":
            startQuickNote()
        default:
            break
        }
        NSApp?.activate(ignoringOtherApps: true)
    }

    // MARK: - Status

    public func flashStatus(_ message: String) {
        statusBannerMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak self] in
            if self?.statusBannerMessage == message { self?.statusBannerMessage = nil }
        }
    }

    public func saveSessionNow() {
        if preferences.persistentUnsavedTabs {
            SessionManager.shared.saveSession(tabs: tabs)
        } else {
            try? FileManager.default.removeItem(at: SessionManager.shared.sessionFileURL)
        }
    }

    /// With Hot Exit off, quitting asks about unsaved tabs. Returns false to cancel quitting.
    public func confirmQuit() -> Bool {
        CodeEditorView.flushPendingEdits()
        guard !preferences.persistentUnsavedTabs else { return true }
        let dirty = tabs.filter { $0.isDirty && (!$0.content.isEmpty || $0.fileURL != nil) }
        guard !dirty.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "You have \(dirty.count) tab\(dirty.count == 1 ? "" : "s") with unsaved changes."
        alert.informativeText = "Hot Exit is off, so unsaved changes will be lost when MacNotepad quits."
        alert.addButton(withTitle: "Save All")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit Without Saving")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            for tab in dirty {
                activeTabID = tab.id
                save()
            }
            return !tabs.contains { $0.isDirty && (!$0.content.isEmpty || $0.fileURL != nil) }
        case .alertSecondButtonReturn:
            return false
        default:
            return true
        }
    }
}
#endif
