import Foundation

public enum DiffLineKind: String, Equatable {
    case unchanged
    case added
    case removed
    case modified
}

public struct DiffRow: Identifiable, Equatable {
    public let id = UUID()
    public let leftLineNumber: Int?
    public let rightLineNumber: Int?
    public let leftText: String
    public let rightText: String
    public let kind: DiffLineKind
}

public struct DiffSummary: Equatable {
    public let additions: Int
    public let removals: Int
    public let modifications: Int
    public let unchanged: Int
}

/// Side-by-side diff engine for MacNotepad's Compare mode.
public struct DiffEngine {
    public static func compare(left: String, right: String) -> (rows: [DiffRow], summary: DiffSummary) {
        let leftLines = left.isEmpty ? [] : left.components(separatedBy: .newlines)
        let rightLines = right.isEmpty ? [] : right.components(separatedBy: .newlines)

        // Compute LCS table for accurate line alignment
        let m = leftLines.count
        let n = rightLines.count
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)

        if m > 0 && n > 0 {
            for i in stride(from: m - 1, through: 0, by: -1) {
                for j in stride(from: n - 1, through: 0, by: -1) {
                    if leftLines[i] == rightLines[j] {
                        dp[i][j] = 1 + dp[i + 1][j + 1]
                    } else {
                        dp[i][j] = max(dp[i + 1][j], dp[i][j + 1])
                    }
                }
            }
        }

        var rows: [DiffRow] = []
        var additions = 0
        var removals = 0
        var modifications = 0
        var unchanged = 0

        var i = 0
        var j = 0
        while i < m || j < n {
            if i < m && j < n && leftLines[i] == rightLines[j] {
                rows.append(
                    DiffRow(
                        leftLineNumber: i + 1,
                        rightLineNumber: j + 1,
                        leftText: leftLines[i],
                        rightText: rightLines[j],
                        kind: .unchanged
                    )
                )
                unchanged += 1
                i += 1
                j += 1
            } else if i < m && j < n && dp[i + 1][j] == dp[i][j + 1] {
                rows.append(
                    DiffRow(
                        leftLineNumber: i + 1,
                        rightLineNumber: j + 1,
                        leftText: leftLines[i],
                        rightText: rightLines[j],
                        kind: .modified
                    )
                )
                modifications += 1
                i += 1
                j += 1
            } else if j < n && (i == m || dp[i][j + 1] >= dp[i + 1][j]) {
                rows.append(
                    DiffRow(
                        leftLineNumber: nil,
                        rightLineNumber: j + 1,
                        leftText: "",
                        rightText: rightLines[j],
                        kind: .added
                    )
                )
                additions += 1
                j += 1
            } else if i < m {
                rows.append(
                    DiffRow(
                        leftLineNumber: i + 1,
                        rightLineNumber: nil,
                        leftText: leftLines[i],
                        rightText: "",
                        kind: .removed
                    )
                )
                removals += 1
                i += 1
            }
        }

        let summary = DiffSummary(
            additions: additions,
            removals: removals,
            modifications: modifications,
            unchanged: unchanged
        )
        return (rows, summary)
    }
}
