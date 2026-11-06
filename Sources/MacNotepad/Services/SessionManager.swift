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
    public var wordWrap: Bool
    public var spellCheckEnabled: Bool
    public var zoomPercentage: Int
    public var showWhitespace: Bool
    public var autoCloseBrackets: Bool
    public var showSidebar: Bool
    public var showPreview: Bool
    public var showOutline: Bool
    /// Notion-style live Markdown: sized headings, bold/italic, checkboxes, dimmed syntax markers.
    public var liveMarkdownStyling: Bool
    public var recentFilePaths: [String]

    public static func defaultSaveDirectoryURL() -> URL {
        if let override = ProcessInfo.processInfo.environment["MACNOTEPAD_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true).appendingPathComponent("Notes", isDirectory: true)
        }
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
        wordWrap: Bool = true,
        spellCheckEnabled: Bool = false,
        zoomPercentage: Int = 100,
        showWhitespace: Bool = false,
        autoCloseBrackets: Bool = true,
        showSidebar: Bool = true,
        showPreview: Bool = false,
        showOutline: Bool = false,
        liveMarkdownStyling: Bool = true,
        recentFilePaths: [String] = []
    ) {
        self.defaultSaveDirectoryPath = defaultSaveDirectoryPath
        self.autoCreateDefaultSaveFolder = autoCreateDefaultSaveFolder
        self.persistentUnsavedTabs = persistentUnsavedTabs
        self.autoSaveIntervalSeconds = autoSaveIntervalSeconds
        self.theme = theme
        self.fontFamily = fontFamily
        self.fontSize = fontSize
        self.showLineNumbers = showLineNumbers
        self.wordWrap = wordWrap
        self.spellCheckEnabled = spellCheckEnabled
        self.zoomPercentage = zoomPercentage
        self.showWhitespace = showWhitespace
        self.autoCloseBrackets = autoCloseBrackets
        self.showSidebar = showSidebar
        self.showPreview = showPreview
        self.showOutline = showOutline
        self.liveMarkdownStyling = liveMarkdownStyling
        self.recentFilePaths = recentFilePaths
    }

    /// Tolerant decoding: settings saved by older versions keep their values and new options get defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EditorPreferences()
        defaultSaveDirectoryPath = try c.decodeIfPresent(String.self, forKey: .defaultSaveDirectoryPath) ?? d.defaultSaveDirectoryPath
        autoCreateDefaultSaveFolder = try c.decodeIfPresent(Bool.self, forKey: .autoCreateDefaultSaveFolder) ?? d.autoCreateDefaultSaveFolder
        persistentUnsavedTabs = try c.decodeIfPresent(Bool.self, forKey: .persistentUnsavedTabs) ?? d.persistentUnsavedTabs
        autoSaveIntervalSeconds = try c.decodeIfPresent(Int.self, forKey: .autoSaveIntervalSeconds) ?? d.autoSaveIntervalSeconds
        theme = try c.decodeIfPresent(AppTheme.self, forKey: .theme) ?? d.theme
        fontFamily = try c.decodeIfPresent(String.self, forKey: .fontFamily) ?? d.fontFamily
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? d.fontSize
        showLineNumbers = try c.decodeIfPresent(Bool.self, forKey: .showLineNumbers) ?? d.showLineNumbers
        wordWrap = try c.decodeIfPresent(Bool.self, forKey: .wordWrap) ?? d.wordWrap
        spellCheckEnabled = try c.decodeIfPresent(Bool.self, forKey: .spellCheckEnabled) ?? d.spellCheckEnabled
        zoomPercentage = try c.decodeIfPresent(Int.self, forKey: .zoomPercentage) ?? d.zoomPercentage
        showWhitespace = try c.decodeIfPresent(Bool.self, forKey: .showWhitespace) ?? d.showWhitespace
        autoCloseBrackets = try c.decodeIfPresent(Bool.self, forKey: .autoCloseBrackets) ?? d.autoCloseBrackets
        showSidebar = try c.decodeIfPresent(Bool.self, forKey: .showSidebar) ?? d.showSidebar
        showPreview = try c.decodeIfPresent(Bool.self, forKey: .showPreview) ?? d.showPreview
        showOutline = try c.decodeIfPresent(Bool.self, forKey: .showOutline) ?? d.showOutline
        liveMarkdownStyling = try c.decodeIfPresent(Bool.self, forKey: .liveMarkdownStyling) ?? d.liveMarkdownStyling
        recentFilePaths = try c.decodeIfPresent([String].self, forKey: .recentFilePaths) ?? d.recentFilePaths
    }
}

