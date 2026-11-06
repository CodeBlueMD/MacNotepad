#if canImport(SwiftUI) && canImport(AppKit)
import SwiftUI
import AppKit

/// Menu-bar quick capture: jot a thought from anywhere and it lands in Inbox.md.
struct QuickCaptureView: View {
    @ObservedObject private var store = WorkspaceStore.shared
    @State private var text = ""
    @State private var savedFlash = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Quick Note", systemImage: "square.and.pencil")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                if savedFlash {
                    Label("Added to Inbox", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.green)
                }
            }

            TextEditor(text: $text)
                .font(.system(size: 13))
                .focused($focused)
                .frame(height: 120)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.06)))

            HStack {
                Button("Add to Inbox") { addToInbox() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Open as Note") {
                    let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    store.newTab(title: "Quick Note.md", content: body.isEmpty ? "# Quick Note\n\n" : "# Quick Note\n\n\(body)\n",
                                 language: .markdown, cursorAtEnd: true)
                    text = ""
                    showMainWindow()
                }
                Spacer()
                Button {
                    showMainWindow()
                } label: {
                    Image(systemName: "macwindow")
                }
                .help("Open MacNotepad")
            }

            Text("⌘↩ adds to Inbox.md · ⌃⌥N opens a quick note from any app")
                .font(.system(size: 10.5))
                .foregroundColor(.secondary)
        }
        .padding(14)
        .frame(width: 340)
        .onAppear { focused = true }
    }

    private func addToInbox() {
        store.appendToInbox(text)
        text = ""
        withAnimation { savedFlash = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { withAnimation { savedFlash = false } }
    }

    private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
    }
}
#endif
