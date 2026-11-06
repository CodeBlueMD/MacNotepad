import Foundation
#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit

@main
struct MacNotepadApp: App {
    var body: some Scene {
        WindowGroup("MacNotepad") {
            MainWorkspaceView()
                .frame(minWidth: 920, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
    }
}
#else
@main
struct MacNotepadCLI {
    static func main() {
        let prefs = SessionManager.shared.loadPreferences()
        print("MacNotepad Core Engine Ready — Default Save Location: \(prefs.defaultSaveDirectoryPath)")
    }
}
#endif
