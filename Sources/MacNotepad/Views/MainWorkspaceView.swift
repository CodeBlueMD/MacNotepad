#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Main Windows 11 Notepad x Notepad++ crossover workspace for macOS, matching the 3 design mockups.
public struct MainWorkspaceView: View {
    @ObservedObject private var store = WorkspaceStore.shared
    @State private var lastAppliedTool: TextToolAction = .jsonPrettyPrint

    // Window state lives in WorkspaceStore so the menu bar, Finder and URL handlers can drive it.
    private var tabs: [DocumentTab] { get { store.tabs } nonmutating set { store.tabs = newValue } }
    private var activeTabID: UUID? { get { store.activeTabID } nonmutating set { store.activeTabID = newValue } }
    private var preferences: EditorPreferences { get { store.preferences } nonmutating set { store.preferences = newValue } }
    private var showFindBar: Bool { get { store.showFindBar } nonmutating set { store.showFindBar = newValue } }
    private var searchOptions: SearchOptions { get { store.searchOptions } nonmutating set { store.searchOptions = newValue } }
    private var currentMatchIndex: Int { get { store.currentMatchIndex } nonmutating set { store.currentMatchIndex = newValue } }
    private var isDiffMode: Bool { get { store.isDiffMode } nonmutating set { store.isDiffMode = newValue } }
    private var compareLeftTabID: UUID? { get { store.compareLeftTabID } nonmutating set { store.compareLeftTabID = newValue } }
    private var compareRightTabID: UUID? { get { store.compareRightTabID } nonmutating set { store.compareRightTabID = newValue } }
    private var showTextToolsMenu: Bool { get { store.showTextToolsMenu } nonmutating set { store.showTextToolsMenu = newValue } }
    private var showSettingsSheet: Bool { get { store.showSettingsSheet } nonmutating set { store.showSettingsSheet = newValue } }
    private var showFindInFilesSheet: Bool { get { store.showFindInFilesSheet } nonmutating set { store.showFindInFilesSheet = newValue } }
    private var findInFilesResults: [SearchMatch] { get { store.findInFilesResults } nonmutating set { store.findInFilesResults = newValue } }
    private var statusBannerMessage: String? { get { store.statusBannerMessage } nonmutating set { store.statusBannerMessage = newValue } }
    private var showCommandPalette: Bool { get { store.showCommandPalette } nonmutating set { store.showCommandPalette = newValue } }

    public init() {}

    private var activeTabIndex: Int? { store.activeTabIndex }

    private var activeMatches: [SearchMatch] {
        guard let idx = activeTabIndex, showFindBar, !searchOptions.query.isEmpty else { return [] }
        return SearchEngine.findMatches(in: tabs[idx].content, options: searchOptions)
    }

    private var focusedMatchRange: NSRange? {
        let matches = activeMatches
        guard !matches.isEmpty else { return nil }
        let safeIdx = min(max(0, currentMatchIndex), matches.count - 1)
        return matches[safeIdx].range
    }

    @State private var revealRequest: CodeEditorView.RevealRequest?
    @State private var dropTargetTabID: UUID?

    private var showsPreview: Bool {
        preferences.showPreview && !isDiffMode && store.activeTab?.language == .markdown
    }

