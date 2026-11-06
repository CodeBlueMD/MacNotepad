import Foundation

/// Application appearance theme (Modern Windows 11 Notepad Mica + Notepad++ syntax themes).
public enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case darkMica = "Dark Mica"
    case lightMica = "Light Mica"
    case system = "System"

    public var id: String { rawValue }
}

/// Persisted user preferences including the ~/Documents/MacNotepad default save location.
public struct EditorPreferences: Codable, Equatable {
    public var defaultSaveDirectoryPath: String
    public var autoCreateDefaultSaveFolder: Bool
    public var persistentUnsavedTabs: Bool
    public var autoSaveIntervalSeconds: Int
    public var theme: AppTheme
    public var fontFamily: String
    public var fontSize: Double
    public var showLineNumbers: Bool
    public var enableCodeFolding: Bool
    public var enableColumnSelection: Bool
    public var wordWrap: Bool
    public var spellCheckEnabled: Bool
    public var zoomPercentage: Int

    public static func defaultSaveDirectoryURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return docs.appendingPathComponent("MacNotepad", isDirectory: true)
    }

    public init(
        defaultSaveDirectoryPath: String = EditorPreferences.defaultSaveDirectoryURL().path,
        autoCreateDefaultSaveFolder: Bool = true,
        persistentUnsavedTabs: Bool = true,
        autoSaveIntervalSeconds: Int = 3,
        theme: AppTheme = .darkMica,
        fontFamily: String = "SF Mono",
        fontSize: Double = 13.0,
        showLineNumbers: Bool = true,
        enableCodeFolding: Bool = true,
        enableColumnSelection: Bool = true,
        wordWrap: Bool = true,
        spellCheckEnabled: Bool = false,
        zoomPercentage: Int = 100
    ) {
        self.defaultSaveDirectoryPath = defaultSaveDirectoryPath
        self.autoCreateDefaultSaveFolder = autoCreateDefaultSaveFolder
        self.persistentUnsavedTabs = persistentUnsavedTabs
        self.autoSaveIntervalSeconds = autoSaveIntervalSeconds
        self.theme = theme
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.showLineNumbers = showLineNumbers
        self.enableCodeFolding = enableCodeFolding
        self.enableColumnSelection = enableColumnSelection
        self.wordWrap = wordWrap
        self.spellCheckEnabled = spellCheckEnabled
        self.zoomPercentage = zoomPercentage
    }
}

/// Manages session state ("Hot Exit" persistent unsaved tabs) and default ~/Documents/MacNotepad file operations.
public final class SessionManager {
    public static let shared = SessionManager()

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    /// Application support directory where unsaved tabs and preferences are persisted across launches.
    public var appSupportDirectoryURL: URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("MacNotepad", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    public var sessionFileURL: URL {
        appSupportDirectoryURL.appendingPathComponent("session-tabs.json")
    }

    public var preferencesFileURL: URL {
        appSupportDirectoryURL.appendingPathComponent("preferences.json")
    }

    /// Ensures the configured default save location under ~/Documents/MacNotepad exists.
    @discardableResult
    public func ensureDefaultSaveDirectory(preferences: EditorPreferences) -> URL {
        let expandedPath = NSString(string: preferences.defaultSaveDirectoryPath).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath, isDirectory: true)
        if preferences.autoCreateDefaultSaveFolder && !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    /// Quick-saves a tab directly into the default save directory (e.g., ~/Documents/MacNotepad/new 1.txt).
    public func quickSaveToDefaultDirectory(tab: inout DocumentTab, preferences: EditorPreferences) throws -> URL {
        let targetDir = ensureDefaultSaveDirectory(preferences: preferences)
        let targetURL: URL
        if let existingURL = tab.fileURL {
            targetURL = existingURL
        } else {
            let ext = tab.language.defaultFileExtension
            let sanitizedTitle = tab.title
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            let fileName = sanitizedTitle.contains(".") ? sanitizedTitle : "\(sanitizedTitle).\(ext)"
            targetURL = targetDir.appendingPathComponent(fileName)
        }

        let normalized = normalizeLineEndings(tab.content, to: tab.lineEnding)
        try normalized.write(to: targetURL, atomically: true, encoding: .utf8)
        tab.fileURL = targetURL
        tab.title = targetURL.lastPathComponent
        tab.isDirty = false
        tab.lastModified = Date()
        return targetURL
    }

    public func normalizeLineEndings(_ text: String, to lineEnding: LineEnding) -> String {
        let unixText = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        switch lineEnding {
        case .lf:
            return unixText
        case .crlf:
            return unixText.replacingOccurrences(of: "\n", with: "\r\n")
        }
    }

    /// Saves all open tabs (including unsaved scratch tabs) for instant restoration on next launch.
    public func saveSession(tabs: [DocumentTab]) {
        guard let data = try? encoder.encode(tabs) else { return }
        try? data.write(to: sessionFileURL, options: .atomic)
    }

    /// Restores previous session tabs, or creates initial starter tabs if launching fresh.
    public func loadSession() -> [DocumentTab] {
        if let data = try? Data(contentsOf: sessionFileURL),
           let decoded = try? decoder.decode([DocumentTab].self, from: data),
           !decoded.isEmpty {
            return decoded
        }
        return Self.defaultStarterTabs()
    }

    public func savePreferences(_ prefs: EditorPreferences) {
        guard let data = try? encoder.encode(prefs) else { return }
        try? data.write(to: preferencesFileURL, options: .atomic)
        ensureDefaultSaveDirectory(preferences: prefs)
    }

    public func loadPreferences() -> EditorPreferences {
        if let data = try? Data(contentsOf: preferencesFileURL),
           let decoded = try? decoder.decode(EditorPreferences.self, from: data) {
            ensureDefaultSaveDirectory(preferences: decoded)
            return decoded
        }
        let defaults = EditorPreferences()
        ensureDefaultSaveDirectory(preferences: defaults)
        return defaults
    }

    public static func defaultStarterTabs() -> [DocumentTab] {
        [
            DocumentTab(
                title: "welcome.md",
                content: """
                # Welcome to MacNotepad
                Modern Windows 11 Notepad design meets Notepad++ power — built natively for macOS.

                ## Highlights
                - **Persistent Unsaved Tabs (Hot Exit):** Close the app anytime; scratch tabs restore automatically.
                - **Default Save Location:** Pre-configured to `~/Documents/MacNotepad` (Cmd+S or Quick Save).
                - **Modern Floating Find & Replace:** Regex (`.*`), Match Case (`Aa`), Whole Word, & Find in Files.
                - **Side-by-Side Diff & Split View:** Compare any two open tabs with live line diffing.
                - **Developer Text Tools:** JSON/XML Formatter, Base64/URL Encode, Line Sort/Dedupe, & SHA-256.
                """,
                isDirty: false,
                language: .markdown
            ),
            DocumentTab(
                title: "config.json",
                content: """
                {
                  "appName": "MacNotepad",
                  "defaultSaveFolder": "~/Documents/MacNotepad",
                  "theme": "Dark Mica",
                  "features": {
                    "persistentUnsavedTabs": true,
                    "columnSelection": true,
                    "codeFolding": true,
                    "regexSearch": true
                  }
                }
                """,
                isDirty: true,
                language: .json
            ),
            DocumentTab(
                title: "new 1",
                content: "// Scratchpad tab (unsaved changes persist automatically across restarts)\nimport Foundation\n\nfunc greet(_ user: String) -> String {\n    return \"Hello, \\(user)! Saved by default to ~/Documents/MacNotepad\"\n}\n",
                isDirty: true,
                language: .swift
            )
        ]
    }
}
