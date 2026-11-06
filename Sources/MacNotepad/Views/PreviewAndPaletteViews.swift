#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit
import WebKit

/// Live rendered Markdown, updated in place (keeps scroll position) as you type.
struct MarkdownPreviewView: NSViewRepresentable {
    let markdown: String
    let title: String
    let dark: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let webView = WKWebView()
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        load(webView, context: context)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let coordinator = context.coordinator
        if coordinator.dark != dark {
            load(webView, context: context)
            return
        }
        guard coordinator.markdown != markdown else { return }
        coordinator.markdown = markdown
        guard coordinator.loaded else { return } // didFinish applies the latest text
        coordinator.pending?.cancel()
        let work = DispatchWorkItem { [weak webView, weak coordinator] in
            guard let webView, let coordinator else { return }
            coordinator.apply(to: webView)
        }
        coordinator.pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func load(_ webView: WKWebView, context: Context) {
        context.coordinator.dark = dark
        context.coordinator.markdown = markdown
        context.coordinator.loaded = false
        context.coordinator.renderedMarkdown = markdown
        webView.loadHTMLString(MarkdownService.htmlDocument(from: markdown, title: title, dark: dark), baseURL: nil)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var markdown = ""
        var renderedMarkdown = ""
        var dark = true
        var loaded = false
        var pending: DispatchWorkItem?

        /// Swaps in the rendered HTML without reloading, so the scroll position is kept.
        func apply(to webView: WKWebView) {
            guard renderedMarkdown != markdown else { return }
            renderedMarkdown = markdown
            let html = MarkdownService.html(from: markdown)
            guard let data = try? JSONEncoder().encode([html]), let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("document.querySelector('article').innerHTML = \(json)[0];")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded = true
            apply(to: webView)
        }

        /// Links open in the default browser instead of inside the preview.
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.navigationType == .linkActivated, let url = action.request.url {
                if url.fragment != nil, url.scheme == "about" {
                    decisionHandler(.allow)
                    return
                }
                // Only web and mail links open directly; a note must not be able to launch local apps or files.
                if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") {
                    NSWorkspace.shared.open(url)
                } else {
                    let alert = NSAlert()
                    alert.messageText = "Open this link?"
                    alert.informativeText = url.absoluteString
                    alert.addButton(withTitle: "Cancel")
                    alert.addButton(withTitle: "Open")
                    if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(url) }
                }
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

/// ⇧⌘P: search and run any command, open recent files and notes, switch language.
struct CommandPaletteView: View {
    struct Item: Identifiable {
        let id = UUID()
        let title: String
        let detail: String
        let symbol: String
        let action: () -> Void
    }

    @ObservedObject private var store = WorkspaceStore.shared
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool
    let dismiss: () -> Void