/// Manages session state ("Hot Exit" persistent unsaved tabs) and default ~/Documents/MacNotepad file operations.
public final class SessionManager {
    public static let shared = SessionManager()

    private let fileManager = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let saveQueue = DispatchQueue(label: "MacNotepad.sessionSave", qos: .utility)
    private var pendingSessionSave: DispatchWorkItem?

    public init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
    }

    /// Application support directory where unsaved tabs and preferences are persisted across launches.
    public var appSupportDirectoryURL: URL {
        let dir: URL
        if let override = ProcessInfo.processInfo.environment["MACNOTEPAD_DATA_DIR"], !override.isEmpty {
            // Lets demos, screenshots and tests run against a separate session without touching real notes.
            dir = URL(fileURLWithPath: override, isDirectory: true).appendingPathComponent("Support", isDirectory: true)
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            dir = base.appendingPathComponent("MacNotepad", isDirectory: true)
        }
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
            // Never silently overwrite another file that happens to share the tab's name.
            targetURL = FileService.uniqueURL(in: targetDir, fileName: fileName)
        }

        try FileService.write(&tab, to: targetURL)
        tab.importedFrom = nil
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
        pendingSessionSave?.cancel()
        pendingSessionSave = nil
        guard let data = try? encoder.encode(Self.compactForSession(tabs)) else { return }
        let url = sessionFileURL
        // Same serial queue as the debounced saves, so an in-flight older save can't land after this one.
        saveQueue.sync { try? data.write(to: url, options: .atomic) }
    }

    /// Clean tabs backed by a file are restored from disk, so their (possibly huge) text isn't duplicated in the session.
    static func compactForSession(_ tabs: [DocumentTab]) -> [DocumentTab] {
        tabs.map { tab in
            guard !tab.isDirty, tab.fileURL != nil else { return tab }
            var compact = tab
            compact.content = ""
            compact.contentStoredOnDisk = true
            return compact
        }
    }

    /// Debounced background save so typing doesn't encode and write every tab on each keystroke.
    public func scheduleSessionSave(tabs: [DocumentTab], delay: TimeInterval = 1.0) {
        pendingSessionSave?.cancel()
        let url = sessionFileURL
        let work = DispatchWorkItem {
            // Own encoder: this runs off the main thread while saveSession may encode on it.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(Self.compactForSession(tabs)) else { return }
            try? data.write(to: url, options: .atomic)
        }
        pendingSessionSave = work
        saveQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Restores previous session tabs, or creates initial starter tabs if launching fresh.
    public func loadSession() -> [DocumentTab] {
        if let data = try? Data(contentsOf: sessionFileURL),
           let decoded = decodeSession(data),
           !decoded.isEmpty {
            return decoded.compactMap { tab in
                guard tab.contentStoredOnDisk == true, let url = tab.fileURL else { return tab }
                // Reload clean tabs from disk; drop them if the file has since been deleted.
                guard var reloaded = try? FileService.openTab(at: url, forcedEncoding: tab.encoding) else { return nil }
                reloaded.id = tab.id
                reloaded.language = tab.language
                reloaded.cursorLine = tab.cursorLine
                reloaded.cursorColumn = tab.cursorColumn
                return reloaded
            }
        }
        return Self.defaultStarterTabs()
    }

    /// Decodes tabs one at a time so a single unreadable tab doesn't lose the rest.
    /// If nothing can be read, the file is kept aside (session-tabs.unreadable-<date>.json) instead of being overwritten.
    private func decodeSession(_ data: Data) -> [DocumentTab]? {
        struct LossyTab: Decodable {
            let tab: DocumentTab?
            init(from decoder: Decoder) throws { tab = try? DocumentTab(from: decoder) }
        }
        let tabs = (try? decoder.decode([LossyTab].self, from: data))?.compactMap(\.tab)
        let total = (try? JSONSerialization.jsonObject(with: data) as? [Any])?.count
        if tabs == nil || (tabs?.count ?? 0) < (total ?? 0) {
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let backup = appSupportDirectoryURL.appendingPathComponent("session-tabs.unreadable-\(stamp).json")
            try? data.write(to: backup)
        }
        return tabs
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
            DocumentTab(title: "new 1")
        ]
    }
}
