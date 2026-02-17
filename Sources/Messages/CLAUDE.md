# iMessage Reader

## What This Does

Reads the user's sent iMessages from `~/Library/Messages/chat.db` for automatic style profile generation during onboarding. Alternative to the manual "paste samples" flow.

## Key File

- `iMessageReader.swift` — Swift `actor` that queries chat.db via the SQLite3 C API

## How It Works

1. Opens `~/Library/Messages/chat.db` in read-only mode (`SQLITE_OPEN_READONLY`)
2. Queries the last 6 months of sent messages (`is_from_me = 1`) with 5+ words
3. Applies quality filters in Swift (skip tapbacks, emoji-only, URL-only)
4. Returns `[ImportedMessage]` structs shown in preview UI
5. `formatForAnalysis()` joins messages for the Sonnet analysis call
6. Raw messages are discarded after profile generation — never saved

## Permission

Requires **Full Disk Access** (FDA) because `~/Library/Messages/` is SIP-protected. The app is already unsandboxed (`com.apple.security.app-sandbox: false`), but FDA is a separate grant in System Settings → Privacy & Security → Full Disk Access.

If FDA isn't granted, `sqlite3_open_v2` fails and `ReaderError.accessDenied` is thrown. The UI shows a link to System Settings with a "Try Again" button.

## iMessage Date Format

Apple stores dates as **nanoseconds since 2001-01-01** (the `NSDate` reference date). Conversion:

```swift
let date = Date(timeIntervalSinceReferenceDate: Double(nanos) / 1_000_000_000)
```

The query uses this to filter to the last 6 months.

## Quality Filters

**SQL-level:** `length(text) - length(replace(text, ' ', '')) >= 4` (proxy for 5+ words)

**Swift-level** (`shouldSkip()`):
- Under 5 words
- Pure emoji (fewer than 5 non-emoji ASCII scalars)
- Tapback reactions ("Loved an image", "Liked a message", etc.)
- URL-only messages (starts with `http`, 2 or fewer words)

## Public Interface

```swift
actor iMessageReader {
    func databaseExists() -> Bool
    func readMessages(limit: Int = 2000) throws -> [ImportedMessage]
    func formatForAnalysis(_ messages: [ImportedMessage], maxMessages: Int = 500) -> String
}
```

## Verification

- **Happy path:** Grant FDA → onboarding → choose iMessage → verify messages appear in preview
- **FDA denied:** Revoke FDA → try iMessage → verify error with "Open System Settings" link
- **No database:** Temporarily rename `~/Library/Messages/chat.db` → verify fallback error
- **Build:** `bash build.sh` — requires `-lsqlite3` linker flag in build.sh