    private var allItems: [Item] {
        var items: [Item] = []
        func add(_ title: String, _ detail: String = "", _ symbol: String, _ action: @escaping () -> Void) {
            items.append(Item(title: title, detail: detail, symbol: symbol, action: action))
        }
        func editor(_ title: String, _ shortcut: String, _ symbol: String, _ selector: Selector) {
            add(title, shortcut, symbol) { sendEditorAction(selector) }
        }
        add("New Note", "⌥⌘N", "square.and.pencil") { store.newNote() }
        add("New Tab", "⌘N", "plus.square") { store.newTab() }
        add("New Quick Note", "⌃⌥N", "bolt") { store.startQuickNote() }
        add("Open…", "⌘O", "folder") { store.openFilePanel() }
        add("Save", "⌘S", "square.and.arrow.down") { store.save() }
        add("Save As…", "⇧⌘S", "square.and.arrow.down.on.square") { store.saveAs() }
        add("Close Tab", "⌘W", "xmark") { store.closeActiveTab() }
        add("Find & Replace", "⌘F", "magnifyingglass") { store.showFindBar = true }
        add("Find in Notes Folder", "⇧⌘F", "doc.text.magnifyingglass") {
            store.findInFilesResults = SearchEngine.findInFiles(directoryURL: store.notesDirectory, options: store.searchOptions)
            store.showFindInFilesSheet = true
        }
        editor("Go to Line…", "⌘L", "arrow.right.to.line", #selector(EditorTextView.goToLine(_:)))
        editor("Toggle Comment", "⌘/", "number", #selector(EditorTextView.toggleLineComment(_:)))
        editor("Duplicate Line", "⇧⌘D", "plus.rectangle.on.rectangle", #selector(EditorTextView.duplicateLines(_:)))
        editor("Delete Line", "⇧⌘K", "delete.left", #selector(EditorTextView.deleteLines(_:)))
        editor("Move Line Up", "⌥↑", "arrow.up", #selector(EditorTextView.moveLinesUp(_:)))
        editor("Move Line Down", "⌥↓", "arrow.down", #selector(EditorTextView.moveLinesDown(_:)))
        editor("Select Next Occurrence", "⌘D", "text.cursor", #selector(EditorTextView.selectNextOccurrence(_:)))
        editor("Select All Occurrences", "⇧⌘L", "text.badge.plus", #selector(EditorTextView.selectAllOccurrences(_:)))
        editor("Add Cursors to Line Ends", "⇧⌘I", "character.cursor.ibeam", #selector(EditorTextView.addCursorsToLineEnds(_:)))
        editor("Fold All", "⇧⌥⌘←", "chevron.right", #selector(EditorTextView.foldAll(_:)))
        editor("Unfold All", "⇧⌥⌘→", "chevron.down", #selector(EditorTextView.unfoldAll(_:)))
        editor("Heading 1", "⌥⌘1", "textformat.size.larger", #selector(EditorTextView.makeHeading1(_:)))
        editor("Heading 2", "⌥⌘2", "textformat.size", #selector(EditorTextView.makeHeading2(_:)))
        editor("Heading 3", "⌥⌘3", "textformat.size.smaller", #selector(EditorTextView.makeHeading3(_:)))
        editor("To-do List", "⌥⌘4", "checkmark.square", #selector(EditorTextView.makeTodo(_:)))
        editor("Bulleted List", "⌥⌘5", "list.bullet", #selector(EditorTextView.makeBullet(_:)))
        editor("Numbered List", "⌥⌘6", "list.number", #selector(EditorTextView.makeNumbered(_:)))
        editor("Quote", "⌥⌘7", "text.quote", #selector(EditorTextView.makeQuote(_:)))
        editor("Toggle Checkbox", "⌘↩", "checkmark.circle", #selector(EditorTextView.toggleCheckbox(_:)))
        editor("Insert Table", "", "tablecells", #selector(EditorTextView.insertTable(_:)))
        editor("Insert Divider", "", "minus", #selector(EditorTextView.insertDivider(_:)))
        editor("Insert Today's Date", "⇧⌘;", "calendar", #selector(EditorTextView.insertDate(_:)))
        editor("Bold", "⌘B", "bold", #selector(EditorTextView.toggleBold(_:)))
        editor("Italic", "⌘I", "italic", #selector(EditorTextView.toggleItalic(_:)))
        editor("Highlight", "⇧⌘H", "highlighter", #selector(EditorTextView.toggleHighlight(_:)))
        editor("Link", "⌘K", "link", #selector(EditorTextView.insertLink(_:)))
        add("Toggle Notes Library", "⌃⌘S", "sidebar.left") { store.preferences.showSidebar.toggle() }
        add("Toggle Outline", "⌃⌘O", "list.bullet.indent") { store.toggleOutline() }
        add("Toggle Markdown Preview", "⌥⌘P", "eye") { store.preferences.showPreview.toggle() }
        add("Toggle Live Markdown Styling", "", "textformat") { store.preferences.liveMarkdownStyling.toggle() }
        add("Toggle Word Wrap", "⌥⌘Z", "text.word.spacing") { store.preferences.wordWrap.toggle() }
        add("Toggle Invisibles", "⌥⌘I", "paragraphsign") { store.preferences.showWhitespace.toggle() }
        add("Toggle Line Numbers", "", "list.number") { store.preferences.showLineNumbers.toggle() }
        add("Compare Tabs Side by Side", "⌥⌘D", "rectangle.split.2x1") { store.isDiffMode.toggle() }
        for theme in AppTheme.allCases {
            add("Theme: \(theme.rawValue)", "", "circle.lefthalf.filled") { store.preferences.theme = theme }
        }
        for format in ExportDocumentFormat.allCases {
            add("Export as \(format.rawValue)", "", format.iconName) { store.convertActiveTab(to: format, useSavePanel: true) }
        }
        for action in TextToolAction.allCases {
            add(action.rawValue, "Text Tool", "wand.and.stars") {
                guard let idx = store.activeTabIndex else { return }
                do {
                    store.tabs[idx].content = try TextToolsService.apply(action, to: store.tabs[idx].content)
                    store.tabs[idx].isDirty = true
                } catch { store.flashStatus(error.localizedDescription) }
            }
        }
        for language in SyntaxLanguage.allCases {
            add("Language: \(language.rawValue)", "", "chevron.left.forwardslash.chevron.right") {
                if let idx = store.activeTabIndex { store.tabs[idx].language = language }
            }
        }
        for path in store.preferences.recentFilePaths {
            add("Open Recent: \((path as NSString).lastPathComponent)", (path as NSString).abbreviatingWithTildeInPath, "clock") {
                store.open(urls: [URL(fileURLWithPath: path)])
            }
        }
        for tab in store.tabs {
            add("Switch to Tab: \(tab.title)", "", "doc") { store.activeTabID = tab.id }
        }
        add("Install Command Line Tool (mnp)", "", "terminal") { CommandLineInstaller.install(store: store) }
        add("Settings", "⌘,", "gearshape") { store.showSettingsSheet = true }
        return items
    }

    /// Fuzzy match: every query character appears in order; earlier and contiguous matches rank higher.
    static func score(_ title: String, _ query: String) -> Int? {
        let t = Array(title.lowercased()), q = Array(query.lowercased().replacingOccurrences(of: " ", with: ""))
        guard !q.isEmpty else { return 0 }
        var ti = 0, score = 0, last = -2
        for c in q {
            while ti < t.count, t[ti] != c { ti += 1 }
            guard ti < t.count else { return nil }
            score += (ti == last + 1 ? 5 : 1) + (ti == 0 || t[ti - 1] == " " ? 3 : 0)
            last = ti
            ti += 1
        }
        return score - t.count / 10
    }

    private var filtered: [Item] {
        guard !query.isEmpty else { return allItems }
        return allItems.compactMap { item in Self.score(item.title, query).map { (item, $0) } }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
    }

    var body: some View {
        let items = filtered
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "command").foregroundColor(.secondary)
                TextField("Type a command…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .focused($focused)
                    .onSubmit { run(items) }
                    .onChange(of: query) { _ in selection = 0 }
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(items.prefix(80).enumerated()), id: \.element.id) { index, item in
                            HStack(spacing: 10) {
                                Image(systemName: item.symbol)
                                    .frame(width: 18)
                                    .foregroundColor(index == selection ? .white : .secondary)
                                Text(item.title)
                                    .font(.system(size: 13))
                                    .lineLimit(1)
                                Spacer()
                                Text(item.detail)
                                    .font(.system(size: 11))
                                    .foregroundColor(index == selection ? .white.opacity(0.85) : .secondary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .foregroundColor(index == selection ? .white : .primary)
                            .background(index == selection ? Color.accentColor : Color.clear)
                            .contentShape(Rectangle())
                            .id(index)
                            .onTapGesture { selection = index; run(items) }
                        }
                    }
                }
                .frame(height: min(340, CGFloat(max(1, min(items.count, 80))) * 33.5))
                .onChange(of: selection) { proxy.scrollTo($0) }
            }
        }
        .frame(width: 560)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .onAppear { focused = true }
        .background(KeyCatcher { key in
            switch key {
            case .down: selection = min(selection + 1, max(0, min(filtered.count, 80) - 1)); return true
            case .up: selection = max(0, selection - 1); return true
            case .escape: dismiss(); return true
            }
        })
    }

    private func run(_ items: [Item]) {
        guard items.indices.contains(selection) else { return }
        let action = items[selection].action
        dismiss()
        DispatchQueue.main.async {
            EditorTextView.focusInMainWindow()
            action()
        }
    }
}

/// Captures ↑ / ↓ / Esc while the palette's text field has focus.
struct KeyCatcher: NSViewRepresentable {
    enum Key { case up, down, escape }
    let handler: (Key) -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.handler = handler
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator] event in
            guard let handler = coordinator?.handler else { return event }
            switch event.keyCode {
            case 125: return handler(.down) ? nil : event
            case 126: return handler(.up) ? nil : event
            case 53: return handler(.escape) ? nil : event
            default: return event
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.handler = handler
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        var monitor: Any?
        var handler: ((Key) -> Bool)?
    }
}
#endif
