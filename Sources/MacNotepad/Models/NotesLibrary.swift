import Foundation

/// One note (or plain-text file) in the notes folder.
public struct NoteItem: Identifiable, Equatable {
    public var id: URL { url }
    public let url: URL
    public let title: String
    public let tags: [String]
    public let modified: Date
    public let openTasks: Int
    public let preview: String
}

/// A folder in the notes library (folders act as categories / notebooks).
public struct NoteFolder: Identifiable, Equatable {
    public var id: URL { url }
    public let url: URL
    public var name: String { url.lastPathComponent }
    public var notes: [NoteItem]
    public var subfolders: [NoteFolder]

    public var allNotes: [NoteItem] { notes + subfolders.flatMap(\.allNotes) }
}

/// Scans the notes folder for Markdown/text notes, their titles, #tags and open to-dos.
public enum NotesLibrary {
    public static let noteExtensions: Set<String> = ["md", "markdown", "txt", "text"]

    public static func scan(_ root: URL, depth: Int = 0) -> NoteFolder {
        let fm = FileManager.default
        let items = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        var notes: [NoteItem] = []
        var folders: [NoteFolder] = []
        for url in items {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey])
            if values?.isDirectory == true {
                if depth < 6 { folders.append(scan(url, depth: depth + 1)) }
            } else if noteExtensions.contains(url.pathExtension.lowercased()) {
                notes.append(note(at: url, modified: values?.contentModificationDate ?? .distantPast))
            }
        }
        notes.sort { $0.modified > $1.modified }
        folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return NoteFolder(url: root, notes: notes, subfolders: folders)
    }

    static func note(at url: URL, modified: Date) -> NoteItem {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let text: String
        if size <= 512_000, let data = try? Data(contentsOf: url) {
            text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        } else {
            text = ""
        }
        let isMarkdown = ["md", "markdown"].contains(url.pathExtension.lowercased())
        let title = (isMarkdown ? MarkdownService.title(of: text) : nil) ?? url.deletingPathExtension().lastPathComponent
        let preview = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("#") && $0 != "---" } ?? ""
        return NoteItem(
            url: url,
            title: title,
            tags: isMarkdown ? MarkdownService.tags(in: text) : [],
            modified: modified,
            openTasks: isMarkdown ? MarkdownService.taskCounts(in: text).open : 0,
            preview: String(preview.prefix(120))
        )
    }

    /// Notes matching a search string (title, file name, tags, or body text) and/or a tag.
    public static func filter(_ notes: [NoteItem], query: String, tag: String?) -> [NoteItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return notes.filter { note in
            if let tag, !note.tags.contains(tag) { return false }
            guard !q.isEmpty else { return true }
            if note.title.lowercased().contains(q) || note.url.lastPathComponent.lowercased().contains(q) { return true }
            if note.tags.contains(where: { $0.contains(q.trimmingCharacters(in: CharacterSet(charactersIn: "#"))) }) { return true }
            guard let body = try? String(contentsOf: note.url, encoding: .utf8) else { return false }
            return body.lowercased().contains(q)
        }
    }

    /// All tags with how many notes use each, most used first.
    public static func tagCounts(_ notes: [NoteItem]) -> [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for note in notes { for tag in note.tags { counts[tag, default: 0] += 1 } }
        return counts.map { ($0.key, $0.value) }.sorted { $0.count != $1.count ? $0.count > $1.count : $0.tag < $1.tag }
    }
}
