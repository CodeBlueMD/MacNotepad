#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Windows 11 Notepad for macOS — streamlined, responsive, and distraction-free.
public struct MainWorkspaceView: View {
    @ObservedObject private var store = WorkspaceStore.shared
    @State private var dropTargetTabID: UUID?

    public init() {}

    private var activeTab: DocumentTab? { store.activeTab }
    private var isFocusMode: Bool { store.focusMode }

    private var activeMatches: [SearchMatch] {
        guard let tab = activeTab, store.showFindBar, !store.searchOptions.query.isEmpty else { return [] }
        return SearchEngine.findMatches(in: tab.content, options: store.searchOptions)
    }

    private func focusedRange(in matches: [SearchMatch]) -> NSRange? {
        guard !matches.isEmpty else { return nil }
        let safeIdx = min(max(0, store.currentMatchIndex), matches.count - 1)
        return matches[safeIdx].range
    }

    public var body: some View {
        let matches = activeMatches

        VStack(spacing: 0) {
            if !isFocusMode {
                NotepadTabBarView(store: store)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            if let tab = activeTab, store.externallyChangedTabIDs.contains(tab.id) {
                externalChangeBanner(for: tab)
            }

            ZStack(alignment: .topTrailing) {
                if let idx = store.activeTabIndex {
                    CodeEditorView(
                        tab: $store.tabs[idx],
                        preferences: store.preferences,
                        searchHighlights: matches.map(\.range),
                        focusedMatchRange: focusedRange(in: matches)
                    )
                    .id(store.tabs[idx].id)
                    .frame(maxWidth: isFocusMode ? 880 : .infinity)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Color.clear
                }

                if store.showFindBar {
                    NotepadFindBarView(store: store, matchCount: matches.count)
                        .padding(.top, 8)
                        .padding(.trailing, 16)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }

            if !isFocusMode {
                NotepadStatusBarView(store: store)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(themeBackgroundColor)
        .sheet(isPresented: $store.showSettingsSheet) {
            NotepadSettingsSheet(store: store)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleFileDrop(providers)
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: isFocusMode)
    }

    private var themeBackgroundColor: Color {
        switch store.preferences.theme {
        case .darkMica: Color(red: 0.12, green: 0.12, blue: 0.14)
        case .dark: Color(red: 0.10, green: 0.10, blue: 0.10)
        case .light: Color(red: 0.98, green: 0.98, blue: 0.99)
        case .system: Color(NSColor.textBackgroundColor)
        }
    }

    private func externalChangeBanner(for tab: DocumentTab) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("“\(tab.title)” was modified outside MacNotepad.")
                .font(.system(size: 12, weight: .medium))
            Spacer()
            Button("Reload from Disk") { store.reloadTab(tab.id) }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button("Keep My Changes") { store.keepLocalVersion(tab.id) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.yellow.opacity(0.15))
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Color.yellow.opacity(0.3)), alignment: .bottom)
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil) else { return }
                Task { @MainActor in
                    store.open(urls: [url])
                }
            }
        }
        return true
    }
}

// MARK: - Tab Bar View

struct NotepadTabBarView: View {
    @ObservedObject var store: WorkspaceStore
    @State private var draggedTabID: UUID?

    var body: some View {
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(store.tabs) { tab in
                        let isActive = tab.id == store.activeTabID
                        HStack(spacing: 6) {
                            Text(tab.title)
                                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                                .foregroundStyle(isActive ? .primary : .secondary)
                                .lineLimit(1)

                            if tab.isDirty {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 6, height: 6)
                            }

                            Button {
                                store.closeTab(tab.id)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(3)
                                    .background(Circle().fill(Color.primary.opacity(0.06)))
                            }
                            .buttonStyle(.plain)
                            .help("Close Tab (⌘W)")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(isActive ? Color(NSColor.textBackgroundColor) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(isActive ? Color.primary.opacity(0.12) : Color.clear, lineWidth: 0.5)
                        )
                        .contentShape(Rectangle())
                        .onTapGesture {
                            store.activeTabID = tab.id
                        }
                    }

                    Button {
                        _ = store.newTab()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 26, height: 26)
                            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.04)))
                    }
                    .buttonStyle(.plain)
                    .help("New Tab (⌘N)")
                    .padding(.leading, 2)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }

            Spacer(minLength: 8)

            HStack(spacing: 4) {
                Button {
                    store.focusMode.toggle()
                } label: {
                    Image(systemName: store.focusMode ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Toggle Focus Mode (⌥⌘F)")

                Button {
                    store.showSettingsSheet = true
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Settings (⌘,)")
            }
            .padding(.trailing, 10)
        }
        .background(Color(NSColor.windowBackgroundColor).opacity(0.6))
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Color.primary.opacity(0.08)), alignment: .bottom)
    }
}

