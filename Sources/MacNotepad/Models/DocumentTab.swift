import Foundation

/// Supported syntax highlighting languages in MacNotepad.
public enum SyntaxLanguage: String, Codable, CaseIterable, Identifiable {
    case plainText = "Plain Text"
    case swift = "Swift"
    case python = "Python"
    case javascript = "JavaScript"
    case json = "JSON"
    case html = "HTML / XML"
    case markdown = "Markdown"
    case sql = "SQL"
    case css = "CSS"
    case bash = "Shell / Bash"

    public var id: String { rawValue }

    public var defaultFileExtension: String {
        switch self {
        case .plainText: return "txt"
        case .swift: return "swift"
        case .python: return "py"
        case .javascript: return "js"
        case .json: return "json"
        case .html: return "html"
        case .markdown: return "md"
        case .sql: return "sql"
        case .css: return "css"
        case .bash: return "sh"
        }
    }

    public static func detect(from url: URL?, content: String = "") -> SyntaxLanguage {
        if let ext = url?.pathExtension.lowercased(), !ext.isEmpty {
            switch ext {
            case "swift": return .swift
            case "py": return .python
            case "js", "ts", "jsx", "tsx", "mjs": return .javascript
            case "json", "geojson": return .json
            case "html", "htm", "xml", "plist", "svg": return .html
            case "md", "markdown": return .markdown
            case "sql": return .sql
            case "css", "scss": return .css
            case "sh", "bash", "zsh": return .bash
            default: break
            }
        }
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) {
            return .json
        }
        if trimmed.hasPrefix("<!DOCTYPE") || trimmed.hasPrefix("<?xml") || trimmed.hasPrefix("<html") {
            return .html
        }
        if trimmed.hasPrefix("# ") || trimmed.contains("\n## ") {
            return .markdown
        }
        return .plainText
    }
}

/// Line ending style (Windows CRLF vs Unix/macOS LF).
public enum LineEnding: String, Codable, CaseIterable, Identifiable {
    case lf = "LF"
    case crlf = "CRLF"

    public var id: String { rawValue }

    public var separator: String {
        switch self {
        case .lf: return "\n"
        case .crlf: return "\r\n"
        }
    }

    public static func detect(in text: String) -> LineEnding {
        text.contains("\r\n") ? .crlf : .lf
    }
}

/// Text encoding options.
public enum DocumentEncoding: String, Codable, CaseIterable, Identifiable {
    case utf8 = "UTF-8"
    case utf16 = "UTF-16"
    case ascii = "ASCII"

    public var id: String { rawValue }
}

/// Represents a single open tab (saved file or persistent unsaved scratch tab).
public struct DocumentTab: Identifiable, Codable, Equatable {
    public var id: UUID
    public var title: String
    public var content: String
    public var fileURL: URL?
    public var isDirty: Bool
    public var language: SyntaxLanguage
    public var lineEnding: LineEnding
    public var encoding: DocumentEncoding
    public var cursorLine: Int
    public var cursorColumn: Int
    public var selectedCharacterCount: Int
    public var foldedLineNumbers: Set<Int>
    public var lastModified: Date

    public init(
        id: UUID = UUID(),
        title: String,
        content: String = "",
        fileURL: URL? = nil,
        isDirty: Bool = false,
        language: SyntaxLanguage = .plainText,
        lineEnding: LineEnding = .lf,
        encoding: DocumentEncoding = .utf8,
        cursorLine: Int = 1,
        cursorColumn: Int = 1,
        selectedCharacterCount: Int = 0,
        foldedLineNumbers: Set<Int> = [],
        lastModified: Date = Date()
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.fileURL = fileURL
        self.isDirty = isDirty
        self.language = language
        self.lineEnding = lineEnding
        self.encoding = encoding
        self.cursorLine = cursorLine
        self.cursorColumn = cursorColumn
        self.selectedCharacterCount = selectedCharacterCount
        self.foldedLineNumbers = foldedLineNumbers
        self.lastModified = lastModified
    }

    /// Word count matching modern Windows 11 Notepad status bar behavior.
    public var wordCount: Int {
        let words = content.split { $0.isWhitespace || $0.isNewline }
        return words.count
    }

    /// Character count matching modern Windows 11 Notepad status bar behavior.
    public var characterCount: Int {
        content.count
    }

    /// Total line count in the buffer.
    public var lineCount: Int {
        guard !content.isEmpty else { return 1 }
        return content.components(separatedBy: .newlines).count
    }
}
