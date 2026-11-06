import Foundation

/// Identifies foldable code block ranges (startLine -> endLine) and token rules for syntax highlighting.
public struct FoldableBlock: Equatable, Identifiable {
    public var id: Int { startLine }
    public let startLine: Int
    public let endLine: Int
}

public struct SyntaxHighlighter {
    /// Detects foldable regions (brace blocks `{ ... }` and markdown sections) for gutter chevrons.
    public static func detectFoldableBlocks(in text: String) -> [FoldableBlock] {
        let lines = text.components(separatedBy: .newlines)
        var stack: [Int] = []
        var blocks: [FoldableBlock] = []

        for (index, line) in lines.enumerated() {
            let lineNum = index + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasSuffix("{") || trimmed.hasSuffix("[") {
                stack.append(lineNum)
            }
            if (trimmed.hasPrefix("}") || trimmed.hasPrefix("]")), let start = stack.popLast() {
                if lineNum > start + 1 {
                    blocks.append(FoldableBlock(startLine: start, endLine: lineNum))
                }
            }
        }
        return blocks.sorted { $0.startLine < $1.startLine }
    }

    /// Keyword list per language used by the native NSTextStorage syntax highlighter.
    public static func keywords(for language: SyntaxLanguage) -> [String] {
        switch language {
        case .swift:
            return ["import", "struct", "class", "enum", "protocol", "func", "var", "let", "if", "else", "guard", "switch", "case", "return", "public", "private", "async", "await", "try", "throws", "true", "false", "nil", "self"]
        case .python:
            return ["def", "class", "import", "from", "return", "if", "elif", "else", "for", "while", "in", "try", "except", "with", "as", "True", "False", "None", "async", "await", "self"]
        case .javascript:
            return ["import", "export", "from", "const", "let", "var", "function", "return", "if", "else", "for", "while", "switch", "case", "class", "async", "await", "true", "false", "null", "undefined"]
        case .sql:
            return ["SELECT", "FROM", "WHERE", "INSERT", "INTO", "UPDATE", "DELETE", "JOIN", "LEFT", "INNER", "GROUP", "BY", "ORDER", "LIMIT", "CREATE", "TABLE", "AS", "AND", "OR", "NULL"]
        case .bash:
            return ["if", "then", "else", "fi", "for", "do", "done", "case", "esac", "function", "export", "local", "return", "echo", "exit"]
        default:
            return []
        }
    }
}