// MARK: - Find & Replace Bar View

struct NotepadFindBarView: View {
    @ObservedObject var store: WorkspaceStore
    let matchCount: Int

    @FocusState private var findFocused: Bool
    @State private var replaceFocused: Bool = false

    private var matchCountLabel: String {
        if matchCount > 0 {
            return "\(store.currentMatchIndex + 1) of \(matchCount)"
        } else {
            return "No matches"
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)

                    TextField("Find…", text: $store.searchOptions.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($findFocused)
                        .onSubmit { nextMatch() }

                    if !store.searchOptions.query.isEmpty {
                        Text(matchCountLabel)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(matchCount > 0 ? Color.secondary : Color.red)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))

                HStack(spacing: 2) {
                    Button(action: prevMatch) {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .disabled(matchCount == 0)
                    .help("Previous Match (⇧⌘G)")

                    Button(action: nextMatch) {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 22, height: 22)
                    }
                    .buttonStyle(.plain)
                    .disabled(matchCount == 0)
                    .help("Next Match (⌘G)")
                }

                HStack(spacing: 3) {
                    toggleOption("Aa", isOn: $store.searchOptions.matchCase, help: "Match Case")
                    toggleOption("W", isOn: $store.searchOptions.wholeWord, help: "Match Whole Word")
                    toggleOption(".*", isOn: $store.searchOptions.useRegex, help: "Regular Expression")
                }

                Button {
                    withAnimation { store.showFindBar = false }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Close Find Bar (Esc)")
            }

            // Replace row
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    TextField("Replace with…", text: $store.searchOptions.replacement)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .onSubmit { replaceCurrent() }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(NSColor.textBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))

                Button("Replace") {
                    replaceCurrent()
                }
                .controlSize(.small)
                .disabled(matchCount == 0)

                Button("Replace All") {
                    replaceAll()
                }
                .controlSize(.small)
                .disabled(matchCount == 0)
            }
        }
        .padding(10)
        .frame(width: 440)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .onAppear { findFocused = true }
    }

    private func toggleOption(_ title: String, isOn: Binding<Bool>, help: String) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(isOn.wrappedValue ? Color.accentColor : Color.secondary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isOn.wrappedValue ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04))
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func nextMatch() {
        guard matchCount > 0 else { return }
        store.currentMatchIndex = (store.currentMatchIndex + 1) % matchCount
    }

    private func prevMatch() {
        guard matchCount > 0 else { return }
        store.currentMatchIndex = (store.currentMatchIndex - 1 + matchCount) % matchCount
    }

    private func replaceCurrent() {
        guard let idx = store.activeTabIndex, matchCount > 0 else { return }
        let matches = SearchEngine.findMatches(in: store.tabs[idx].content, options: store.searchOptions)
        guard store.currentMatchIndex < matches.count else { return }
        let target = matches[store.currentMatchIndex]
        let replaced = SearchEngine.replace(in: store.tabs[idx].content, targetRange: target.range, with: store.searchOptions.replacement)
        store.tabs[idx].content = replaced
        store.tabs[idx].isDirty = true
    }

    private func replaceAll() {
        guard let idx = store.activeTabIndex, matchCount > 0 else { return }
        let result = SearchEngine.replaceAll(in: store.tabs[idx].content, options: store.searchOptions)
        store.tabs[idx].content = result.updatedText
        store.tabs[idx].isDirty = true
        store.flashStatus("Replaced \(result.replacementsCount) occurrences")
    }
}