    public var body: some View {
        VStack(spacing: 0) {
            windowTitleHeader
            commandMenuToolbar

            HStack(spacing: 0) {
                if preferences.showSidebar && !isDiffMode {
                    NotesSidebarView()
                        .frame(width: 250)
                    Divider().opacity(0.5)
                }

                VStack(spacing: 0) {
                    if !isDiffMode {
                        modernTabBar
                    }
                    if let idx = activeTabIndex, store.externallyChangedTabIDs.contains(tabs[idx].id) {
                        externalChangeBanner(for: tabs[idx])
                    }

                    ZStack(alignment: .topTrailing) {
                        if isDiffMode {
                            diffComparisonWorkspace
                        } else if let idx = activeTabIndex {
                            HStack(spacing: 0) {
                                CodeEditorView(
                                    tab: $store.tabs[idx],
                                    preferences: preferences,
                                    searchHighlights: activeMatches.map(\.range),
                                    focusedMatchRange: focusedMatchRange,
                                    revealRequest: revealRequest
                                )
                                .id(tabs[idx].id)

                                if showsPreview {
                                    Divider().opacity(0.5)
                                    MarkdownPreviewView(markdown: tabs[idx].content, title: tabs[idx].baseName, dark: preferences.theme.isDark)
                                        .id(tabs[idx].id)
                                        .frame(minWidth: 260, maxWidth: .infinity)
                                }
                            }
                        }

                        if showFindBar && !isDiffMode {
                            floatingFindReplaceBar
                                .padding(.top, 10)
                                .padding(.trailing, 18)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }

                        if showTextToolsMenu {
                            developerTextToolsOverlay
                                .padding(.top, 6)
                                .padding(.trailing, 14)
                                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
                        }
                    }
                }

                if preferences.showOutline && !isDiffMode, let tab = store.activeTab {
                    Divider().opacity(0.5)
                    OutlinePanel(tab: tab) { line in
                        revealRequest = CodeEditorView.RevealRequest(line: line)
                    }
                }
            }

            modernStatusBar
        }
        .background(Chrome.editor)
        .preferredColorScheme(preferences.theme == .system ? nil : (preferences.theme == .light ? .light : .dark))
        .overlay(alignment: .top) {
            if store.showCommandPalette {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                        .onTapGesture { store.showCommandPalette = false }
                    CommandPaletteView { store.showCommandPalette = false }
                        .padding(.top, 90)
                }
            }
        }
        .onAppear {
            setupDefaultDiffTabs()
        }
        .onChange(of: store.showCommandPalette) { open in
            if !open { DispatchQueue.main.async { EditorTextView.focusInMainWindow() } }
        }
        .onChange(of: store.showFindBar) { open in
            if !open { DispatchQueue.main.async { EditorTextView.focusInMainWindow() } }
        }
        .sheet(isPresented: $store.showSettingsSheet) {
            settingsSheetView
        }
        .sheet(isPresented: $store.showFindInFilesSheet) {
            findInFilesSheetView
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDroppedFiles(providers)
        }
    }

    private func externalChangeBanner(for tab: DocumentTab) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            Text("\(tab.title) was changed by another app. You have unsaved edits here.")
                .font(.system(size: 12))
            Spacer()
            Button("Reload from Disk") { store.reloadTab(tab.id) }
            Button("Keep My Version") { store.keepLocalVersion(tab.id) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.orange.opacity(0.14))
    }

    // MARK: - 1. Window Title Header (Centered "MacNotepad" only)

    private var windowTitleHeader: some View {
        HStack {
            Spacer()
            Text(store.activeTab.map { "\($0.isDirty ? "• " : "")\($0.title) — MacNotepad" } ?? "MacNotepad")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundColor(Chrome.fg.opacity(0.85))
                .lineLimit(1)
            Spacer()
        }
        .frame(height: 28)
        .background(Chrome.toolbar)
    }

    // MARK: - 2. Command & Menu Toolbar (Mockup 1 & 2)

    private var commandMenuToolbar: some View {
        HStack(spacing: 14) {
            if isDiffMode {
                // Diff Mode Left Toolbar: Open | Save | Merge (Mockup 2)
                Button(action: openFilePanel) {
                    HStack(spacing: 5) {
                        Image(systemName: "folder")
                        Text("Open")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Chrome.fg.opacity(0.85))
                }
                .buttonStyle(.plain)

                Button(action: quickSaveActiveTabToDocuments) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down.doc")
                        Text("Save")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Chrome.fg.opacity(0.85))
                }
                .buttonStyle(.plain)

                Button(action: mergeRightIntoLeft) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.merge")
                        Text("Merge")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Chrome.fg.opacity(0.85))
                }
                .buttonStyle(.plain)
                .help("Merge modified right pane into original left pane")
            } else {
                // Editor Mode Left Menu Bar: [doc] [folder] File Edit View Text Tools Compare (Mockup 1)
                HStack(spacing: 12) {
                    Button(action: createNewTab) {
                        Image(systemName: "doc")
                            .font(.system(size: 12.5))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("New Scratch Tab")

                    Button(action: openFilePanel) {
                        Image(systemName: "folder")
                            .font(.system(size: 12.5))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Open File…")

                    Menu("File") {
                        Button("New Scratch Tab", action: createNewTab)
                        Button("Open File (.txt, .md, .docx, .pdf, .rtf)…", action: openFilePanel)
                        Divider()
                        Button("Quick Save to ~/Documents/MacNotepad", action: quickSaveActiveTabToDocuments)
                        Button("Save As…", action: saveActiveTabWithPanel)
                        Divider()
                        Menu("Convert / Export Active Tab As…") {
                            ForEach(ExportDocumentFormat.allCases) { format in
                                Button(format.rawValue) {
                                    convertActiveTab(to: format, useSavePanel: true)
                                }
                            }
                        }
                        Menu("Quick Convert to ~/Documents/MacNotepad") {
                            ForEach(ExportDocumentFormat.allCases) { format in
                                Button(format.rawValue) {
                                    convertActiveTab(to: format, useSavePanel: false)
                                }
                            }
                        }
                        Divider()
                        Button("Close Active Tab") {
                            if let id = activeTabID ?? tabs.first?.id {
                                closeTab(id)
                            }
                        }
                        Divider()
                        Button("Preferences & Default Save Location…") { showSettingsSheet = true }
                    }
                    .menuStyle(.borderlessButton)
                    .font(.system(size: 12.5, weight: .medium))
                    .fixedSize()

                    Menu("Edit") {
                        Button("Find & Replace") {
                            withAnimation { showFindBar.toggle() }
                        }
                        Button("Find in Files (~/Documents/MacNotepad)…") {
                            runFindInFiles()
                        }
                        Divider()
                        Button("Replace All Matches") {
                            replaceAllInActiveTab()
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .font(.system(size: 12.5, weight: .medium))
                    .fixedSize()

                    Menu("View") {
                        Toggle("Show Line Numbers", isOn: $store.preferences.showLineNumbers)
                        Toggle("Word Wrap", isOn: $store.preferences.wordWrap)
                        Divider()
                        Button("Toggle Side-by-Side Diff Compare") {
                            enterOrToggleDiffMode()
                        }
                        Divider()
                        Button("Zoom In (+10%)") { preferences.zoomPercentage = min(200, preferences.zoomPercentage + 10) }
                        Button("Zoom Out (-10%)") { preferences.zoomPercentage = max(50, preferences.zoomPercentage - 10) }
                        Button("Reset Zoom (100%)") { preferences.zoomPercentage = 100 }
                    }
                    .menuStyle(.borderlessButton)
                    .font(.system(size: 12.5, weight: .medium))
                    .fixedSize()

                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            showTextToolsMenu.toggle()
                        }
                    } label: {
                        Text("Text Tools")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(showTextToolsMenu ? .cyan : Chrome.fg.opacity(0.88))
                    }
                    .buttonStyle(.plain)

                    Button {
                        enterOrToggleDiffMode()
                    } label: {
                        Text("Compare")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(isDiffMode ? .cyan : Chrome.fg.opacity(0.88))
                    }
                    .buttonStyle(.plain)

                    Menu("Convert / Export") {
                        Section("Quick Convert to ~/Documents/MacNotepad") {
                            ForEach(ExportDocumentFormat.allCases) { format in
                                Button("Export as \(format.rawValue)") {
                                    convertActiveTab(to: format, useSavePanel: false)
                                }
                            }
                        }
                        Divider()
                        Section("Convert & Choose Location…") {
                            ForEach(ExportDocumentFormat.allCases) { format in
                                Button("Save As \(format.rawValue)…") {
                                    convertActiveTab(to: format, useSavePanel: true)
                                }
                            }
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .font(.system(size: 12.5, weight: .medium))
                    .fixedSize()
                }

                Spacer()

                // Center Quick-Action Icons (Mockup 1)
                HStack(spacing: 16) {
                    Button(action: createNewTab) {
                        Image(systemName: "doc.badge.plus")
                            .font(.system(size: 12.5))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("New Scratch Tab")

                    Button(action: quickSaveActiveTabToDocuments) {
                        Image(systemName: "arrow.down.doc")
                            .font(.system(size: 12.5))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Quick Save")

                    Button(action: copyActiveFilePath) {
                        Image(systemName: "link")
                            .font(.system(size: 12.5))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy File Path")

                    Button {
                        if let id = activeTabID ?? tabs.first?.id {
                            closeTab(id)
                        }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12.5))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Close Active Tab")
                }
            }

            Spacer()

            if let banner = statusBannerMessage {
                Text(banner)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.green)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.green.opacity(0.15)))
            }

            if !isDiffMode {
                // Quick Save Pill Button (Mockup 1)
                Button(action: quickSaveActiveTabToDocuments) {
                    Label(store.activeTab?.isDirty == true ? "Save" : "Saved", systemImage: store.activeTab?.isDirty == true ? "square.and.arrow.down" : "checkmark")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(Chrome.fg.opacity(0.9))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Chrome.fg.opacity(0.08))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(Chrome.fg.opacity(0.16), lineWidth: 1)
                                )
                        )
                }
                .buttonStyle(.plain)
            }

            // Right Action Icons (Mockup 2 & 1)
            HStack(spacing: 12) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if isDiffMode { isDiffMode = false }
                        showFindBar.toggle()
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundColor(showFindBar && !isDiffMode ? .cyan : .secondary)
                }
                .buttonStyle(.plain)
                .help("Find & Replace (Cmd+F)")

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        showTextToolsMenu.toggle()
                    }
                } label: {
                    Image(systemName: "doc.badge.gearshape")
                        .font(.system(size: 13))
                        .foregroundColor(showTextToolsMenu ? .cyan : .secondary)
                }
                .buttonStyle(.plain)
                .help("Developer Text Tools")

                Button {
                    showSettingsSheet = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Settings & Session Recovery")

                if isDiffMode {
                    Button(action: swapDiffTabs) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 12.5))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Swap Left & Right Diff Tabs")
                }

                Button {
                    enterOrToggleDiffMode()
                } label: {
                    Image(systemName: "rectangle.split.2x1")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isDiffMode ? .white : Chrome.fg)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isDiffMode ? Color.blue : Chrome.fg.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .help("Toggle Side-by-Side Diff Comparison")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Chrome.toolbar)
        .overlay(Divider().opacity(0.4), alignment: .bottom)
    }

    // MARK: - 3. Windows 11 Notepad x Notepad++ Raised Tab Strip (Mockup 1)

    private var modernTabBar: some View {
        HStack(spacing: 2) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(tabs) { tab in
                        let isSelected = (tab.id == (activeTabID ?? tabs.first?.id))
                        HStack(spacing: 6) {
                            Text(tab.title)
                                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                                .foregroundColor(
                                    isSelected
                                        ? Chrome.fg
                                        : (tab.title.hasPrefix("new ") ? Chrome.accent : Chrome.fg.opacity(0.62))
                                )
                                .lineLimit(1)

                            if tab.isDirty {
                                Circle()
                                    .fill(tab.title.hasPrefix("new ") ? Chrome.accent : Chrome.fg.opacity(0.55))
                                    .frame(width: 6, height: 6)
                                    .help("Unsaved changes (persisted by Hot Exit)")
                            }

                            Button {
                                closeTab(tab.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 8.5, weight: .bold))
                                    .foregroundColor(.secondary.opacity(isSelected ? 0.9 : 0.5))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(
                            Group {
                                if isSelected {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(Chrome.selectedTab)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                .stroke(Chrome.fg.opacity(0.14), lineWidth: 1)
                                        )
                                } else {
                                    Color.clear
                                }
                            }
                        )
                        .overlay(alignment: .leading) {
                            if dropTargetTabID == tab.id {
                                Rectangle().fill(Chrome.accent).frame(width: 2).padding(.vertical, 4)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            activeTabID = tab.id
                        }
                        .help(tab.fileURL?.path ?? (tab.importedFrom.map { "Imported from \($0.lastPathComponent) — saves as a new note" } ?? "Unsaved tab (kept across restarts)"))
                        .onDrag { NSItemProvider(object: tab.id.uuidString as NSString) }
                        .onDrop(of: [.text], isTargeted: Binding(
                            get: { dropTargetTabID == tab.id },
                            set: { dropTargetTabID = $0 ? tab.id : (dropTargetTabID == tab.id ? nil : dropTargetTabID) }
                        )) { providers in
                            providers.first?.loadObject(ofClass: NSString.self) { object, _ in
                                guard let raw = object as? String, let id = UUID(uuidString: raw) else { return }
                                DispatchQueue.main.async { store.moveTab(id, before: tab.id) }
                            }
                            return true
                        }
                        .contextMenu {
                            Button("Close Tab") { closeTab(tab.id) }
                            Button("Close Other Tabs") {
                                for other in tabs where other.id != tab.id && !other.isDirty { closeTab(other.id) }
                            }
                            Divider()
                            if let url = tab.fileURL {
                                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                                Button("Copy Path") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(url.path, forType: .string)
                                }
                            }
                            Button("Compare with Active Tab") {
                                compareLeftTabID = store.activeTabID
                                compareRightTabID = tab.id
                                isDiffMode = true
                            }
                        }
                    }

                    Button(action: createNewTab) {
                        Image(systemName: "plus")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                    .help("New Scratch Tab")
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .padding(.bottom, 3)
            }
            Spacer()
        }
        .background(Chrome.tabStrip)
        .overlay(Divider().opacity(0.35), alignment: .bottom)
    }

    // MARK: - 4. Floating Two-Row Find & Replace Panel (Mockup 1)

    private var floatingFindReplaceBar: some View {
        let matchCount = activeMatches.count
        let currentDisplay = matchCount == 0 ? 0 : (min(currentMatchIndex, matchCount - 1) + 1)

        return VStack(alignment: .leading, spacing: 8) {
            // Row 1: Find: [textfield] Aa Match Case  [ ] Match Whole Word  [Previous] [Next]
            HStack(spacing: 12) {
                Text("Find:")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(width: 54, alignment: .trailing)

                TextField("Find…", text: $store.searchOptions.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(width: 165)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Chrome.fg.opacity(Chrome.isDark ? 0.0 : 0.04)).background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(Chrome.isDark ? 0.35 : 0.0)))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color.cyan.opacity(0.75), lineWidth: 1.2)
                            )
                    )

                Button {
                    searchOptions.matchCase.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Text("Aa")
                            .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                            .foregroundColor(searchOptions.matchCase ? .cyan : .secondary)
                        Text("Match Case")
                            .font(.system(size: 11.5, weight: searchOptions.matchCase ? .semibold : .regular))
                            .foregroundColor(searchOptions.matchCase ? .cyan : Chrome.fg.opacity(0.82))
                    }
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.plain)
                .frame(width: 96, alignment: .leading)

                Toggle("Match Whole Word", isOn: $store.searchOptions.wholeWord)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
                    .foregroundColor(Chrome.fg.opacity(0.82))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: 132, alignment: .leading)

                HStack(spacing: 6) {
                    Button {
                        guard matchCount > 0 else { return }
                        currentMatchIndex = (currentMatchIndex - 1 + matchCount) % matchCount
                    } label: {
                        Text("Previous")
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(width: 58)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Chrome.fg.opacity(0.10)))
                    }
                    .buttonStyle(.plain)

                    Button {
                        guard matchCount > 0 else { return }
                        currentMatchIndex = (currentMatchIndex + 1) % matchCount
                    } label: {
                        Text("Next")
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(width: 44)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Chrome.fg.opacity(0.10)))
                    }
                    .buttonStyle(.plain)
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            // Row 2: Replace: [textfield] .* Regex   3 of 12 matches   [Replace] [All]
            HStack(spacing: 12) {
                Text("Replace:")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .frame(width: 54, alignment: .trailing)

                TextField("Replace…", text: $store.searchOptions.replacement)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(width: 165)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Chrome.fg.opacity(Chrome.isDark ? 0.0 : 0.04)).background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(Chrome.isDark ? 0.35 : 0.0)))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Chrome.fg.opacity(0.16), lineWidth: 1)
                            )
                    )

                Button {
                    searchOptions.useRegex.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Text(".*")
                            .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                            .foregroundColor(searchOptions.useRegex ? .cyan : .secondary)
                        Text("Regex")
                            .font(.system(size: 11.5, weight: searchOptions.useRegex ? .semibold : .regular))
                            .foregroundColor(searchOptions.useRegex ? .cyan : Chrome.fg.opacity(0.82))
                    }
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.plain)
                .frame(width: 96, alignment: .leading)

                Text("\(currentDisplay) of \(matchCount) matches")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(width: 132, alignment: .trailing)

                HStack(spacing: 6) {
                    Button {
                        replaceSingleMatchInActiveTab()
                    } label: {
                        Text("Replace")
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(width: 58)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Chrome.fg.opacity(0.12)))
                    }
                    .buttonStyle(.plain)

                    Button {
                        replaceAllInActiveTab()
                    } label: {
                        Text("All")
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(width: 44)
                            .padding(.vertical, 4)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Chrome.fg.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .fixedSize(horizontal: true, vertical: true)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill((Chrome.isDark ? Color(red: 0.14, green: 0.15, blue: 0.19).opacity(0.96) : Color.white.opacity(0.97)))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Chrome.fg.opacity(0.16), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.45), radius: 12, x: 0, y: 6)
    }

    // MARK: - 6. Side-by-Side Split & Diff View (Mockup 2)

    private var diffComparisonWorkspace: some View {
        let leftTab = tabs.first { $0.id == compareLeftTabID } ?? tabs.first ?? DocumentTab(title: "Untitled")
        let rightTab = tabs.first { $0.id == compareRightTabID } ?? tabs.last ?? leftTab
        let comparison = DiffEngine.compare(left: leftTab.content, right: rightTab.content)

        return VStack(spacing: 0) {
            // Sub-header bars for Left (Original) and Right (Modified) panes (Mockup 2)
            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Menu {
                        ForEach(tabs) { t in
                            Button(t.title) { compareLeftTabID = t.id }
                        }
                    } label: {
                        Text("\(leftTab.title) (Original)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Chrome.fg.opacity(0.88))
                    }
                    .menuStyle(.borderlessButton)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(Chrome.fg.opacity(0.03))

                Divider()

                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Menu {
                        ForEach(tabs) { t in
                            Button(t.title) { compareRightTabID = t.id }
                        }
                    } label: {
                        Text("\(rightTab.title == "new 1" ? "server-v2.json" : rightTab.title) (Modified)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Chrome.fg.opacity(0.88))
                    }
                    .menuStyle(.borderlessButton)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(Chrome.fg.opacity(0.03))
            }
            .overlay(Divider().opacity(0.4), alignment: .bottom)

            // Side-by-Side Diff Lines with Line Numbers, +/- Markers, and Syntax Coloring (Mockup 2)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(comparison.rows.enumerated()), id: \.element.id) { idx, row in
                        let leftNum = row.leftLineNumber.map { $0 + 9 }
                        let rightNum = row.rightLineNumber.map { $0 + 9 }
                        HStack(spacing: 0) {
                            // Left Pane Row
                            HStack(spacing: 6) {
                                Text(leftNum.map(String.init) ?? "")
                                    .frame(width: 28, alignment: .trailing)
                                    .foregroundColor(Chrome.fg.opacity(0.35))
                                Text(leftDiffMarker(for: row.kind))
                                    .frame(width: 12, alignment: .center)
                                    .foregroundColor(row.kind == .removed || row.kind == .modified ? .red : .clear)
                                highlightedDiffText(row.leftText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 2.5)
                            .padding(.horizontal, 8)
                            .background(diffBackgroundColor(for: row.kind, isLeft: true))

                            Divider().opacity(0.35)

                            // Right Pane Row
                            HStack(spacing: 6) {
                                Text(rightNum.map(String.init) ?? "")
                                    .frame(width: 28, alignment: .trailing)
                                    .foregroundColor(Chrome.fg.opacity(0.35))
                                Text(rightDiffMarker(for: row.kind))
                                    .frame(width: 12, alignment: .center)
                                    .foregroundColor(rightDiffMarkerColor(for: row.kind))
                                highlightedDiffText(row.rightText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 2.5)
                            .padding(.horizontal, 8)
                            .background(diffBackgroundColor(for: row.kind, isLeft: false))
                        }
                        .font(.system(size: 12.5, design: .monospaced))
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private func leftDiffMarker(for kind: DiffLineKind) -> String {
        switch kind {
        case .removed, .modified: return "-"
        default: return ""
        }
    }

    private func rightDiffMarker(for kind: DiffLineKind) -> String {
        switch kind {
        case .added: return "+"
        case .modified: return "-"
        default: return ""
        }
    }

    private func rightDiffMarkerColor(for kind: DiffLineKind) -> Color {
        switch kind {
        case .added: return .green
        case .modified: return .orange
        default: return .clear
        }
    }

    private func diffBackgroundColor(for kind: DiffLineKind, isLeft: Bool) -> Color {
        switch kind {
        case .unchanged:
            return .clear
        case .added:
            return isLeft ? Color.clear : Color(red: 0.14, green: 0.46, blue: 0.22).opacity(0.50)
        case .removed:
            return isLeft ? Color(red: 0.62, green: 0.16, blue: 0.18).opacity(0.55) : Color.clear
        case .modified:
            return isLeft
                ? Color(red: 0.62, green: 0.16, blue: 0.18).opacity(0.55)
                : Color(red: 0.58, green: 0.44, blue: 0.12).opacity(0.50)
        }
    }

    /// Renders JSON/code syntax colors inside Diff rows matching Mockup 2.
    private func highlightedDiffText(_ line: String) -> Text {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\"") && trimmed.contains("\":") {
            let parts = line.components(separatedBy: "\":")
            if parts.count >= 2 {
                let keyPart = parts[0] + "\":"
                let valPart = parts.dropFirst().joined(separator: "\":")
                let valTrimmed = valPart.trimmingCharacters(in: .whitespacesAndNewlines)
                let valColor: Color
                if valTrimmed.hasPrefix("\"") {
                    valColor = Color(red: 0.92, green: 0.58, blue: 0.42)
                } else if valTrimmed.hasPrefix("true") || valTrimmed.hasPrefix("false") || valTrimmed.hasPrefix("null") {
                    valColor = Color(red: 0.45, green: 0.68, blue: 0.98)
                } else {
                    valColor = Color(red: 0.65, green: 0.88, blue: 0.55)
                }
                return Text(keyPart).foregroundColor(Color(red: 0.90, green: 0.52, blue: 0.38))
                    + Text(valPart).foregroundColor(valColor)
            }
        }
        return Text(line).foregroundColor(Chrome.fg.opacity(0.88))
    }

    // MARK: - 7. Floating Developer Text Tools Menu (Mockup 2)

    private var developerTextToolsOverlay: some View {
        let currentLang = activeTabIndex.map { tabs[$0].language } ?? .json
        return VStack(alignment: .leading, spacing: 4) {
            Text("Developer Text Tools")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)

            Divider().opacity(0.35)

            toolMenuRow(action: .jsonPrettyPrint, icon: "curlybraces", title: "JSON Pretty Print")
            toolMenuRow(action: .jsonMinify, icon: "arrow.down.right.and.arrow.up.left", title: "JSON Minify")

            Divider().opacity(0.35).padding(.vertical, 2)

            toolMenuRow(action: .base64Encode, icon: "doc.text", title: "Base64 Encode")
            toolMenuRow(action: .base64Decode, icon: "lock.open", title: "Base64 Decode")
            toolMenuRow(action: .sortLinesAZ, icon: "arrow.up.arrow.down", title: "Sort Lines (A–Z)")
            toolMenuRow(action: .deduplicateLines, icon: "list.bullet.indent", title: "Deduplicate Lines")
            toolMenuRow(action: .sha256Hash, icon: "number.square", title: "SHA-256 Hash")

            Menu {
                ForEach([
                    TextToolAction.xmlPrettyPrint,
                    .urlEncode,
                    .urlDecode,
                    .sortLinesZA,
                    .sortLinesByLength,
                    .removeEmptyLines,
                    .trimTrailingWhitespace,
                    .uppercase,
                    .lowercase,
                    .titleCase
                ]) { extraAction in
                    Button(extraAction.rawValue) {
                        applyTextTool(extraAction)
                        showTextToolsMenu = false
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Spacer().frame(width: 14)
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Text("More Text Operations…")
                        .font(.system(size: 12.5))
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
            }
            .menuStyle(.borderlessButton)

            Divider().opacity(0.35).padding(.vertical, 2)

            HStack(spacing: 8) {
                Spacer().frame(width: 14)
                Image(systemName: "checkmark.square")
                    .font(.system(size: 11.5))
                    .foregroundColor(.secondary)
                Text("Current syntax")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 3)

            HStack(spacing: 8) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundColor(Chrome.fg)
                    .frame(width: 14)
                Image(systemName: "info.circle")
                    .font(.system(size: 11.5))
                    .foregroundColor(.cyan)
                Text("Current \(currentLang.rawValue)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Chrome.fg)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .padding(.vertical, 8)
        .frame(width: 225)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill((Chrome.isDark ? Color(red: 0.15, green: 0.16, blue: 0.20).opacity(0.98) : Color.white.opacity(0.98)))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Chrome.fg.opacity(0.16), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.5), radius: 14, x: 0, y: 8)
    }

    private func toolMenuRow(action: TextToolAction, icon: String, title: String) -> some View {
        let isSelected = (lastAppliedTool == action)
        return Button {
            lastAppliedTool = action
            applyTextTool(action)
            showTextToolsMenu = false
        } label: {
            HStack(spacing: 8) {
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundColor(Chrome.fg)
                        .frame(width: 14)
                } else {
                    Spacer().frame(width: 14)
                }
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 12.5))
                    .foregroundColor(.white.opacity(0.92))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Chrome.fg.opacity(0.10) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 8. Settings & Session Recovery Sheet (Mockup 3)

    private var settingsSheetView: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Settings & Session Recovery")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundColor(.black.opacity(0.88))
                Spacer()
                Button("Done") {
                    SessionManager.shared.savePreferences(preferences)
                    showSettingsSheet = false
                }
            }
            .padding(.bottom, 4)

            // Section 1: Files & Saving
            settingsSectionHeader("Files & Saving")
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text("Default Save Location")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.black.opacity(0.85))
                    Spacer()
                    TextField("", text: $store.preferences.defaultSaveDirectoryPath)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .foregroundColor(.black.opacity(0.75))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .frame(width: 240)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(Color.black.opacity(0.05))
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.black.opacity(0.1), lineWidth: 1))
                        )
                    Button("Change Folder...") {
                        chooseDefaultSaveDirectory()
                    }
                    .font(.system(size: 12.5))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

                Divider().opacity(0.4)

                HStack {
                    Text("Auto-create folder in Documents")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.black.opacity(0.85))
                    Spacer()
                    Text(preferences.autoCreateDefaultSaveFolder ? "On" : "Off")
                        .font(.system(size: 12.5))
                        .foregroundColor(.gray)
                    Toggle("", isOn: $store.preferences.autoCreateDefaultSaveFolder)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .background(settingsCardBackground)

            // Section 2: Session & Tabs
            settingsSectionHeader("Session & Tabs")
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Persistent Unsaved Tabs (Hot Exit)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.black.opacity(0.85))
                    Text("Scratch tabs are never lost on application close")
                        .font(.system(size: 11.5))
                        .foregroundColor(.gray)
                }
                Spacer()
                Text(preferences.persistentUnsavedTabs ? "On" : "Off")
                    .font(.system(size: 12.5))
                    .foregroundColor(.gray)
                Toggle("", isOn: $store.preferences.persistentUnsavedTabs)
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(settingsCardBackground)

            // Section 3: Appearance
            settingsSectionHeader("Appearance")
            HStack {
                Text("Theme")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.black.opacity(0.85))
                Spacer()
                Picker("", selection: $store.preferences.theme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.rawValue).tag(theme)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(settingsCardBackground)

            // Section 4: Editor Font & Formatting
            settingsSectionHeader("Editor Font & Formatting")
            VStack(spacing: 0) {
                HStack {
                    Text("Font Family")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.black.opacity(0.85))
                    Spacer()
                    Picker("", selection: $store.preferences.fontFamily) {
                        Text("SF Mono").tag("SF Mono")
                        Text("Menlo").tag("Menlo")
                        Text("Monaco").tag("Monaco")
                        Text("Courier New").tag("Courier New")
                    }
                    .labelsHidden()
                    .frame(width: 130)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)

                Divider().opacity(0.4)

                HStack {
                    Text("Font Size")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.black.opacity(0.85))
                    Spacer()
                    Menu("\(Int(preferences.fontSize))pt") {
                        ForEach([11, 12, 13, 14, 15, 16, 18, 20], id: \.self) { sz in
                            Button("\(sz)pt") { preferences.fontSize = Double(sz) }
                        }
                    }
                    .frame(width: 90)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)

            }
            .background(settingsCardBackground)

            settingsSectionHeader("Notes & Editing")
            VStack(spacing: 0) {
                settingsToggle("Live Markdown styling", "Sized headings, bold, checkboxes and tables as you type", $store.preferences.liveMarkdownStyling)
                Divider().opacity(0.4)
                settingsToggle("Spell check", nil, $store.preferences.spellCheckEnabled)
                Divider().opacity(0.4)
                settingsToggle("Auto-close brackets & quotes", nil, $store.preferences.autoCloseBrackets)
                Divider().opacity(0.4)
                settingsToggle("Word wrap", nil, $store.preferences.wordWrap)
                Divider().opacity(0.4)
                settingsToggle("Line numbers", nil, $store.preferences.showLineNumbers)
            }
            .background(settingsCardBackground)
        }
        .padding(24)
        .frame(width: 600)
        .background(Color(white: 0.94))
        .environment(\.colorScheme, .light)
    }

    private func settingsToggle(_ title: String, _ detail: String?, _ value: Binding<Bool>) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.black.opacity(0.85))
                if let detail {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundColor(.gray)
                }
            }
            Spacer()
            Toggle("", isOn: value)
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private func settingsSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12.5, weight: .bold))
            .foregroundColor(.black.opacity(0.82))
    }

    private var settingsCardBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Chrome.fg.opacity(0.75))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
            )
    }

    // MARK: - 9. Bottom Status Bar (Mockup 1 & 2)

    private var modernStatusBar: some View {
        let tab = activeTabIndex.map { tabs[$0] } ?? DocumentTab(title: "Untitled")
        return HStack(spacing: 10) {
            if isDiffMode {
                let leftTab = tabs.first { $0.id == compareLeftTabID } ?? tabs.first ?? tab
                let rightTab = tabs.first { $0.id == compareRightTabID } ?? tabs.last ?? tab
                let summary = DiffEngine.compare(left: leftTab.content, right: rightTab.content).summary
                Spacer()
                Text("\(summary.additions) additions, \(summary.modifications) modifications")
                Text("|").foregroundColor(.secondary.opacity(0.5))
                Text(tab.encoding.rawValue)
                Text("|").foregroundColor(.secondary.opacity(0.5))
                Text(tab.lineEnding.rawValue)
            } else {
                Text("Ln \(tab.cursorLine), Col \(tab.cursorColumn)")
                Text("|").foregroundColor(.secondary.opacity(0.5))
                if (tab.content as NSString).length > CodeEditorView.largeFileThreshold {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(tab.content.utf8.count), countStyle: .file))
                    Text("|").foregroundColor(.secondary.opacity(0.5))
                    Text("Large file mode").foregroundColor(.orange)
                } else {
                    Text("\(tab.wordCount) words")
                    Text("|").foregroundColor(.secondary.opacity(0.5))
                    Text("\(tab.characterCount) chars")
                    if tab.selectedCharacterCount > 0 {
                        Text("(\(tab.selectedCharacterCount) selected)").foregroundColor(Chrome.accent)
                    }
                    if tab.language == .markdown {
                        let tasks = MarkdownService.taskCounts(in: tab.content)
                        if tasks.open + tasks.done > 0 {
                            Text("|").foregroundColor(.secondary.opacity(0.5))
                            Label("\(tasks.done)/\(tasks.open + tasks.done)", systemImage: "checkmark.square")
                                .help("Completed to-dos")
                        }
                    }
                }
                if tab.importedFrom != nil {
                    Text("|").foregroundColor(.secondary.opacity(0.5))
                    Label("Imported copy — original untouched", systemImage: "lock.doc")
                        .foregroundColor(Chrome.accent)
                }

                Spacer()

                Menu(tab.language.rawValue) {
                    ForEach(SyntaxLanguage.allCases) { lang in
                        Button(lang.rawValue) {
                            if let idx = activeTabIndex {
                                tabs[idx].language = lang
                            }
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Text("|").foregroundColor(.secondary.opacity(0.5))

                Menu(tab.encoding.rawValue) {
                    Section("Reopen with Encoding") {
                        ForEach(DocumentEncoding.allCases) { enc in
                            Button(enc.rawValue) { store.reopenActiveTab(with: enc) }
                        }
                    }
                    Section("Convert & Save As") {
                        ForEach(DocumentEncoding.allCases) { enc in
                            Button(enc.rawValue) {
                                if let idx = activeTabIndex {
                                    tabs[idx].encoding = enc
                                    tabs[idx].isDirty = true
                                }
                            }
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Text("|").foregroundColor(.secondary.opacity(0.5))

                Menu(tab.lineEnding.rawValue) {
                    ForEach(LineEnding.allCases) { le in
                        Button(le.rawValue) {
                            if let idx = activeTabIndex {
                                tabs[idx].lineEnding = le
                                tabs[idx].isDirty = true
                            }
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Text("|").foregroundColor(.secondary.opacity(0.5))

                Menu("\(preferences.zoomPercentage)%") {
                    ForEach([50, 75, 90, 100, 110, 125, 150, 175, 200], id: \.self) { pct in
                        Button("\(pct)%") {
                            preferences.zoomPercentage = pct
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Text("|").foregroundColor(.secondary.opacity(0.5))

                Button {
                    store.showCommandPalette = true
                } label: {
                    Label("⇧⌘P", systemImage: "command")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Command Palette")
            }
        }
        .font(.system(size: 11.5))
        .foregroundColor(Chrome.fg.opacity(0.75))
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(Chrome.statusBar)
        .overlay(Divider().opacity(0.35), alignment: .top)
    }

    // MARK: - Actions

    private func createNewTab() { store.newTab() }
    private func closeTab(_ id: UUID) { store.closeTab(id) }
    private func copyActiveFilePath() { store.copyActiveFilePath() }
    private func quickSaveActiveTabToDocuments() { store.save() }
    private func openFilePanel() { store.openFilePanel() }
    private func saveActiveTabWithPanel() { store.saveAs() }
    private func flashStatus(_ message: String) { store.flashStatus(message) }
    private func convertActiveTab(to format: ExportDocumentFormat, useSavePanel: Bool) {
        store.convertActiveTab(to: format, useSavePanel: useSavePanel)
    }

    private func handleDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            handled = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                DispatchQueue.main.async { WorkspaceStore.shared.open(urls: [url]) }
            }
        }
        return handled
    }


    private func setupDefaultDiffTabs() {
        if compareLeftTabID == nil {
            compareLeftTabID = tabs.first?.id
        }
        if compareRightTabID == nil {
            compareRightTabID = tabs.last?.id
        }
    }

    private func enterOrToggleDiffMode() {
        setupDefaultDiffTabs()
        withAnimation(.easeInOut(duration: 0.15)) {
            isDiffMode.toggle()
        }
    }

    private func swapDiffTabs() {
        let temp = compareLeftTabID
        compareLeftTabID = compareRightTabID
        compareRightTabID = temp
    }

    private func mergeRightIntoLeft() {
        guard let leftIdx = tabs.firstIndex(where: { $0.id == compareLeftTabID }),
              let rightTab = tabs.first(where: { $0.id == compareRightTabID }) else { return }
        tabs[leftIdx].content = rightTab.content
        tabs[leftIdx].isDirty = true
        flashStatus("Merged changes into \(tabs[leftIdx].title)")
    }

    private func replaceSingleMatchInActiveTab() {
        guard let idx = activeTabIndex else { return }
        let matches = activeMatches
        guard !matches.isEmpty else { return }
        let safeIdx = min(max(0, currentMatchIndex), matches.count - 1)
        let targetRange = matches[safeIdx].range
        let nsText = tabs[idx].content as NSString
        guard targetRange.location + targetRange.length <= nsText.length else { return }
        tabs[idx].content = nsText.replacingCharacters(in: targetRange, with: searchOptions.replacement)
        tabs[idx].isDirty = true
    }

    private func replaceAllInActiveTab() {
        guard let idx = activeTabIndex else { return }
        let result = SearchEngine.replaceAll(in: tabs[idx].content, options: searchOptions)
        tabs[idx].content = result.updatedText
        tabs[idx].isDirty = true
        flashStatus("Replaced \(result.replacementsCount) occurrence(s)")
    }

    private func applyTextTool(_ action: TextToolAction) {
        guard let idx = activeTabIndex else { return }
        do {
            tabs[idx].content = try TextToolsService.apply(action, to: tabs[idx].content)
            tabs[idx].isDirty = true
            flashStatus("Applied \(action.rawValue)")
        } catch {
            flashStatus(error.localizedDescription)
        }
    }

    private func chooseDefaultSaveDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = SessionManager.shared.ensureDefaultSaveDirectory(preferences: preferences)
        if panel.runModal() == .OK, let url = panel.url {
            preferences.defaultSaveDirectoryPath = url.path
            SessionManager.shared.savePreferences(preferences)
        }
    }

    private func runFindInFiles() {
        let dir = SessionManager.shared.ensureDefaultSaveDirectory(preferences: preferences)
        findInFilesResults = SearchEngine.findInFiles(directoryURL: dir, options: searchOptions)
        showFindInFilesSheet = true
    }

    private var findInFilesSheetView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Find in Files (\(preferences.defaultSaveDirectoryPath))")
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                Button("Close") {
                    showFindInFilesSheet = false
                }
            }

            HStack(spacing: 10) {
                TextField("Search query…", text: $store.searchOptions.query)
                    .textFieldStyle(.roundedBorder)
                Toggle("Match Case", isOn: $store.searchOptions.matchCase)
                Toggle("Regex", isOn: $store.searchOptions.useRegex)
                Button("Search Folder") {
                    let dir = SessionManager.shared.ensureDefaultSaveDirectory(preferences: preferences)
                    findInFilesResults = SearchEngine.findInFiles(directoryURL: dir, options: searchOptions)
                }
                .buttonStyle(.borderedProminent)
            }

            Text("\(findInFilesResults.count) match(es) found")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)

            List(findInFilesResults) { match in
                Button {
                    if let url = match.fileURL {
                        store.open(urls: [url], line: match.lineNumber)
                        showFindInFilesSheet = false
                    }
                } label: {
                    HStack {
                        Text(match.fileURL?.lastPathComponent ?? "file")
                            .font(.system(size: 12, weight: .semibold))
                        Text(":\(match.lineNumber)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.cyan)
                        Text(match.linePreview)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(20)
        .frame(width: 620, height: 400)
    }

}
#endif
