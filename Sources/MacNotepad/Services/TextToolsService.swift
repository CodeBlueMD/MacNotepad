import Foundation
import CryptoKit

/// Built-in Notepad++ style developer text manipulation and formatting tools.
public enum TextToolAction: String, CaseIterable, Identifiable {
    case jsonPrettyPrint = "JSON Pretty Print"
    case jsonMinify = "JSON Minify"
    case xmlPrettyPrint = "XML / HTML Pretty Print"
    case base64Encode = "Base64 Encode"
    case base64Decode = "Base64 Decode"
    case urlEncode = "URL Encode"
    case urlDecode = "URL Decode"
    case sortLinesAZ = "Sort Lines (A → Z)"
    case sortLinesZA = "Sort Lines (Z → A)"
    case sortLinesByLength = "Sort Lines by Length"
    case deduplicateLines = "Remove Duplicate Lines"
    case removeEmptyLines = "Remove Empty Lines"
    case trimTrailingWhitespace = "Trim Trailing Whitespace"
    case uppercase = "UPPERCASE"
    case lowercase = "lowercase"
    case titleCase = "Title Case"
    case sha256Hash = "Generate SHA-256 Hash"

    public var id: String { rawValue }
}

public enum TextToolsError: LocalizedError {
    case invalidJSON
    case invalidBase64
    case invalidURLEncoding

    public var errorDescription: String? {
        switch self {
        case .invalidJSON:
            return "The current text is not valid JSON."
        case .invalidBase64:
            return "The current text is not a valid Base64 encoded string."
        case .invalidURLEncoding:
            return "Could not decode percent-encoded URL string."
        }
    }
}

public struct TextToolsService {
    public static func apply(_ action: TextToolAction, to input: String) throws -> String {
        switch action {
        case .jsonPrettyPrint:
            guard let data = input.data(using: .utf8),
                  let jsonObject = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  let prettyData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys]),
                  let result = String(data: prettyData, encoding: .utf8) else {
                throw TextToolsError.invalidJSON
            }
            return result

        case .jsonMinify:
            guard let data = input.data(using: .utf8),
                  let jsonObject = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  let minifiedData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.sortedKeys]),
                  let result = String(data: minifiedData, encoding: .utf8) else {
                throw TextToolsError.invalidJSON
            }
            return result

        case .xmlPrettyPrint:
            return formatXMLOrHTML(input)

        case .base64Encode:
            return Data(input.utf8).base64EncodedString()

        case .base64Decode:
            guard let data = Data(base64Encoded: input.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let decoded = String(data: data, encoding: .utf8) else {
                throw TextToolsError.invalidBase64
            }
            return decoded

        case .urlEncode:
            return input.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? input

        case .urlDecode:
            guard let decoded = input.removingPercentEncoding else {
                throw TextToolsError.invalidURLEncoding
            }
            return decoded

        case .sortLinesAZ:
            return input
                .components(separatedBy: .newlines)
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                .joined(separator: "\n")

        case .sortLinesZA:
            return input
                .components(separatedBy: .newlines)
                .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedDescending }
                .joined(separator: "\n")

        case .sortLinesByLength:
            return input
                .components(separatedBy: .newlines)
                .sorted { $0.count < $1.count }
                .joined(separator: "\n")

        case .deduplicateLines:
            var seen = Set<String>()
            var unique: [String] = []
            for line in input.components(separatedBy: .newlines) {
                if seen.insert(line).inserted {
                    unique.append(line)
                }
            }
            return unique.joined(separator: "\n")

        case .removeEmptyLines:
            return input
                .components(separatedBy: .newlines)
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .joined(separator: "\n")

        case .trimTrailingWhitespace:
            return input
                .components(separatedBy: .newlines)
                .map { line in
                    line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
                }
                .joined(separator: "\n")

        case .uppercase:
            return input.uppercased()

        case .lowercase:
            return input.lowercased()

        case .titleCase:
            return input.capitalized

        case .sha256Hash:
            let digest = SHA256.hash(data: Data(input.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }
    }

    private static func formatXMLOrHTML(_ raw: String) -> String {
        let singleLine = raw
            .replacingOccurrences(of: ">\\s+<", with: "><", options: .regularExpression)
            .replacingOccurrences(of: "><", with: ">\n<")
        let lines = singleLine.components(separatedBy: .newlines)
        var indent = 0
        var formatted: [String] = []

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("</") {
                indent = max(0, indent - 1)
            }
            let padding = String(repeating: "  ", count: indent)
            formatted.append(padding + line)

            if line.hasPrefix("<")
                && !line.hasPrefix("</")
                && !line.hasPrefix("<?")
                && !line.hasPrefix("<!")
                && !line.hasSuffix("/>")
                && !line.contains("</") {
                indent += 1
            }
        }
        return formatted.joined(separator: "\n")
    }
}