// MARK: - Status Bar View

struct NotepadStatusBarView: View {
    @ObservedObject var store: WorkspaceStore

    var body: some View {
        let tab = store.activeTab
        HStack(spacing: 16) {
            if let msg = store.statusBannerMessage {
                Text(msg)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
            } else {
                Text("Ln \(tab?.cursorLine ?? 1), Col \(tab?.cursorColumn ?? 1)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if let tab {
                if tab.selectedCharacterCount > 0 {
                    Text("\(tab.characterCount) characters (\(tab.selectedCharacterCount) selected)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(tab.characterCount) characters")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Text("\(store.preferences.zoomPercentage)%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)

                Menu {
                    Button("Windows (CRLF)") { toggleLineEnding(for: tab, to: .crlf) }
                    Button("Unix (LF)") { toggleLineEnding(for: tab, to: .lf) }
                } label: {
                    Text(tab.lineEnding == .crlf ? "Windows (CRLF)" : "Unix (LF)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Menu {
                    ForEach(DocumentEncoding.allCases) { enc in
                        Button(enc.rawValue) { store.reopenActiveTab(with: enc) }
                    }
                } label: {
                    Text(tab.encoding.rawValue)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button {
                    store.preferences.liveMarkdownStyling.toggle()
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(store.preferences.liveMarkdownStyling ? Color.accentColor : Color.secondary.opacity(0.4))
                            .frame(width: 6, height: 6)
                        Text("Markdown")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(store.preferences.liveMarkdownStyling ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                .help("Toggle Markdown Styling")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color(NSColor.windowBackgroundColor).opacity(0.4))
        .overlay(Rectangle().frame(height: 0.5).foregroundStyle(Color.primary.opacity(0.08)), alignment: .top)
    }

    private func toggleLineEnding(for tab: DocumentTab, to ending: LineEnding) {
        guard let idx = store.activeTabIndex else { return }
        store.tabs[idx].lineEnding = ending
        store.tabs[idx].isDirty = true
    }
}

// MARK: - Settings Sheet

struct NotepadSettingsSheet: View {
    @ObservedObject var store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Notepad Settings")
                    .font(.system(size: 18, weight: .bold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    GroupBox("Appearance") {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Theme", selection: $store.preferences.theme) {
                                ForEach(AppTheme.allCases) { theme in
                                    Text(theme.rawValue).tag(theme)
                                }
                            }
                            .pickerStyle(.segmented)

                            HStack {
                                Text("Font")
                                Spacer()
                                Picker("", selection: $store.preferences.fontFamily) {
                                    Text("SF Mono").tag("SF Mono")
                                    Text("Menlo").tag("Menlo")
                                    Text("Courier New").tag("Courier New")
                                    Text("System Font").tag(".AppleSystemUIFont")
                                }
                                .frame(width: 160)

                                Stepper("\(Int(store.preferences.fontSize)) pt", value: $store.preferences.fontSize, in: 9...36, step: 1)
                                    .frame(width: 110)
                            }
                        }
                        .padding(8)
                    }

                    GroupBox("Editor Behavior") {
                        VStack(alignment: .leading, spacing: 10) {
                            Toggle("Word Wrap", isOn: $store.preferences.wordWrap)
                            Toggle("Show Line Numbers", isOn: $store.preferences.showLineNumbers)
                            Toggle("Continuous Spell Checking", isOn: $store.preferences.spellCheckEnabled)
                            Toggle("Auto-close Brackets and Quotes", isOn: $store.preferences.autoCloseBrackets)
                            Toggle("Lightweight Markdown Formatting", isOn: $store.preferences.liveMarkdownStyling)
                        }
                        .padding(8)
                    }

                    GroupBox("Session Restore") {
                        VStack(alignment: .leading, spacing: 8) {
                            Toggle("Keep unsaved tabs and scratch notes open on restart (Hot Exit)", isOn: $store.preferences.persistentUnsavedTabs)
                            Text("When enabled, tabs and unsaved changes are preserved across app quits without prompting.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 480, height: 420)
    }
}
#endif
