#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit

/// Window chrome colors that follow the Light / Dark / System theme.
enum Chrome {
    @MainActor static var isDark: Bool { WorkspaceStore.shared.preferences.theme.isDark }
    @MainActor static var fg: Color { isDark ? .white : .black }
    @MainActor static var titleBar: Color { isDark ? Color(red: 0.13, green: 0.14, blue: 0.17) : Color(red: 0.93, green: 0.94, blue: 0.95) }
    @MainActor static var toolbar: Color { isDark ? Color(red: 0.13, green: 0.14, blue: 0.17) : Color(red: 0.95, green: 0.95, blue: 0.96) }
    @MainActor static var tabStrip: Color { isDark ? Color(red: 0.115, green: 0.125, blue: 0.15) : Color(red: 0.91, green: 0.92, blue: 0.93) }
    @MainActor static var selectedTab: Color { isDark ? Color(red: 0.16, green: 0.18, blue: 0.22) : .white }
    @MainActor static var editor: Color { isDark ? Color(red: 0.098, green: 0.106, blue: 0.125) : Color(red: 0.99, green: 0.99, blue: 0.995) }
    @MainActor static var statusBar: Color { isDark ? Color(red: 0.12, green: 0.13, blue: 0.16) : Color(red: 0.94, green: 0.94, blue: 0.95) }
    @MainActor static var sidebar: Color { isDark ? Color(red: 0.11, green: 0.12, blue: 0.145) : Color(red: 0.965, green: 0.965, blue: 0.97) }
    @MainActor static var accent: Color { isDark ? Color(red: 0.35, green: 0.83, blue: 0.90) : Color(red: 0.04, green: 0.44, blue: 0.64) }
}

/// Notion-style notes library: folders as notebooks, search across all notes, #tags, open to-do counts.
struct NotesSidebarView: View {
    @ObservedObject private var store = WorkspaceStore.shared
    @State private var library: NoteFolder?
    @State private var query = ""
    @State private var selectedTag: String?
    @State private var expanded: Set<URL> = []
    @State private var renaming: NoteItem?
    @State private var renameText = ""
    @State private var lastScan = Date.distantPast

