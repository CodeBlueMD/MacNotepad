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

    /// The ending used by most lines, so one stray CRLF doesn't convert a whole LF file.
    public static func detect(in text: String) -> LineEnding {
        let crlf = text.components(separatedBy: "\r\n").count - 1
        guard crlf > 0 else { return .lf }
        let lf = text.components(separatedBy: "\n").count - 1 - crlf
        return crlf >= lf ? .crlf : .lf
    }
}

/// Text encodings MacNotepad can detect, reopen with, and convert to.
public enum DocumentEncoding: String, Codable, CaseIterable, Identifiable {
    case utf8 = "UTF-8"
    case utf8BOM = "UTF-8 with BOM"
    case utf16 = "UTF-16"
    case utf16BE = "UTF-16 BE"
    case windows1252 = "Windows-1252"
    case isoLatin1 = "ISO-8859-1"
    case macRoman = "Mac Roman"
    case shiftJIS = "Shift JIS"
    case ascii = "ASCII"

    public var id: String { rawValue }

    public var stringEncoding: String.Encoding {
        switch self {
        case .utf8, .utf8BOM: return .utf8
        case .utf16: return .utf16LittleEndian
        case .utf16BE: return .utf16BigEndian
        case .windows1252: return .windowsCP1252
        case .isoLatin1: return .isoLatin1
        case .macRoman: return .macOSRoman
        case .shiftJIS: return .shiftJIS
        case .ascii: return .ascii
        }
    }

    /// Byte-order mark written before the text, if any.
    public var byteOrderMark: [UInt8] {
        switch self {
        case .utf8BOM: return [0xEF, 0xBB, 0xBF]
        case .utf16: return [0xFF, 0xFE]
        case .utf16BE: return [0xFE, 0xFF]
        default: return []
        }
    }
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
    public var lastModified: Date
    /// Original file this tab was converted from (e.g. a .docx). Saving never writes back to it.
    public var importedFrom: URL?
    /// Modification date of `fileURL` when it was last read or written, used to detect outside changes.
    public var fileModificationDate: Date?
    /// True when the session file stores no copy of `content` because the saved file on disk is identical.
    public var contentStoredOnDisk: Bool?
    /// Library folder a new note should be saved into on its first ⌘S.
    public var pendingFolder: URL?

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
        lastModified: Date = Date(),
        importedFrom: URL? = nil,
        fileModificationDate: Date? = nil
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
        self.lastModified = lastModified
        self.importedFrom = importedFrom
        self.fileModificationDate = fileModificationDate
    }

    /// Display name without extension, used for notes and exports.
    public var baseName: String {
        let name = (title as NSString).deletingPathExtension
        return name.isEmpty ? title : name
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
        TextMetrics.lineNumber(at: (content as NSString).length, in: content as NSString)
    }
}
