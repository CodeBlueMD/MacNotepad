#!/usr/bin/env bash
# Creates a self-contained demo notes library for screenshots and manual testing.
# Usage: scripts/make-demo-notes.sh /path/to/demo-dir
#        MACNOTEPAD_DATA_DIR=/path/to/demo-dir MacNotepad.app/Contents/MacOS/MacNotepad
set -euo pipefail
ROOT="${1:?usage: make-demo-notes.sh <dir>}"
NOTES="$ROOT/Notes"
/bin/rm -rf "$ROOT"
mkdir -p "$NOTES/Work" "$NOTES/Personal" "$NOTES/Projects"

cat > "$NOTES/Work/Product Launch Plan.md" <<'MD'
# Product Launch Plan

Launch target: **March 14** · Owner: *Product team* #launch #q1

> 💡 Keep the scope small: ship the editor, notes library and export first.

## Goals

- [x] Finalize the feature list
- [x] Record the demo video
- [ ] Publish the release notes
- [ ] Email beta testers

## Timeline

| Week | Milestone | Status |
| --- | --- | --- |
| 1 | Feature freeze | Done |
| 2 | Beta build | In progress |
| 3 | Public release | Planned |

## Open Questions

1. Do we bundle the `mnp` command-line tool?
2. Which export formats matter most? ==Word and PDF== came up most.

See the [design doc](https://example.com/design) for details.
MD

cat > "$NOTES/Work/Weekly Sync.md" <<'MD'
# Weekly Sync — Nov 4

Attendees: Ana, Ben, Priya #meetings

## Decisions

- Move the beta to **next Tuesday**
- Use Markdown for all internal docs

## Action Items

- [ ] Ana — update the onboarding checklist
- [x] Ben — fix the export bug
- [ ] Priya — draft the FAQ
MD

cat > "$NOTES/Personal/Trip to Lisbon.md" <<'MD'
# Trip to Lisbon

#travel #personal

## Packing

- [x] Passport
- [ ] Adapter (Type F)
- [ ] Walking shoes

## Places

1. Alfama & São Jorge Castle
2. Time Out Market
3. Day trip to *Sintra*
MD

cat > "$NOTES/Personal/Reading List.md" <<'MD'
# Reading List

#books

- [ ] *The Pragmatic Programmer*
- [x] *Deep Work*
- [ ] *A Philosophy of Software Design*
MD

cat > "$NOTES/Projects/Ideas.md" <<'MD'
# Ideas

#ideas

- Menu-bar capture for quick thoughts
- Daily note template with a ==focus== section
- Sync notes folder via iCloud Drive
MD

cat > "$NOTES/Inbox.md" <<'MD'
# Inbox

- Nov 6, 2026 at 9:12 AM — Call the dentist
- Nov 6, 2026 at 11:40 AM — Look into Swift 6 strict concurrency
MD

cat > "$NOTES/Projects/server.swift" <<'SWIFT'
import Foundation

/// Minimal HTTP health check used by the deploy script.
struct HealthCheck {
    let url: URL
    var timeout: TimeInterval = 5

    func run() async throws -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            return false
        }
        // 2xx means healthy
        return (200..<300).contains(http.statusCode)
    }
}

enum Environment: String, CaseIterable {
    case staging, production

    var baseURL: URL {
        URL(string: "https://\(rawValue).example.com/health")!
    }
}
SWIFT

echo "Demo notes created in $NOTES"
