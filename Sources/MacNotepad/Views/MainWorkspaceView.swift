#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit

/// Main Windows 11 Notepad x Notepad++ crossover workspace for macOS, matching the 3 design mockups.
public struct MainWorkspaceView: View {
    @State private var tabs: [DocumentTab] = SessionManager.shared.loadSession()
    @State private var activeTabID: UUID?
    @State private var preferences: EditorPreferences = SessionManager.shared.loadPreferences()

    // Floating Find & Replace Bar (Mockup 1)
    @State private var showFindBar: Bool = true
    @State private var searchOptions = SearchOptions(query: "self")
    @State private var currentMatchIndex: Int = 0

    // Side-by-Side Split & Diff Compare Mode (Mockup 2)
    @State private var isDiffMode: Bool = false
    @State private var compareLeftTabID: UUID?
    @State private var compareRightTabID: UUID?

    // Developer Text Tools Floating Menu & Settings Modal (Mockup 2 & 3)
    @State private var showTextToolsMenu: Bool = false
    @State private var lastAppliedTool: TextToolAction = .jsonPrettyPrint
    @State private var showSettingsSheet: Bool = false
    @State private var statusBannerMessage: String?

    public init() {}

    private var activeTabIndex: Int? {
        guard let id = activeTabID ?? tabs.first?.id else { return nil }
        return tabs.firstIndex { $0.id == id }
    }

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

