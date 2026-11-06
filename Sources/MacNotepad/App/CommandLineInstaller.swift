#if canImport(AppKit)
import AppKit

/// Installs the `mnp` shell command, which opens files (or piped text) in MacNotepad.
///   mnp notes.md          open a file
///   mnp file.swift:42     open at a line
///   echo hi | mnp         open piped text in a new tab
enum CommandLineInstaller {
    static let script = """
    #!/bin/sh
    # mnp — open files or piped text in MacNotepad
    if [ "$#" -eq 0 ]; then
      if [ -t 0 ]; then
        open -b com.codebluemd.macnotepad
      else
        tmp="$(mktemp -t mnp).txt"
        cat > "$tmp"
        open -b com.codebluemd.macnotepad "$tmp"
      fi
      exit 0
    fi
    for arg in "$@"; do
      file="$arg"; line=""
      case "$arg" in
        *:[0-9]*) file="${arg%:*}"; line="${arg##*:}" ;;
      esac
      [ -e "$file" ] || touch "$file"
      abs="$(cd "$(dirname "$file")" && pwd)/$(basename "$file")"
      if [ -n "$line" ]; then
        enc="$(printf '%s' "$abs" | /usr/bin/python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.stdin.read()))' 2>/dev/null || printf '%s' "$abs")"
        open "macnotepad://open?path=$enc&line=$line"
      else
        open -b com.codebluemd.macnotepad "$abs"
      fi
    done
    """

    @MainActor
    static func install(store: WorkspaceStore) {
        let targets = ["/usr/local/bin", NSHomeDirectory() + "/.local/bin"]
        let scriptURL = FileManager.default.temporaryDirectory.appendingPathComponent("mnp")
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        } catch {
            store.flashStatus("Couldn't prepare mnp: \(error.localizedDescription)")
            return
        }

        // Prefer /usr/local/bin (asks for an administrator password once); fall back to ~/.local/bin.
        let installCommand = "mkdir -p /usr/local/bin && cp '\(scriptURL.path)' /usr/local/bin/mnp && chmod 755 /usr/local/bin/mnp"
        var error: NSDictionary?
        let apple = NSAppleScript(source: "do shell script \"\(installCommand)\" with administrator privileges")
        apple?.executeAndReturnError(&error)
        if error == nil {
            store.flashStatus("Installed mnp to /usr/local/bin — try: mnp notes.md")
            return
        }

        let fallback = URL(fileURLWithPath: targets[1])
        do {
            try FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
            let dest = fallback.appendingPathComponent("mnp")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.copyItem(at: scriptURL, to: dest)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            store.flashStatus("Installed mnp to ~/.local/bin (add it to your PATH)")
        } catch {
            store.flashStatus("Couldn't install mnp: \(error.localizedDescription)")
        }
    }
}
#endif
