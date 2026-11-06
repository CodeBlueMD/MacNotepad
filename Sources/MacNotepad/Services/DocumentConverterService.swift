import Foundation
import AppKit
import PDFKit

/// Supported document export and conversion formats in MacNotepad.
public enum ExportDocumentFormat: String, CaseIterable, Identifiable {
    case pdf = "PDF Document (.pdf)"
    case docx = "Word Document (.docx)"
    case rtf = "Rich Text Format (.rtf)"
    case html = "HTML Web Page (.html)"
    case markdown = "Markdown (.md)"
    case txt = "Plain Text (.txt)"
    case doc = "Word 97–2004 (.doc)"

    public var id: String { rawValue }

    public var fileExtension: String {
        switch self {
        case .pdf: return "pdf"
        case .docx: return "docx"
        case .rtf: return "rtf"
        case .html: return "html"
        case .markdown: return "md"
        case .txt: return "txt"
        case .doc: return "doc"
        }
    }

    public var iconName: String {
        switch self {
        case .pdf: return "doc.richtext"
        case .docx, .doc: return "doc.text.fill"
        case .rtf: return "doc.append"
        case .html: return "globe"
        case .markdown: return "text.badge.checkmark"
        case .txt: return "doc.plaintext"
        }
    }
}

public enum DocumentConverterError: LocalizedError {
    case unreadableFile(String)
    case exportFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unreadableFile(let name):
            return "Could not read text from \(name)."
        case .exportFailed(let reason):
            return "Conversion failed: \(reason)"
        }
    }
}

/// Native macOS service for opening and converting .docx, .pdf, .rtf, .doc, .html, .md, and .txt files.
public struct DocumentConverterService {

