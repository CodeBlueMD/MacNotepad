import Foundation

/// A collapsible region: `startLine` stays visible and `hiddenRange` (UTF-16) is hidden when folded.
public struct FoldRegion: Equatable {
    public let startLine: Int
    public let hiddenRange: NSRange
}

/// Finds foldable regions: `{…}` / `[…]` blocks, Python-style indented blocks, and Markdown heading sections.
public enum FoldingService {
    public static func regions(in text: String, language: SyntaxLanguage) -> [FoldRegion] {
        let ns = text as NSString
        guard ns.length > 0, ns.length < 5_000_000 else { return [] }
        var lineStarts: [Int] = [0]
        var lineEnds: [Int] = [] // index of "\n" (or length) for each line
        var position = 0
        while position < ns.length {
            let newline = ns.range(of: "\n", range: NSRange(location: position, length: ns.length - position))
            if newline.location == NSNotFound { break }
            lineEnds.append(newline.location)
            position = newline.location + 1
            lineStarts.append(position)
        }
        lineEnds.append(ns.length)
        let lineCount = lineStarts.count

        func line(_ i: Int) -> String { ns.substring(with: NSRange(location: lineStarts[i], length: lineEnds[i] - lineStarts[i])) }

        switch language {
        case .markdown:
            return markdownRegions(lineCount: lineCount, line: line, lineStarts: lineStarts, lineEnds: lineEnds)
        case .python:
            return indentRegions(lineCount: lineCount, line: line, lineEnds: lineEnds)
        case .plainText:
            return []
        default:
            return bracketRegions(ns: ns, lineStarts: lineStarts, lineEnds: lineEnds)
        }
    }

    /// `{` or `[` at the end of a line, matched by a line starting with `}` / `]`: hides everything
    /// between them, so the folded line reads `func run() {⋯}`.
    private static func bracketRegions(ns: NSString, lineStarts: [Int], lineEnds: [Int]) -> [FoldRegion] {
        var stack: [(line: Int, char: unichar)] = []
        var regions: [FoldRegion] = []
        for i in 0..<lineStarts.count {
            let range = NSRange(location: lineStarts[i], length: lineEnds[i] - lineStarts[i])
            let trimmed = ns.substring(with: range).trimmingCharacters(in: .whitespaces)
            if let first = trimmed.utf16.first, first == 0x7D || first == 0x5D, let open = stack.last {
                let expected: unichar = first == 0x7D ? 0x7B : 0x5B
                if open.char == expected {
                    stack.removeLast()
                    if i > open.line + 1 {
                        let closingOffset = ns.substring(with: range).utf16.prefix { $0 == 0x20 || $0 == 0x09 }.count
                        let start = lineEnds[open.line]
                        let end = lineStarts[i] + closingOffset
                        regions.append(FoldRegion(startLine: open.line + 1, hiddenRange: NSRange(location: start, length: end - start)))
                    }
                }
            }
            if let last = trimmed.utf16.last, last == 0x7B || last == 0x5B {
                stack.append((i, last))
            }
        }
        return regions.sorted { $0.startLine < $1.startLine }
    }

    /// Lines ending in `:` followed by more-indented lines.
    private static func indentRegions(lineCount: Int, line: (Int) -> String, lineEnds: [Int]) -> [FoldRegion] {
        func indent(_ s: String) -> Int? {
            guard !s.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return s.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        }
        var regions: [FoldRegion] = []
        for i in 0..<lineCount {
            let text = line(i)
            guard text.trimmingCharacters(in: .whitespaces).hasSuffix(":"), let base = indent(text) else { continue }
            var last = i
            var j = i + 1
            while j < lineCount {
                if let ind = indent(line(j)) {
                    if ind <= base { break }
                    last = j
                }
                j += 1
            }
            if last > i {
                regions.append(FoldRegion(startLine: i + 1, hiddenRange: NSRange(location: lineEnds[i], length: lineEnds[last] - lineEnds[i])))
            }
        }
        return regions
    }

    /// A heading folds everything up to the next heading of the same or higher level.
    private static func markdownRegions(lineCount: Int, line: (Int) -> String, lineStarts: [Int], lineEnds: [Int]) -> [FoldRegion] {
        var headings: [(line: Int, level: Int)] = []
        var inFence = false
        for i in 0..<lineCount {
            let text = line(i)
            if text.hasPrefix("```") { inFence.toggle(); continue }
            if !inFence, let heading = MarkdownService.headingLevel(of: text) { headings.append((i, heading.level)) }
        }
        var regions: [FoldRegion] = []
        for (k, heading) in headings.enumerated() {
            var endLine = lineCount - 1
            for next in headings[(k + 1)...] where next.level <= heading.level {
                endLine = next.line - 1
                break
            }
            // Don't swallow the blank line(s) separating this section from the next heading.
            while endLine > heading.line, line(endLine).trimmingCharacters(in: .whitespaces).isEmpty { endLine -= 1 }
            if endLine > heading.line {
                let start = lineEnds[heading.line]
                regions.append(FoldRegion(startLine: heading.line + 1, hiddenRange: NSRange(location: start, length: lineEnds[endLine] - start)))
            }
        }
        return regions
    }
}
