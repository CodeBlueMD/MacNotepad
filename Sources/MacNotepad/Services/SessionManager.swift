import Foundation

/// Application appearance theme (Modern Windows 11 Notepad Mica + Notepad++ syntax themes).
public enum AppTheme: String, Codable, CaseIterable, Identifiable {
    case darkMica = "Dark Mica"
    case light = "Light"
    case dark = "Dark"
    case system = "System"

    public var id: String { rawValue }

    /// Backward-compatible decoding so old "Light Mica" maps cleanly.
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = (try? container.decode(String.self)) ?? "Dark Mica"
        switch raw {
        case "Light Mica", "Light": self = .light
        case "Dark": self = .dark
        case "System": self = .system
        default: self = .darkMica
        }
    }
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
        wordWrap: Bool = false,
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
                title: "release-notes.md",
                content: """
                # MacNotepad — Release Notes
                Modern Windows 11 Notepad design meets Notepad++ power — built natively for macOS.

                ## Key Features
                - **Persistent Unsaved Tabs (Hot Exit):** Scratch tabs are never lost on application close.
                - **Default Save Location:** Pre-configured to `~/Documents/MacNotepad` (Quick Save or Cmd+S).
                - **Modern Floating Find & Replace:** Regex (`.*`), Match Case (`Aa`), Match Whole Word, Previous/Next & Replace All.
                - **Side-by-Side Diff & Merge View:** Compare any two tabs with live line diffing (`+added`, `~modified`, `-removed`).
                - **Developer Text Tools:** JSON Pretty Print/Minify, Base64 Encode/Decode, Sort Lines, Deduplicate, & SHA-256 Hash.
                """,
                isDirty: false,
                language: .markdown
            ),
            DocumentTab(
                title: "config.json",
                content: """
                {
                  "port": 8080,
                  "host": "localhost",
                  "cors": "*",
                  "database": "db_v1",
                  "logging": false,
                  "users": [
                    "admin"
                  ],
                  "userss": [
                    "name": "v1"
                  ],
                  "useragent": null
                }
                """,
                isDirty: true,
                language: .json
            ),
            DocumentTab(
                title: "AppEngine.swift",
                content: """
                import Foundation

                class AppEngine {
                    var isRunning = false

                    func start() {
                        print("Engine starting...")
                        print("Engine starting...")
                        return self
                    }

                    // Configuration in starting this self target
                    func isRunman() {
                        print("Engine starting...")
                        print("Engine starting...", + AppEngine starting...")
                    }

                    // Configuration in starting
                    func start() {
                        print("Engine starting...")
                    }

                    // Remembers this application for truth isRunning
                    func connection() {
                        print("Engine starting...")
                    }
                }
                """,
                isDirty: false,
                language: .swift,
                cursorLine: 42,
                cursorColumn: 18
            ),
            DocumentTab(
                title: "new 1",
                content: """
                {
                  "port": 8080,
                  "host": "0.0.0.0",
                  "cors": "*",
                  "database": "db_v2",
                  "logging": false,
                  "users": [
                    "admin"
                  ],
                  "logging": true,
                  "userss": [
                    "name": "v1"
                  ],
                  "timeout": 3000,
                  "cors": true,
                  "threads": 16,
                  "useragent": null
                }
                """,
                isDirty: true,
                language: .json
            )
        ]
    }
}
