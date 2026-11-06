#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit

/// Main Windows 11 Notepad x Notepad++ crossover workspace for macOS.
public struct MainWorkspaceView: View {
    @State private var tabs: [DocumentTab] = SessionManager.shared.loadSession()
    @State private var activeTabID: UUID?
    @State private var preferences: EditorPreferences = SessionManager.shared.loadPreferences()

    // Floating Find & Replace Bar (Windows 11 Notepad style)
    @State private var showFindBar: Bool = false
    @State private var showReplaceRow: Bool = false
    @State private var searchOptions = SearchOptions()
    @State private var currentMatchIndex: Int = 0

    // Side-by-Side Split & Diff Compare Mode (Notepad++ style)
    @State private var isDiffMode: Bool = false
    @State private var compareRightTabID: UUID?

    // Developer Text Tools & Modals
    @State private var showTextToolsPopover: Bool = false
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

    public var body: some View {
        VStack(spacing: 0) {
            modernTabBar
            minimalistCommandBar

            ZStack(alignment: .topTrailing) {
                if isDiffMode {
                    diffComparisonWorkspace
                } else if let idx = activeTabIndex {
                    HStack(spacing: 0) {
                        if preferences.showLineNumbers {
                            lineNumberGutter(for: tabs[idx])
                        }
                        CodeEditorView(
                            tab: $tabs[idx],
                            preferences: preferences,
                            searchHighlights: activeMatches.map(\.range)
                        )
                    }
                }

                if showFindBar {
                    floatingFindReplaceBar
                        .padding(.top, 10)
                        .padding(.trailing, 18)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }

            modernStatusBar
        }
        .preferredColorScheme(preferences.theme == .lightMica ? .light : .dark)
        .onAppear {
            if activeTabID == nil {
                activeTabID = tabs.first?.id
            }
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

    // MARK: - 1. Windows 11 Notepad Style Rounded Title-Bar Tabs

    private var modernTabBar: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(tabs) { tab in
                        let isSelected = (tab.id == (activeTabID ?? tabs.first?.id))
                        HStack(spacing: 8) {
                            Image(systemName: tab.language == .plainText ? "doc.text" : "chevron.left.forwardslash.chevron.right")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(isSelected ? .accentColor : .secondary)

                            Text(tab.title)
                                .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                                .lineLimit(1)

                            if tab.isDirty {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 7, height: 7)
                                    .help("Unsaved changes (persisted automatically by Hot Exit)")
                            }

                            Button {
                                closeTab(tab.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(isSelected ? Color.primary.opacity(0.12) : Color.primary.opacity(0.04))
                        )
                        .onTapGesture {
                            activeTabID = tab.id
                        }
                    }

                    Button(action: createNewTab) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(7)
                            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .help("New Scratch Tab (Cmd+N)")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }

            Spacer()

            if let banner = statusBannerMessage {
                Text(banner)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.green.opacity(0.14)))
            }

            Button {
                showSettingsSheet = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14, weight: .medium))
                    .padding(7)
            }
            .buttonStyle(.plain)
            .help("Settings & Default Save Location (Cmd+,)")
            .padding(.trailing, 10)
        }
        .background(.ultraThinMaterial)
    }

    // MARK: - 2. Minimalist Modern Command Bar

    private var minimalistCommandBar: some View {
        HStack(spacing: 12) {
            Button(action: openFilePanel) {
                Label("Open", systemImage: "folder")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)

            Button(action: saveActiveTabWithPanel) {
                Label("Save As…", systemImage: "square.and.arrow.down")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)

            Button(action: quickSaveActiveTabToDocuments) {
                HStack(spacing: 5) {
                    Image(systemName: "bolt.horizontal.circle.fill")
                    Text("Quick Save to ~/Documents/MacNotepad")
                }
                .font(.system(size: 11.5, weight: .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.accentColor.opacity(0.18)))
            }
            .buttonStyle(.plain)

            Divider().frame(height: 16)

            Button {
                withAnimation(.easeInOut(duration: 0.15)) {
                    showFindBar.toggle()
                }
            } label: {
                Label("Find & Replace", systemImage: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)

            Button {
                showTextToolsPopover.toggle()
            } label: {
                Label("Developer Text Tools", systemImage: "wand.and.stars")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .popover(isPresented: $showTextToolsPopover, arrowEdge: .bottom) {
                textToolsPopoverView
            }

            Button {
                withAnimation {
                    isDiffMode.toggle()
                    if compareRightTabID == nil {
                        compareRightTabID = tabs.last?.id
                    }
                }
            } label: {
                Label(isDiffMode ? "Exit Compare" : "Compare Tabs (Diff)", systemImage: "rectangle.split.2x1")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isDiffMode ? .accentColor : .primary)
            }
            .buttonStyle(.borderless)

            Spacer()

            if let idx = activeTabIndex {
                Picker("Syntax", selection: $tabs[idx].language) {
                    ForEach(SyntaxLanguage.allCases) { lang in
                        Text(lang.rawValue).tag(lang)
                    }
                }
                .labelsHidden()
                .frame(width: 130)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.03))
        .overlay(Divider(), alignment: .bottom)
    }

    // MARK: - 3. Floating Modern Find & Replace Pill Bar

    private var floatingFindReplaceBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    withAnimation { showReplaceRow.toggle() }
                } label: {
                    Image(systemName: showReplaceRow ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                }
                .buttonStyle(.plain)

                TextField("Find in tab…", text: $searchOptions.query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 190)

                Toggle("Aa", isOn: $searchOptions.matchCase)
                    .toggleStyle(.button)
                    .help("Match Case")

                Toggle(".*", isOn: $searchOptions.useRegex)
                    .toggleStyle(.button)
                    .help("Regular Expression")

                Toggle("Word", isOn: $searchOptions.wholeWord)
                    .toggleStyle(.button)
                    .help("Match Whole Word")

                Text("\(activeMatches.count) matches")
                    .font(.system(size: 11.5, design: .monospaced))
                    .foregroundColor(.secondary)

                Button {
                    showFindBar = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            if showReplaceRow {
                HStack(spacing: 8) {
                    Spacer().frame(width: 16)
                    TextField("Replace with… ($1, $2 supported)", text: $searchOptions.replacement)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)

                    Button("Replace All") {
                        guard let idx = activeTabIndex else { return }
                        let result = SearchEngine.replaceAll(in: tabs[idx].content, options: searchOptions)
                        tabs[idx].content = result.updatedText
                        tabs[idx].isDirty = true
                        flashStatus("Replaced \(result.replacementsCount) occurrence(s)")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 10, x: 0, y: 4)
    }

    // MARK: - 4. Line Numbers & Code Folding Gutter

    private func lineNumberGutter(for tab: DocumentTab) -> some View {
        let foldableStarts = Set(SyntaxHighlighter.detectFoldableBlocks(in: tab.content).map(\.startLine))
        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .trailing, spacing: 2) {
                ForEach(1...max(1, tab.lineCount), id: \.self) { line in
                    HStack(spacing: 4) {
                        Text("\(line)")
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(line == tab.cursorLine ? .primary : .secondary.opacity(0.6))
                        if preferences.enableCodeFolding && foldableStarts.contains(line) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundColor(.accentColor)
                        } else {
                            Spacer().frame(width: 8)
                        }
                    }
                }
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 8)
        }
        .frame(width: 54)
        .background(Color.primary.opacity(0.03))
        .overlay(Divider(), alignment: .trailing)
    }

    // MARK: - 5. Side-by-Side Split & Diff View

    private var diffComparisonWorkspace: some View {
        let leftTab = activeTabIndex.map { tabs[$0] } ?? tabs.first ?? DocumentTab(title: "Left")
        let rightTab = tabs.first { $0.id == compareRightTabID } ?? tabs.last ?? leftTab
        let comparison = DiffEngine.compare(left: leftTab.content, right: rightTab.content)

        return VStack(spacing: 0) {
            HStack {
                Text("Left: \(leftTab.title)")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("+\(comparison.summary.additions) added  ~\(comparison.summary.modifications) modified  -\(comparison.summary.removals) removed")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
                Spacer()
                Picker("Compare With:", selection: $compareRightTabID) {
                    ForEach(tabs) { t in
                        Text(t.title).tag(Optional(t.id))
                    }
                }
                .frame(width: 220)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.05))

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(comparison.rows) { row in
                        HStack(spacing: 0) {
                            HStack(spacing: 8) {
                                Text(row.leftLineNumber.map(String.init) ?? "")
                                    .frame(width: 34, alignment: .trailing)
                                    .foregroundColor(.secondary)
                                Text(row.leftText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 3)
                            .padding(.horizontal, 8)
                            .background(diffBackgroundColor(for: row.kind, isLeft: true))

                            Divider()

                            HStack(spacing: 8) {
                                Text(row.rightLineNumber.map(String.init) ?? "")
                                    .frame(width: 34, alignment: .trailing)
                                    .foregroundColor(.secondary)
                                Text(row.rightText)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, 3)
                            .padding(.horizontal, 8)
                            .background(diffBackgroundColor(for: row.kind, isLeft: false))
                        }
                        .font(.system(size: 12.5, design: .monospaced))
                    }
                }
            }
        }
    }

    private func diffBackgroundColor(for kind: DiffLineKind, isLeft: Bool) -> Color {
        switch kind {
        case .unchanged:
            return .clear
        case .added:
            return isLeft ? Color.clear : Color.green.opacity(0.18)
        case .removed:
            return isLeft ? Color.red.opacity(0.18) : Color.clear
        case .modified:
            return Color.orange.opacity(0.18)
        }
    }

    // MARK: - 6. Developer Text Tools Popover

    private var textToolsPopoverView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Developer Text Tools (Notepad++)")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.secondary)
                .padding(.bottom, 4)

            ForEach(TextToolAction.allCases) { action in
                Button {
                    applyTextTool(action)
                    showTextToolsPopover = false
                } label: {
                    HStack {
                        Text(action.rawValue)
                            .font(.system(size: 12.5))
                        Spacer()
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(width: 250)
    }

    // MARK: - 7. Settings & Default Save Location Sheet

    private var settingsSheetView: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Settings & Session Recovery")
                    .font(.system(size: 18, weight: .bold))
                Spacer()
                Button("Done") {
                    SessionManager.shared.savePreferences(preferences)
                    showSettingsSheet = false
                }
                .buttonStyle(.borderedProminent)
            }

            GroupBox("Default Save Location (Documents)") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        TextField("Default Save Folder", text: $preferences.defaultSaveDirectoryPath)
                            .textFieldStyle(.roundedBorder)
                        Button("Choose Folder…") {
                            chooseDefaultSaveDirectory()
                        }
                    }
                    Toggle("Automatically create folder under ~/Documents if missing", isOn: $preferences.autoCreateDefaultSaveFolder)
                }
                .padding(8)
            }

            GroupBox("Session & Persistent Unsaved Tabs") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Persistent Unsaved Tabs (Hot Exit — never lose scratch tabs on quit)", isOn: $preferences.persistentUnsavedTabs)
                    Toggle("Enable Line Numbers", isOn: $preferences.showLineNumbers)
                    Toggle("Enable Code Folding Chevrons", isOn: $preferences.enableCodeFolding)
                    Toggle("Enable Column / Block Selection (Option + Drag)", isOn: $preferences.enableColumnSelection)
                }
                .padding(8)
            }

            GroupBox("Appearance & Typography") {
                HStack(spacing: 16) {
                    Picker("Theme", selection: $preferences.theme) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.rawValue).tag(theme)
                        }
                    }
                    Stepper("Font Size: \(Int(preferences.fontSize))pt", value: $preferences.fontSize, in: 10...24)
                }
                .padding(8)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    // MARK: - 8. Windows 11 Notepad Modern Status Bar

    private var modernStatusBar: some View {
        let tab = activeTabIndex.map { tabs[$0] } ?? DocumentTab(title: "new 1")
        return HStack(spacing: 14) {
            Text("Ln \(tab.cursorLine), Col \(tab.cursorColumn)")
            Divider().frame(height: 12)
            if tab.selectedCharacterCount > 0 {
                Text("\(tab.selectedCharacterCount) selected")
                    .foregroundColor(.accentColor)
                Divider().frame(height: 12)
            }
            Text("\(tab.wordCount) words")
            Text("\(tab.characterCount) chars")

            Spacer()

            Text("Default Save: ~/Documents/MacNotepad")
                .foregroundColor(.secondary)
            Divider().frame(height: 12)
            Text(tab.language.rawValue)
                .fontWeight(.medium)
            Divider().frame(height: 12)
            Text("\(preferences.zoomPercentage)%")
            Divider().frame(height: 12)
            Text(tab.lineEnding.rawValue)
            Divider().frame(height: 12)
            Text(tab.encoding.rawValue)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .overlay(Divider(), alignment: .top)
    }

    // MARK: - Actions

    private func createNewTab() {
        let nextNum = tabs.count + 1
        let newTab = DocumentTab(title: "new \(nextNum)", content: "", isDirty: false)
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

    private func quickSaveActiveTabToDocuments() {
        guard let idx = activeTabIndex else { return }
        do {
            let savedURL = try SessionManager.shared.quickSaveToDefaultDirectory(
                tab: &tabs[idx],
                preferences: preferences
            )
            flashStatus("Saved to \(savedURL.path)")
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