    private let refreshTimer = Timer.publish(every: 6, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            searchField
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if let library {
                        if !query.isEmpty || selectedTag != nil {
                            let results = NotesLibrary.filter(library.allNotes, query: query, tag: selectedTag)
                            sectionLabel(results.isEmpty ? "No matches" : "\(results.count) result\(results.count == 1 ? "" : "s")")
                            ForEach(results) { noteRow($0, depth: 0) }
                        } else {
                            folderContents(library, depth: 0)
                            if library.allNotes.isEmpty { emptyState }
                        }
                        tagsSection(library)
                    } else {
                        ProgressView().controlSize(.small).padding()
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 12)
            }
            Divider().opacity(0.4)
            footer
        }
        .background(Chrome.sidebar)
        .onAppear(perform: rescan)
        .onChange(of: store.libraryRevision) { _ in rescan() }
        .onReceive(refreshTimer) { _ in rescan() }
        .sheet(item: $renaming) { note in renameSheet(note) }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 8) {
            Text("Notes")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(Chrome.fg.opacity(0.9))
            Spacer()
            Button { createFolder(in: store.notesDirectory) } label: { Image(systemName: "folder.badge.plus") }
                .buttonStyle(.plain).help("New Folder")
            Button { store.newNote() } label: { Image(systemName: "square.and.pencil") }
                .buttonStyle(.plain).help("New Note (⌥⌘N)")
        }
        .font(.system(size: 12.5))
        .foregroundColor(Chrome.fg.opacity(0.65))
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundColor(.secondary)
            TextField("Search notes", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(Chrome.fg.opacity(0.06)))
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No notes yet")
                .font(.system(size: 12, weight: .semibold))
            Text("Press ⌥⌘N for a new note, or ⌘S to save a tab here.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(10)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }

    private func folderContents(_ folder: NoteFolder, depth: Int) -> AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 1) {
                ForEach(folder.subfolders) { sub in
                    folderRow(sub, depth: depth)
                    if expanded.contains(sub.url) {
                        folderContents(sub, depth: depth + 1)
                    }
                }
                ForEach(folder.notes) { noteRow($0, depth: depth) }
            }
        )
    }

    private func folderRow(_ folder: NoteFolder, depth: Int) -> some View {
        let isOpen = expanded.contains(folder.url)
        return HStack(spacing: 5) {
            Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                .font(.system(size: 8.5, weight: .bold))
                .frame(width: 10)
            Image(systemName: isOpen ? "folder.fill" : "folder")
                .font(.system(size: 11.5))
                .foregroundColor(Chrome.accent)
            Text(folder.name)
                .font(.system(size: 12.5, weight: .medium))
                .lineLimit(1)
            Spacer()
            Text("\(folder.allNotes.count)")
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
        }
        .foregroundColor(Chrome.fg.opacity(0.85))
        .padding(.leading, CGFloat(depth) * 12 + 6)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if isOpen { expanded.remove(folder.url) } else { expanded.insert(folder.url) }
        }
        .contextMenu {
            Button("New Note in \(folder.name)") { store.newNote(in: folder.url) }
            Button("New Folder Inside") { createFolder(in: folder.url) }
            Divider()
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) }
        }
    }

    private func noteRow(_ note: NoteItem, depth: Int) -> some View {
        let isActive = store.activeTab?.fileURL?.standardizedFileURL == note.url.standardizedFileURL
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: note.url.pathExtension.lowercased() == "txt" ? "doc.plaintext" : "doc.text")
                    .font(.system(size: 11))
                    .foregroundColor(isActive ? Chrome.accent : .secondary)
                Text(note.title)
                    .font(.system(size: 12.5, weight: isActive ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if note.openTasks > 0 {
                    Text("\(note.openTasks)☐")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .help("\(note.openTasks) open to-do\(note.openTasks == 1 ? "" : "s")")
                }
            }
            HStack(spacing: 4) {
                Text(Self.relative(note.modified))
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                ForEach(note.tags.prefix(2), id: \.self) { tag in
                    Text("#\(tag)")
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(Chrome.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Chrome.accent.opacity(0.13)))
                }
            }
            .padding(.leading, 17)
        }
        .foregroundColor(Chrome.fg.opacity(0.88))
        .padding(.leading, CGFloat(depth) * 12 + 16)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(isActive ? Chrome.accent.opacity(0.14) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { store.open(urls: [note.url]) }
        .help(note.preview)
        .contextMenu {
            Button("Open") { store.open(urls: [note.url]) }
            Button("Rename…") { renameText = note.url.deletingPathExtension().lastPathComponent; renaming = note }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([note.url]) }
            Divider()
            Button("Move to Trash") { trash(note) }
        }
    }

    private func tagsSection(_ library: NoteFolder) -> some View {
        let tags = NotesLibrary.tagCounts(library.allNotes)
        return Group {
            if !tags.isEmpty {
                sectionLabel("Tags")
                FlowLayout(spacing: 5) {
                    ForEach(tags, id: \.tag) { item in
                        let selected = selectedTag == item.tag
                        Text("#\(item.tag) \(item.count)")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(selected ? .white : Chrome.accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(selected ? Chrome.accent : Chrome.accent.opacity(0.13)))
                            .onTapGesture { selectedTag = selected ? nil : item.tag }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }

    private var footer: some View {
        HStack {
            Button {
                NSWorkspace.shared.open(store.notesDirectory)
            } label: {
                Label(store.notesDirectory.lastPathComponent, systemImage: "folder")
                    .lineLimit(1)
            }
            .buttonStyle(.plain)
            .help("Open \((store.notesDirectory.path as NSString).abbreviatingWithTildeInPath) in Finder")
            Spacer()
        }
        .font(.system(size: 10.5))
        .foregroundColor(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }()

    static func relative(_ date: Date) -> String {
        Date().timeIntervalSince(date) < 60 ? "just now" : relativeFormatter.localizedString(for: date, relativeTo: Date())
    }

    // MARK: Actions

    private func rescan() {
        let root = store.notesDirectory
        DispatchQueue.global(qos: .userInitiated).async {
            let scanned = NotesLibrary.scan(root)
            DispatchQueue.main.async {
                if library == nil { expanded.formUnion(scanned.subfolders.map(\.url)) }
                if scanned != library { library = scanned }
                lastScan = Date()
            }
        }
    }

    private func createFolder(in parent: URL) {
        let url = FileService.uniqueURL(in: parent, fileName: "New Folder")
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            expanded.insert(parent)
            expanded.insert(url)
            store.libraryRevision += 1
            renameText = "New Folder"
        } catch {
            store.flashStatus("Couldn't create folder: \(error.localizedDescription)")
        }
    }

    private func trash(_ note: NoteItem) {
        let alert = NSAlert()
        alert.messageText = "Move “\(note.title)” to the Trash?"
        alert.informativeText = "You can restore it from the Trash in Finder."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: note.url, resultingItemURL: nil)
            if let idx = store.tabs.firstIndex(where: { $0.fileURL?.standardizedFileURL == note.url.standardizedFileURL }) {
                if store.tabs[idx].isDirty {
                    // Keep unsaved edits open as an unsaved note instead of discarding them.
                    store.tabs[idx].fileURL = nil
                    store.tabs[idx].fileModificationDate = nil
                } else {
                    store.closeTab(store.tabs[idx].id, confirmIfDirty: false)
                }
            }
            store.libraryRevision += 1
        } catch {
            store.flashStatus("Couldn't move to Trash: \(error.localizedDescription)")
        }
    }

    private func renameSheet(_ note: NoteItem) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Note").font(.headline)
            TextField("Name", text: $renameText).textFieldStyle(.roundedBorder).frame(width: 280)
            HStack {
                Spacer()
                Button("Cancel") { renaming = nil }
                Button("Rename") { rename(note) }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private func rename(_ note: NoteItem) {
        let name = renameText.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-")
        renaming = nil
        guard !name.isEmpty else { return }
        let target = note.url.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension(note.url.pathExtension)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            store.flashStatus("A note named \(target.lastPathComponent) already exists")
            return
        }
        do {
            try FileManager.default.moveItem(at: note.url, to: target)
            if let idx = store.tabs.firstIndex(where: { $0.fileURL?.standardizedFileURL == note.url.standardizedFileURL }) {
                store.tabs[idx].fileURL = target
                store.tabs[idx].title = target.lastPathComponent
                store.tabs[idx].fileModificationDate = FileService.modificationDate(of: target)
            }
            store.libraryRevision += 1
        } catch {
            store.flashStatus("Couldn't rename: \(error.localizedDescription)")
        }
    }
}

/// Wrapping row layout for tag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 240
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// Table of contents for Markdown (headings) and a function list for code.
struct OutlinePanel: View {
    let tab: DocumentTab
    let onSelect: (Int) -> Void

    private var entries: [(level: Int, title: String, line: Int)] {
        if tab.language == .markdown { return MarkdownService.headings(in: tab.content) }
        return CodeOutline.symbols(in: tab.content, language: tab.language)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(tab.language == .markdown ? "OUTLINE" : "SYMBOLS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    let items = entries
                    if items.isEmpty {
                        Text(tab.language == .markdown ? "Add # headings to build an outline." : "No symbols found.")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 14)
                    }
                    ForEach(Array(items.enumerated()), id: \.offset) { _, entry in
                        let current = entry.line <= tab.cursorLine && !(items.contains { $0.line > entry.line && $0.line <= tab.cursorLine })
                        Text(entry.title)
                            .font(.system(size: entry.level == 1 ? 12.5 : 12, weight: entry.level == 1 ? .semibold : .regular))
                            .foregroundColor(current ? Chrome.accent : Chrome.fg.opacity(entry.level == 1 ? 0.88 : 0.7))
                            .lineLimit(1)
                            .padding(.leading, CGFloat(max(0, entry.level - 1)) * 12 + 14)
                            .padding(.trailing, 10)
                            .padding(.vertical, 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { onSelect(entry.line) }
                    }
                }
            }
        }
        .frame(width: 210)
        .background(Chrome.sidebar)
    }
}

