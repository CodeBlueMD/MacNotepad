import Foundation

/// Token categories produced by the per-language highlighting rules.
public enum SyntaxTokenKind: CaseIterable {
    case function
    case type
    case keyword
    case literal
    case string
    case comment
}

public struct SyntaxHighlighter {
    /// Keyword list per language used by the native NSTextStorage syntax highlighter.
    public static func keywords(for language: SyntaxLanguage) -> [String] {
        switch language {
        case .swift:
            return ["import", "struct", "class", "enum", "protocol", "extension", "func", "var", "let", "if", "else", "guard", "switch", "case", "default", "for", "in", "while", "return", "public", "private", "internal", "static", "async", "await", "try", "throws", "true", "false", "nil", "self"]
        case .python:
            return ["def", "class", "import", "from", "return", "if", "elif", "else", "for", "while", "in", "try", "except", "with", "as", "True", "False", "None", "async", "await", "self"]
        case .javascript:
            return ["import", "export", "from", "const", "let", "var", "function", "return", "if", "else", "for", "while", "switch", "case", "class", "new", "async", "await", "true", "false", "null", "undefined"]
        case .sql:
            return ["SELECT", "FROM", "WHERE", "INSERT", "INTO", "UPDATE", "DELETE", "JOIN", "LEFT", "INNER", "GROUP", "BY", "ORDER", "LIMIT", "CREATE", "TABLE", "AS", "AND", "OR", "NULL"]
        case .bash:
            return ["if", "then", "else", "fi", "for", "do", "done", "case", "esac", "function", "export", "local", "return", "echo", "exit"]
        case .json:
            return ["true", "false", "null"]
        default:
            return []
        }
    }

    /// Single-line comment syntax for each language (nil when the language has none).
    static func commentPattern(for language: SyntaxLanguage) -> String? {
        switch language {
        case .swift, .javascript: return "//.*$"
        case .python, .bash: return "#.*$"
        case .sql: return "--.*$"
        case .css: return "/\\*.*?\\*/"
        case .html: return "<!--.*?-->"
        default: return nil
        }
    }

    /// Ordered highlighting rules for a language. Later rules win, so strings and comments come last;
    /// they share one regex so a `//` inside a string is never treated as a comment (and vice versa).
    static func rules(for language: SyntaxLanguage) -> [(kind: SyntaxTokenKind, regex: NSRegularExpression, group: Int)] {
        if let cached = cache.withLock({ $0[language] }) { return cached }

        var rules: [(SyntaxTokenKind, NSRegularExpression, Int)] = []
        func add(_ kind: SyntaxTokenKind, _ pattern: String, group: Int = 0, options: NSRegularExpression.Options = []) {
            if let regex = try? NSRegularExpression(pattern: pattern, options: options) {
                rules.append((kind, regex, group))
            }
        }

        let isCode = language != .plainText && language != .markdown
        if isCode && language != .json && language != .html {
            add(.function, "\\b([A-Za-z_][A-Za-z0-9_]*)(?=\\s*\\()", group: 1)
            add(.type, "\\b[A-Z][A-Za-z0-9_]*\\b")
        }
        let words = keywords(for: language)
        if !words.isEmpty {
            add(.keyword, "\\b(?:" + words.joined(separator: "|") + ")\\b",
                options: language == .sql ? [.caseInsensitive] : [])
        }
        if isCode {
            add(.literal, "\\b\\d+(?:\\.\\d+)?\\b")

            let singleQuoted = language != .swift && language != .json
            var alternatives = ["\"(?:[^\"\\\\\\n]|\\\\.)*\""]
            if singleQuoted { alternatives.append("'(?:[^'\\\\\\n]|\\\\.)*'") }
            if let comment = commentPattern(for: language) {
                alternatives.append("(" + comment + ")")
            }
            add(.string, alternatives.joined(separator: "|"), options: [.anchorsMatchLines])
        }

        cache.withLock { $0[language] = rules }
        return rules
    }

    /// Runs the language rules over `range` of `text` and reports each token.
    /// Comment matches arrive from the combined string/comment rule and are reported as `.comment`.
    public static func tokens(in text: String, range: NSRange, language: SyntaxLanguage,
                              _ body: (SyntaxTokenKind, NSRange) -> Void) {
        for rule in rules(for: language) {
            rule.regex.enumerateMatches(in: text, range: range) { match, _, _ in
                guard let match else { return }
                if rule.kind == .string, match.numberOfRanges > 1, match.range(at: 1).location != NSNotFound {
                    body(.comment, match.range(at: 1))
                } else {
                    body(rule.kind, match.range(at: rule.group))
                }
            }
        }
    }

    private static let cache = Locked<[SyntaxLanguage: [(kind: SyntaxTokenKind, regex: NSRegularExpression, group: Int)]]>([:])
}

/// Fast line/column lookups on UTF-16 text without splitting the whole string.
public enum TextMetrics {
    /// 1-based line number of the given UTF-16 location (counts `\n`).
    public static func lineNumber(at location: Int, in text: NSString) -> Int {
        let end = min(max(0, location), text.length)
        var count = 1
        var buffer = [unichar](repeating: 0, count: 4096)
        var position = 0
        while position < end {
            let chunk = min(buffer.count, end - position)
            text.getCharacters(&buffer, range: NSRange(location: position, length: chunk))
            for i in 0..<chunk where buffer[i] == 0x0A { count += 1 }
            position += chunk
        }
        return count
    }

    /// 1-based (line, column) of the given UTF-16 location.
    public static func lineAndColumn(at location: Int, in text: NSString) -> (line: Int, column: Int) {
        let safe = min(max(0, location), text.length)
        let previousNewline = text.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: safe))
        let lineStart = previousNewline.location == NSNotFound ? 0 : previousNewline.location + 1
        return (lineNumber(at: safe, in: text), safe - lineStart + 1)
    }
}

/// Minimal lock wrapper for the shared regex cache.
final class Locked<Value> {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
