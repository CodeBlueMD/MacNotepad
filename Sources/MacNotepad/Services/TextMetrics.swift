import Foundation

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