/// Lightweight function/class list for code files (Notepad++ "Function List").
enum CodeOutline {
    static func symbols(in text: String, language: SyntaxLanguage) -> [(level: Int, title: String, line: Int)] {
        let pattern: String
        switch language {
        case .swift: pattern = "^\\s*(?:(?:public|private|internal|fileprivate|open|static|final|override|@\\w+)\\s+)*(class|struct|enum|protocol|extension|func|actor)\\s+([A-Za-z_][\\w.]*)"
        case .python: pattern = "^\\s*(class|def|async def)\\s+([A-Za-z_]\\w*)"
        case .javascript: pattern = "^\\s*(?:export\\s+)?(?:default\\s+)?(class|function|const|async function)\\s+([A-Za-z_$][\\w$]*)"
        case .bash: pattern = "^\\s*(function)?\\s*([A-Za-z_][\\w-]*)\\s*\\(\\)"
        case .sql: pattern = "(?i)^\\s*(create\\s+(?:table|view|function|procedure))\\s+([\\w.]+)"
        case .css: pattern = "^([^\\s{][^{]*)(\\{)"
        default: return []
        }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        var result: [(Int, String, Int)] = []
        for (index, line) in text.components(separatedBy: "\n").enumerated() {
            let ns = line as NSString
            guard let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let indent = line.prefix { $0 == " " || $0 == "\t" }.count
            let title: String
            if language == .css {
                title = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            } else {
                let kind = match.range(at: 1).location != NSNotFound ? ns.substring(with: match.range(at: 1)) : "func"
                title = "\(kind) \(ns.substring(with: match.range(at: 2)))"
            }
            result.append((min(4, indent / 4 + 1), title, index + 1))
        }
        return result
    }
}
#endif