    /// Opens any supported file (.pdf, .docx, .doc, .rtf, .html, .md, .txt, source code) and extracts its text content.
    public static func readDocumentContent(from url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "pdf":
            return try extractTextFromPDF(url: url)

        case "docx", "doc", "rtf", "odt":
            return try extractTextFromRichDocument(url: url)

        default:
            if let utf8Text = try? String(contentsOf: url, encoding: .utf8) {
                return utf8Text
            }
            if let utf16Text = try? String(contentsOf: url, encoding: .utf16) {
                return utf16Text
            }
            if let latinText = try? String(contentsOf: url, encoding: .isoLatin1) {
                return latinText
            }
            return try extractTextFromRichDocument(url: url)
        }
    }

    /// Imports a document as Markdown for editing as a note. Word/RTF/ODT formatting (headings, bold,
    /// italic, lists, tables, links) is carried over; PDFs contribute their text. The source file is never modified.
    public static func importAsMarkdown(from url: URL) throws -> String {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            return try extractTextFromPDF(url: url)
        }
        if ext == "docx", let markdown = DocxImporter.markdown(from: url) {
            return markdown
        }
        // textutil's HTML keeps Word lists and tables, which AppKit's direct .docx reader flattens.
        if ext != "rtf", let html = runTextUtil(["-convert", "html", "-stdout", url.path]),
           let attributed = try? NSAttributedString(
               data: html,
               options: [.documentType: NSAttributedString.DocumentType.html,
                         .characterEncoding: String.Encoding.utf8.rawValue],
               documentAttributes: nil) {
            return MarkdownService.markdown(from: attributed)
        }
        if let attributed = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) {
            return MarkdownService.markdown(from: attributed)
        }
        return try extractTextFromRichDocument(url: url)
    }

    private static func runTextUtil(_ arguments: [String]) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 && !data.isEmpty ? data : nil
    }

    /// Extracts text from all pages of a PDF using macOS PDFKit.
    public static func extractTextFromPDF(url: URL) throws -> String {
        guard let pdf = PDFDocument(url: url) else {
            throw DocumentConverterError.unreadableFile(url.lastPathComponent)
        }
        var pagesText: [String] = []
        for i in 0..<pdf.pageCount {
            if let page = pdf.page(at: i), let pageStr = page.string, !pageStr.isEmpty {
                if pdf.pageCount > 1 {
                    pagesText.append("--- Page \(i + 1) ---\n\(pageStr)")
                } else {
                    pagesText.append(pageStr)
                }
            }
        }
        return pagesText.joined(separator: "\n\n")
    }

    /// Extracts text from .docx, .doc, .rtf, or .odt using NSAttributedString or macOS textutil.
    public static func extractTextFromRichDocument(url: URL) throws -> String {
        if let attrString = try? NSAttributedString(url: url, options: [:], documentAttributes: nil) {
            return attrString.string
        }

        // Fallback to macOS built-in /usr/bin/textutil for complex Word .docx files
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", "txt", "-stdout", url.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus == 0, let text = String(data: data, encoding: .utf8) {
            return text
        }

        throw DocumentConverterError.unreadableFile(url.lastPathComponent)
    }

    /// Converts and exports a text buffer into .pdf, .docx, .rtf, .html, .md, .txt, or .doc.
    public static func export(
        content: String,
        title: String,
        to destinationURL: URL,
        format: ExportDocumentFormat,
        fontFamily: String = "SF Mono",
        fontSize: Double = 13.0,
        isMarkdown: Bool = false
    ) throws {
        if isMarkdown, try exportMarkdown(content: content, title: title, to: destinationURL, format: format) {
            return
        }
        switch format {
        case .txt, .markdown:
            try content.write(to: destinationURL, atomically: true, encoding: .utf8)

        case .html:
            let escaped = content
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            let htmlDoc = """
            <!DOCTYPE html>
            <html>
            <head>
            <meta charset="utf-8">
            <title>\(title)</title>
            <style>
              body { font-family: '\(fontFamily)', -apple-system, monospace; font-size: \(Int(fontSize))pt; line-height: 1.5; margin: 36px; color: #1a1a1a; }
              pre { white-space: pre-wrap; word-wrap: break-word; font-family: inherit; }
            </style>
            </head>
            <body>
            <pre>\(escaped)</pre>
            </body>
            </html>
            """
            try htmlDoc.write(to: destinationURL, atomically: true, encoding: .utf8)

        case .rtf:
            let attrString = makeAttributedString(content: content, fontFamily: fontFamily, fontSize: fontSize)
            let range = NSRange(location: 0, length: attrString.length)
            let data = try attrString.data(
                from: range,
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
            )
            try data.write(to: destinationURL, options: .atomic)

        case .docx:
            try exportRichFormatViaTextUtilOrAppKit(
                content: content,
                to: destinationURL,
                textUtilFormat: "docx",
                docType: .officeOpenXML,
                fontFamily: fontFamily,
                fontSize: fontSize
            )

        case .doc:
            try exportRichFormatViaTextUtilOrAppKit(
                content: content,
                to: destinationURL,
                textUtilFormat: "doc",
                docType: .docFormat,
                fontFamily: fontFamily,
                fontSize: fontSize
            )

        case .pdf:
            try renderMultiPagePDF(
                content: content,
                to: destinationURL,
                fontFamily: fontFamily,
                fontSize: fontSize
            )
        }
    }

    /// Markdown notes export with real formatting (headings, lists, tables, links) instead of monospaced text.
    /// Returns false for formats that should fall back to the plain-text exporters.
    private static func exportMarkdown(content: String, title: String, to url: URL, format: ExportDocumentFormat) throws -> Bool {
        switch format {
        case .html:
            try MarkdownService.htmlDocument(from: content, title: title).write(to: url, atomically: true, encoding: .utf8)
            return true
        case .docx:
            try DocxExporter.write(markdown: content, title: title, to: url)
            return true
        case .doc, .rtf, .pdf:
            guard let attributed = MarkdownService.attributedString(from: content, title: title) else { return false }
            let range = NSRange(location: 0, length: attributed.length)
            switch format {
            case .doc:
                try attributed.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.docFormat])
                    .write(to: url, options: .atomic)
            case .rtf:
                try attributed.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
                    .write(to: url, options: .atomic)
            default:
                try renderAttributedPDF(attributed, to: url)
            }
            return true
        default:
            return false
        }
    }

    private static func renderAttributedPDF(_ attributed: NSAttributedString, to url: URL) throws {
        let pageSize = CGSize(width: 612, height: 792)
        let margin: CGFloat = 54
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw DocumentConverterError.exportFailed("Unable to initialize PDF graphics context")
        }
        let framesetter = CTFramesetterCreateWithAttributedString(attributed as CFAttributedString)
        var index = 0
        repeat {
            context.beginPDFPage(nil)
            let path = CGPath(rect: CGRect(x: margin, y: margin, width: pageSize.width - margin * 2,
                                           height: pageSize.height - margin * 2), transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(index, 0), path, nil)
            CTFrameDraw(frame, context)
            let visible = CTFrameGetVisibleStringRange(frame)
            context.endPDFPage()
            if visible.length == 0 { break }
            index += visible.length
        } while index < attributed.length
        context.closePDF()
    }

    private static func makeAttributedString(content: String, fontFamily: String, fontSize: Double) -> NSAttributedString {
        let font = NSFont(name: fontFamily, size: CGFloat(fontSize))
            ?? NSFont.systemFont(ofSize: CGFloat(fontSize))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3.0
        return NSAttributedString(
            string: content,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.black,
                .paragraphStyle: paragraph
            ]
        )
    }

    private static func exportRichFormatViaTextUtilOrAppKit(
        content: String,
        to destinationURL: URL,
        textUtilFormat: String,
        docType: NSAttributedString.DocumentType,
        fontFamily: String,
        fontSize: Double
    ) throws {
        let attrString = makeAttributedString(content: content, fontFamily: fontFamily, fontSize: fontSize)
        let fullRange = NSRange(location: 0, length: attrString.length)

        // Try native NSAttributedString writer first
        if let data = try? attrString.data(from: fullRange, documentAttributes: [.documentType: docType]) {
            try data.write(to: destinationURL, options: .atomic)
            return
        }

        // Fallback to macOS /usr/bin/textutil via temporary RTF so formatting is preserved
        let tempRTF = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".rtf")
        defer { try? FileManager.default.removeItem(at: tempRTF) }
        let rtfData = try attrString.data(from: fullRange, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        try rtfData.write(to: tempRTF, options: .atomic)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/textutil")
        process.arguments = ["-convert", textUtilFormat, tempRTF.path, "-output", destinationURL.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw DocumentConverterError.exportFailed("Could not create .\(textUtilFormat) file")
        }
    }

    /// Generates a clean, multi-page vector PDF from the document text using CoreText & CoreGraphics.
    private static func renderMultiPagePDF(
        content: String,
        to destinationURL: URL,
        fontFamily: String,
        fontSize: Double
    ) throws {
        let pageWidth: CGFloat = 612.0   // US Letter 8.5"
        let pageHeight: CGFloat = 792.0  // US Letter 11"
        let margin: CGFloat = 48.0
        var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        guard let consumer = CGDataConsumer(url: destinationURL as CFURL),
              let pdfContext = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw DocumentConverterError.exportFailed("Unable to initialize PDF graphics context")
        }

        let attrString = makeAttributedString(
            content: content.isEmpty ? " " : content,
            fontFamily: fontFamily,
            fontSize: fontSize
        )
        let framesetter = CTFramesetterCreateWithAttributedString(attrString as CFAttributedString)
        let textLength = attrString.length
        var currentIndex = 0

        while currentIndex < textLength {
            pdfContext.beginPDFPage(nil)
            let printableRect = CGRect(
                x: margin,
                y: margin,
                width: pageWidth - (margin * 2),
                height: pageHeight - (margin * 2)
            )
            let path = CGPath(rect: printableRect, transform: nil)
            let frame = CTFramesetterCreateFrame(
                framesetter,
                CFRangeMake(currentIndex, 0),
                path,
                nil
            )
            CTFrameDraw(frame, pdfContext)
            let visibleRange = CTFrameGetVisibleStringRange(frame)
            pdfContext.endPDFPage()

            if visibleRange.length == 0 {
                break
            }
            currentIndex += visibleRange.length
        }

        pdfContext.closePDF()
    }
}