    public var body: some View {
        VStack(spacing: 0) {
            windowTitleHeader
            commandMenuToolbar

            if !isDiffMode {
                modernTabBar
            }

            ZStack(alignment: .topTrailing) {
                if isDiffMode {
                    diffComparisonWorkspace
                } else if let idx = activeTabIndex {
                    HStack(spacing: 0) {
                        if preferences.showLineNumbers {
                            lineNumberGutter(for: $tabs[idx])
                        }
                        CodeEditorView(
                            tab: $tabs[idx],
                            preferences: preferences,
                            searchHighlights: activeMatches.map(\.range),
                            focusedMatchRange: focusedMatchRange
                        )
                    }
                }

                // Floating Find & Replace Panel (Top-Right, Mockup 1)
                if showFindBar && !isDiffMode {
                    floatingFindReplaceBar
                        .padding(.top, 10)
                        .padding(.trailing, 18)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }

                // Floating Developer Text Tools Dropdown Panel (Top-Right, Mockup 2)
                if showTextToolsMenu {
                    developerTextToolsOverlay
                        .padding(.top, 6)
                        .padding(.trailing, 14)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topTrailing)))
                }
            }

            modernStatusBar
        }
        .background(Color(nsColor: NSColor(calibratedRed: 0.098, green: 0.106, blue: 0.125, alpha: 1.0)))
        .preferredColorScheme(preferences.theme == .light ? .light : .dark)
        .onAppear {
            // Default to AppEngine.swift tab on launch to match Mockup 1
            if activeTabID == nil {
                if let appEngineTab = tabs.first(where: { $0.title == "AppEngine.swift" }) {
                    activeTabID = appEngineTab.id
                } else {
                    activeTabID = tabs.first?.id
                }
            }
            setupDefaultDiffTabs()
            SessionManager.shared.ensureDefaultSaveDirectory(preferences: preferences)
        }
        .onChange(of: tabs) { updatedTabs in
            if preferences.persistentUnsavedTabs {
                SessionManager.shared.saveSession(tabs: updatedTabs)
            }
        }
        .sheet(isPresented: $showSettingsSheet) {
            settingsSheetView
        }
    }

    // MARK: - 1. Window Title Header (Mockup 1 & 2)

    private var windowTitleHeader: some View {
        let activeTitle = activeTabIndex.map { tabs[$0].title } ?? "AppEngine.swift"
        let leftTitle = tabs.first(where: { $0.id == compareLeftTabID })?.title ?? "server-v1.json"
        let rightTitle = tabs.first(where: { $0.id == compareRightTabID })?.title ?? "server-v2.json"

        return HStack {
            Spacer()
            if isDiffMode {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    Text("\(leftTitle)  |  \(rightTitle) - Diff")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.88))
                }
            } else {
                Text("MacNotepad — \(activeTitle)")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.88))
            }
            Spacer()
        }
        .frame(height: 28)
        .background(Color(nsColor: NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.17, alpha: 1.0)))
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
                    .foregroundColor(Color.white.opacity(0.85))
                }
                .buttonStyle(.plain)

                Button(action: quickSaveActiveTabToDocuments) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.down.doc")
                        Text("Save")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.85))
                }
                .buttonStyle(.plain)

                Button(action: mergeRightIntoLeft) {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.merge")
                        Text("Merge")
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.85))
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
                        Button("New Scratch Tab (Cmd+N)", action: createNewTab)
                        Button("Open File… (Cmd+O)", action: openFilePanel)
                        Divider()
                        Button("Quick Save to ~/Documents/MacNotepad (Cmd+S)", action: quickSaveActiveTabToDocuments)
                        Button("Save As…", action: saveActiveTabWithPanel)
                        Divider()
                        Button("Preferences & Default Save Location…") { showSettingsSheet = true }
                    }
                    .menuStyle(.borderlessButton)
                    .font(.system(size: 12.5, weight: .medium))
                    .fixedSize()

                    Menu("Edit") {
                        Button("Find & Replace (Cmd+F)") {
                            withAnimation { showFindBar.toggle() }
                        }
                        Button("Replace All Matches") {
                            replaceAllInActiveTab()
                        }
                    }
                    .menuStyle(.borderlessButton)
                    .font(.system(size: 12.5, weight: .medium))
                    .fixedSize()

                    Menu("View") {
                        Toggle("Show Line Numbers", isOn: $preferences.showLineNumbers)
                        Toggle("Enable Code Folding", isOn: $preferences.enableCodeFolding)
                        Toggle("Word Wrap", isOn: $preferences.wordWrap)
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
                            .foregroundColor(showTextToolsMenu ? .cyan : Color.white.opacity(0.88))
                    }
                    .buttonStyle(.plain)

                    Button {
                        enterOrToggleDiffMode()
                    } label: {
                        Text("Compare")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(isDiffMode ? .cyan : Color.white.opacity(0.88))
                    }
                    .buttonStyle(.plain)
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
                    Text("Quick Save to ~/Documents/MacNotepad")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.9))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
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
                        .foregroundColor(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isDiffMode ? Color.blue : Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .help("Toggle Side-by-Side Diff Comparison")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color(nsColor: NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.17, alpha: 1.0)))
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
                                        ? .white
                                        : (tab.title.hasPrefix("new ") ? Color.cyan : Color.white.opacity(0.62))
                                )
                                .lineLimit(1)

                            if tab.isDirty {
                                Circle()
                                    .fill(tab.title.hasPrefix("new ") ? Color.cyan : Color.white.opacity(0.55))
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
                                        .fill(Color(nsColor: NSColor(calibratedRed: 0.16, green: 0.18, blue: 0.22, alpha: 1.0)))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                                .stroke(Color.white.opacity(0.14), lineWidth: 1)
                                        )
                                } else {
                                    Color.clear
                                }
                            }
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            activeTabID = tab.id
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
        .background(Color(nsColor: NSColor(calibratedRed: 0.115, green: 0.125, blue: 0.15, alpha: 1.0)))
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

                TextField("Find…", text: $searchOptions.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(width: 165)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.black.opacity(0.35))
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
                            .foregroundColor(searchOptions.matchCase ? .cyan : Color.white.opacity(0.82))
                    }
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.plain)
                .frame(width: 96, alignment: .leading)

                Toggle("Match Whole Word", isOn: $searchOptions.wholeWord)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
                    .foregroundColor(Color.white.opacity(0.82))
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
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.10)))
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
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.10)))
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

                TextField("Replace…", text: $searchOptions.replacement)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(width: 165)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.black.opacity(0.35))
                            .overlay(
                                RoundedRectangle(cornerRadius: 5)
                                    .stroke(Color.white.opacity(0.16), lineWidth: 1)
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
                            .foregroundColor(searchOptions.useRegex ? .cyan : Color.white.opacity(0.82))
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
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.12)))
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
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.12)))
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
                .fill(Color(nsColor: NSColor(calibratedRed: 0.14, green: 0.15, blue: 0.19, alpha: 0.96)))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                )
        )
        .shadow(color: .black.opacity(0.45), radius: 12, x: 0, y: 6)
    }

    // MARK: - 5. Line Numbers & Interactive Code Folding Gutter (Mockup 1)

    private func lineNumberGutter(for tab: Binding<DocumentTab>) -> some View {
        let blocks = SyntaxHighlighter.detectFoldableBlocks(in: tab.wrappedValue.content)
        let foldableStarts = Set(blocks.map(\.startLine))
        let displayOffset = tab.wrappedValue.title == "AppEngine.swift" ? 29 : 0

        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(1...max(1, tab.wrappedValue.lineCount), id: \.self) { line in
                    let shownLineNumber = line + displayOffset
                    let isFolded = tab.wrappedValue.foldedLineNumbers.contains(line)
                    HStack(spacing: 5) {
                        Text("\(shownLineNumber)")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(line == tab.wrappedValue.cursorLine ? .white : Color.white.opacity(0.35))

                        if preferences.enableCodeFolding && foldableStarts.contains(line) {
                            Button {
                                if isFolded {
                                    tab.wrappedValue.foldedLineNumbers.remove(line)
                                } else {
                                    tab.wrappedValue.foldedLineNumbers.insert(line)
                                }
                            } label: {
                                Image(systemName: isFolded ? "chevron.right" : "chevron.down")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Spacer().frame(width: 10)
                        }
                    }
                    .frame(height: 19)
                }
            }
            .padding(.vertical, 12)
            .padding(.horizontal, 8)
        }
        .frame(width: 54)
        .background(Color(nsColor: NSColor(calibratedRed: 0.098, green: 0.106, blue: 0.125, alpha: 1.0)))
    }

    // MARK: - 6. Side-by-Side Split & Diff View (Mockup 2)

    private var diffComparisonWorkspace: some View {
        let leftTab = tabs.first { $0.id == compareLeftTabID } ?? tabs.first ?? DocumentTab(title: "server-v1.json")
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
                        Text("\(leftTab.title == "config.json" ? "server-v1.json" : leftTab.title) (Original)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Color.white.opacity(0.88))
                    }
                    .menuStyle(.borderlessButton)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(0.03))

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
                            .foregroundColor(Color.white.opacity(0.88))
                    }
                    .menuStyle(.borderlessButton)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(0.03))
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
                                    .foregroundColor(Color.white.opacity(0.35))
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
                                    .foregroundColor(Color.white.opacity(0.35))
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
        return Text(line).foregroundColor(Color.white.opacity(0.88))
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
                    .foregroundColor(.white)
                    .frame(width: 14)
                Image(systemName: "info.circle")
                    .font(.system(size: 11.5))
                    .foregroundColor(.cyan)
                Text("Current \(currentLang.rawValue)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .padding(.vertical, 8)
        .frame(width: 225)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: NSColor(calibratedRed: 0.15, green: 0.16, blue: 0.20, alpha: 0.98)))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
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
                        .foregroundColor(.white)
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
                    .fill(isSelected ? Color.white.opacity(0.10) : Color.clear)
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
                .keyboardShortcut(.defaultAction)
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
                    TextField("", text: $preferences.defaultSaveDirectoryPath)
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
                    Toggle("", isOn: $preferences.autoCreateDefaultSaveFolder)
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
                Toggle("", isOn: $preferences.persistentUnsavedTabs)
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
                Picker("", selection: $preferences.theme) {
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
                    Picker("", selection: $preferences.fontFamily) {
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

                Divider().opacity(0.4)

                HStack {
                    Text("Code Folding")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.black.opacity(0.85))
                    Spacer()
                    Text(preferences.enableCodeFolding ? "On" : "Off")
                        .font(.system(size: 12.5))
                        .foregroundColor(.gray)
                    Toggle("", isOn: $preferences.enableCodeFolding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)

                Divider().opacity(0.4)

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Column Selection")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.black.opacity(0.85))
                        Text("Option + Drag enables column (block) selection")
                            .font(.system(size: 11.5))
                            .foregroundColor(.gray)
                    }
                    Spacer()
                    Text(preferences.enableColumnSelection ? "On" : "Off")
                        .font(.system(size: 12.5))
                        .foregroundColor(.gray)
                    Toggle("", isOn: $preferences.enableColumnSelection)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
            .background(settingsCardBackground)
        }
        .padding(24)
        .frame(width: 600)
        .background(Color(white: 0.94))
        .environment(\.colorScheme, .light)
    }

    private func settingsSectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 12.5, weight: .bold))
            .foregroundColor(.black.opacity(0.82))
    }

    private var settingsCardBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.white.opacity(0.75))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.black.opacity(0.08), lineWidth: 1)
            )
    }

    // MARK: - 9. Bottom Status Bar (Mockup 1 & 2)

    private var modernStatusBar: some View {
        let tab = activeTabIndex.map { tabs[$0] } ?? DocumentTab(title: "AppEngine.swift")
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
                Text("\(tab.wordCount) words")
                Text("|").foregroundColor(.secondary.opacity(0.5))
                Text("\(tab.characterCount) chars")

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
                Text(tab.encoding.rawValue)
                Text("|").foregroundColor(.secondary.opacity(0.5))
                Text(tab.lineEnding.rawValue)
                Text("|").foregroundColor(.secondary.opacity(0.5))
                Text("\(preferences.zoomPercentage)%")
                Text("|").foregroundColor(.secondary.opacity(0.5))
                Text("Default: ~/Documents/MacNotepad")
                    .foregroundColor(.secondary)
            }
        }
        .font(.system(size: 11.5))
        .foregroundColor(Color.white.opacity(0.75))
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
        .background(Color(nsColor: NSColor(calibratedRed: 0.12, green: 0.13, blue: 0.16, alpha: 1.0)))
        .overlay(Divider().opacity(0.35), alignment: .top)
    }

    // MARK: - Actions

    private func setupDefaultDiffTabs() {
        if compareLeftTabID == nil {
            compareLeftTabID = tabs.first(where: { $0.title == "config.json" })?.id ?? tabs.first?.id
        }
        if compareRightTabID == nil {
            compareRightTabID = tabs.first(where: { $0.title == "new 1" })?.id ?? tabs.last?.id
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

    private func createNewTab() {
        let nextNum = tabs.count + 1
        let newTab = DocumentTab(title: "new \(nextNum)", content: "", isDirty: true)
        tabs.append(newTab)
        activeTabID = newTab.id
    }

    private func closeTab(_ id: UUID) {
        tabs.removeAll { $0.id == id }
        if tabs.isEmpty {
            createNewTab()
        } else if activeTabID == id {
            activeTabID = tabs.last?.id
        }
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

    private func copyActiveFilePath() {
        guard let idx = activeTabIndex else { return }
        let path = tabs[idx].fileURL?.path ?? "\(preferences.defaultSaveDirectoryPath)/\(tabs[idx].title)"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        flashStatus("Copied path to clipboard")
    }

    private func quickSaveActiveTabToDocuments() {
        guard let idx = activeTabIndex else { return }
        do {
            let savedURL = try SessionManager.shared.quickSaveToDefaultDirectory(
                tab: &tabs[idx],
                preferences: preferences
            )
            flashStatus("Saved to \(savedURL.lastPathComponent)")
        } catch {
            flashStatus("Save failed: \(error.localizedDescription)")
        }
    }

    private func openFilePanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.directoryURL = SessionManager.shared.ensureDefaultSaveDirectory(preferences: preferences)

        if panel.runModal() == .OK {
            for url in panel.urls {
                if let text = try? String(contentsOf: url, encoding: .utf8) {
                    let tab = DocumentTab(
                        title: url.lastPathComponent,
                        content: text,
                        fileURL: url,
                        isDirty: false,
                        language: SyntaxLanguage.detect(from: url, content: text),
                        lineEnding: LineEnding.detect(in: text)
                    )
                    tabs.append(tab)
                    activeTabID = tab.id
                }
            }
        }
    }

    private func saveActiveTabWithPanel() {
        guard let idx = activeTabIndex else { return }
        let panel = NSSavePanel()
        panel.directoryURL = SessionManager.shared.ensureDefaultSaveDirectory(preferences: preferences)
        panel.nameFieldStringValue = tabs[idx].title.contains(".")
            ? tabs[idx].title
            : "\(tabs[idx].title).\(tabs[idx].language.defaultFileExtension)"

        if panel.runModal() == .OK, let url = panel.url {
            try? tabs[idx].content.write(to: url, atomically: true, encoding: .utf8)
            tabs[idx].fileURL = url
            tabs[idx].title = url.lastPathComponent
            tabs[idx].isDirty = false
            flashStatus("Saved \(url.lastPathComponent)")
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

    private func flashStatus(_ message: String) {
        statusBannerMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            if statusBannerMessage == message {
                statusBannerMessage = nil
            }
        }
    }
}
#endif
