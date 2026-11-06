import Foundation

public enum FileServiceError: LocalizedError {
    case refusingToOverwriteRichDocument(String)
    case cannotEncode(String, DocumentEncoding)

    public var errorDescription: String? {
        switch self {
        case .refusingToOverwriteRichDocument(let name):
            return "\(name) is a formatted document. MacNotepad saves your edits as a new note instead of overwriting it."
        case .cannotEncode(let name, let encoding):
            return "\(name) contains characters that can't be saved as \(encoding.rawValue)."
        }
    }
}

/// Reads and writes plain-text files with encoding detection, and keeps rich documents
/// (.docx, .pdf, .rtf…) safe by importing them as Markdown notes instead of editing them in place.
public enum FileService {
    /// Formats that are opened by conversion and must never be overwritten with plain text.
    public static let richDocumentExtensions: Set<String> = ["docx", "doc", "rtf", "rtfd", "odt", "pdf", "pages", "webarchive"]

    public static func isRichDocument(_ url: URL) -> Bool {
        richDocumentExtensions.contains(url.pathExtension.lowercased())
    }

    public static func modificationDate(of url: URL) -> Date? {
        // Follow symlinks so changes to the real file are noticed.
        (try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path))?[.modificationDate] as? Date
    }

    // MARK: - Reading

    /// Detects the encoding of raw file bytes: BOM first, then strict UTF-8, then common legacy encodings.
    public static func detectEncoding(of data: Data) -> DocumentEncoding {
        let bytes = [UInt8](data.prefix(3))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8BOM }
        if bytes.starts(with: [0xFF, 0xFE]) { return .utf16 }
        if bytes.starts(with: [0xFE, 0xFF]) { return .utf16BE }
        if String(data: data, encoding: .utf8) != nil { return .utf8 }
        if looksLikeUTF16WithoutBOM(data) { return .utf16 }
        if String(data: data, encoding: .shiftJIS) != nil, data.contains(where: { $0 >= 0x81 && $0 <= 0x9F }) {
            return .shiftJIS
        }
        return .windows1252
    }

    private static func looksLikeUTF16WithoutBOM(_ data: Data) -> Bool {
        guard data.count >= 4, data.count % 2 == 0 else { return false }
        let sample = data.prefix(512)
        var zeroOddBytes = 0
        for (offset, byte) in sample.enumerated() where offset % 2 == 1 && byte == 0 { zeroOddBytes += 1 }
        return zeroOddBytes > sample.count / 4
    }

    public static func decode(_ data: Data, as encoding: DocumentEncoding) -> String? {
        let body = data.starts(with: encoding.byteOrderMark) ? data.dropFirst(encoding.byteOrderMark.count) : data[...]
        return String(data: Data(body), encoding: encoding.stringEncoding)
    }

    /// Opens any supported file as a tab. Rich documents become unsaved Markdown notes that remember their source.
    public static func openTab(at url: URL, forcedEncoding: DocumentEncoding? = nil) throws -> DocumentTab {
        if isRichDocument(url) {
            let markdown = try DocumentConverterService.importAsMarkdown(from: url)
            let base = url.deletingPathExtension().lastPathComponent
            return DocumentTab(
                title: "\(base).md",
                content: markdown,
                isDirty: true,
                language: .markdown,
                importedFrom: url
            )
        }

        let data = try Data(contentsOf: url)
        var encoding = forcedEncoding ?? detectEncoding(of: data)
        var decoded = decode(data, as: encoding)
        if decoded == nil, let latin = decode(data, as: .isoLatin1) {
            // Record the decoder that actually worked, so saving uses a matching encoding.
            decoded = latin
            encoding = .isoLatin1
        }
        guard let text = decoded else {
            throw DocumentConverterError.unreadableFile(url.lastPathComponent)
        }
        return DocumentTab(
            title: url.lastPathComponent,
            content: text.replacingOccurrences(of: "\r\n", with: "\n"),
            fileURL: url,
            isDirty: false,
            language: SyntaxLanguage.detect(from: url, content: text),
            lineEnding: LineEnding.detect(in: text),
            encoding: encoding,
            fileModificationDate: modificationDate(of: url)
        )
    }

    // MARK: - Writing

    /// Encodes tab content with its line ending and encoding (including BOM).
    public static func encodedData(for tab: DocumentTab) throws -> Data {
        let normalized = SessionManager.shared.normalizeLineEndings(tab.content, to: tab.lineEnding)
        guard let body = normalized.data(using: tab.encoding.stringEncoding, allowLossyConversion: false) else {
            throw FileServiceError.cannotEncode(tab.title, tab.encoding)
        }
        return Data(tab.encoding.byteOrderMark) + body
    }

    /// Writes a tab to `url`, refusing to clobber formatted documents with plain text.
    public static func write(_ tab: inout DocumentTab, to url: URL) throws {
        if isRichDocument(url) {
            throw FileServiceError.refusingToOverwriteRichDocument(url.lastPathComponent)
        }
        // Write through symlinks (e.g. dotfiles linked into a repo) instead of replacing the link.
        try encodedData(for: tab).write(to: url.resolvingSymlinksInPath(), options: .atomic)
        tab.fileURL = url
        tab.title = url.lastPathComponent
        tab.isDirty = false
        tab.lastModified = Date()
        tab.fileModificationDate = modificationDate(of: url)
        if tab.language == .plainText {
            tab.language = SyntaxLanguage.detect(from: url, content: tab.content)
        }
    }

    /// Picks a file name in `directory` that doesn't collide with an existing file ("note 2.md", …).
    public static func uniqueURL(in directory: URL, fileName: String) -> URL {
        let base = (fileName as NSString).deletingPathExtension
        let ext = (fileName as NSString).pathExtension
        var candidate = directory.appendingPathComponent(fileName)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = directory.appendingPathComponent(name)
            counter += 1
        }
        return candidate
    }
}
