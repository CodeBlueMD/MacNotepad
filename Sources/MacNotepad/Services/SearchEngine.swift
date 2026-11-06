import Foundation

/// Options for modern Find & Replace and multi-file search.
public struct SearchOptions: Equatable {
    public var query: String = ""
    public var replacement: String = ""
    public var useRegex: Bool = false
    public var matchCase: Bool = false
    public var wholeWord: Bool = false

    public init(
        query: String = "",
        replacement: String = "",
        useRegex: Bool = false,
        matchCase: Bool = false,
        wholeWord: Bool = false
    ) {
        self.query = query
        self.replacement = replacement
        self.useRegex = useRegex
        self.matchCase = matchCase
        self.wholeWord = wholeWord
    }
}

public struct SearchMatch: Identifiable, Equatable {
    public let id = UUID()
    public let range: NSRange
    public let matchedText: String
    public let lineNumber: Int
    public let linePreview: String
    public let fileURL: URL?
}

public struct SearchEngine {
    /// Builds an NSRegularExpression honoring Regex, Match Case, and Whole Word toggles.
    public static func makeRegex(options: SearchOptions) throws -> NSRegularExpression? {
        guard !options.query.isEmpty else { return nil }
        var pattern = options.useRegex
            ? options.query
            : NSRegularExpression.escapedPattern(for: options.query)

        if options.wholeWord {
            pattern = "\\b(?:\(pattern))\\b"
        }

        var regexOptions: NSRegularExpression.Options = [.anchorsMatchLines]
        if !options.matchCase {
            regexOptions.insert(.caseInsensitive)
        }
        return try NSRegularExpression(pattern: pattern, options: regexOptions)
    }

    /// Finds all matches inside a text buffer with 1-indexed line numbers and previews.
    public static func findMatches(in text: String, options: SearchOptions, fileURL: URL? = nil) -> [SearchMatch] {
        guard let regex = try? makeRegex(options: options) else { return [] }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let rawMatches = regex.matches(in: text, options: [], range: fullRange)

        return rawMatches.map { result in
            let prefix = nsText.substring(to: result.range.location)
            let lineNum = prefix.components(separatedBy: .newlines).count
            let lineRange = nsText.lineRange(for: result.range)
            let preview = nsText.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
            return SearchMatch(
                range: result.range,
                matchedText: nsText.substring(with: result.range),
                lineNumber: lineNum,
                linePreview: preview,
                fileURL: fileURL
            )
        }
    }

    /// Replaces all matches in the text buffer (supports regex capture groups like $1, $2).
    public static func replaceAll(in text: String, options: SearchOptions) -> (updatedText: String, replacementsCount: Int) {
        guard let regex = try? makeRegex(options: options) else { return (text, 0) }
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        let count = regex.numberOfMatches(in: text, options: [], range: fullRange)
        guard count > 0 else { return (text, 0) }

        let replacementTemplate = options.useRegex
            ? options.replacement
            : NSRegularExpression.escapedTemplate(for: options.replacement)

        let updated = regex.stringByReplacingMatches(
            in: text,
            options: [],
            range: fullRange,
            withTemplate: replacementTemplate
        )
        return (updated, count)
    }

    /// Notepad++ style "Find in Files" across a directory.
    public static func findInFiles(directoryURL: URL, options: SearchOptions) -> [SearchMatch] {
        guard !options.query.isEmpty else { return [] }
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var results: [SearchMatch] = []
        for case let fileURL as URL in enumerator {
            guard (try? fileURL.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                  let content = try? String(contentsOf: fileURL, encoding: .utf8) else {
                continue
            }
            let fileMatches = findMatches(in: content, options: options, fileURL: fileURL)
            results.append(contentsOf: fileMatches)
        }
        return results
    }
}
