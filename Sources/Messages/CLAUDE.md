# iMessage Reader

## What This Does

Reads the user's sent iMessages from `~/Library/Messages/chat.db` for automatic style profile generation during onboarding. Alternative to the manual "paste samples" flow.

## Key File

- `iMessageReader.swift` (165 lines) — Swift `actor` that queries chat.db via the SQLite3 C API

## How It Works

1. Opens `~/Library/Messages/chat.db` in read-only mode (`SQLITE_OPEN_READONLY`)
2. Queries sent messages with a `LEFT JOIN` on the `handle` table to retrieve the contact handle ID alongside each message: `is_from_me = 1 AND text IS NOT NULL AND text != ''` with `ORDER BY date DESC LIMIT ?` (parameterized, default 2000)
3. Applies quality filters **in Swift only** — no SQL-level word/length filters
4. Returns `[ImportedMessage]` structs (containing `text`, `date`, and `handleId`) shown in preview UI
5. `formatForAnalysis()` joins messages for the Sonnet analysis call
6. Raw messages are discarded after profile generation — never saved

## Permission

Requires **Full Disk Access** (FDA) because `~/Library/Messages/` is SIP-protected. The app is already unsandboxed (`com.apple.security.app-sandbox: false`), but FDA is a separate grant in System Settings → Privacy & Security → Full Disk Access.

If FDA isn't granted, `sqlite3_open_v2` fails and `ReaderError.accessDenied` is thrown. FDA detection checks the error message for "unable to open", "permission", "not authorized", AND "authorization" patterns. The UI shows a link to System Settings with a "Try Again" button.

## iMessage Date Format

Apple stores dates as **nanoseconds since 2001-01-01** (the `NSDate` reference date). Conversion:

```swift
let date = Date(timeIntervalSinceReferenceDate: Double(nanos) / 1_000_000_000)
```

Note: There is NO date filter in the query — all sent messages are fetched up to the LIMIT.

## Quality Filters

**SQL-level:** None. The query only filters `is_from_me = 1 AND text IS NOT NULL AND text != ''`.

**Swift-level** (`shouldSkip()`):
- `trimmed.count < 2` — single-character messages ("k", "y") have no style signal
- `nonEmojiCount < 3` — pure emoji / reaction messages (fewer than 3 non-emoji ASCII scalars)
- Tapback reactions — catches multiple formats:
  - Verb prefixes checked: `loved`, `liked`, `laughed at`, `emphasized`, `questioned`, `disliked`, `reacted`
  - Standard: "Loved an image", "Liked a message"
  - Quoted: `Liked "some text"` or `Liked \u{201C}some text\u{201D}` (smart quotes)
  - Emoji reactions: `Reacted 💯 to "something"` (verb + " to " pattern)
- URL-only messages — starts with `http` with 2 or fewer words

**Important:** iMessage stores the Unicode Object Replacement Character (U+FFFC) in the `text` field for attachment-only messages (photos, audio, etc.). These are filtered out by the `trimmed.count < 2` check since U+FFFC alone is a single character. In practice, the majority of messages in a typical chat.db may be these invisible placeholders.

## Observability

The reader reports errors to `EventReporter` (engine: `"imessage"`) via `@MainActor` dispatch:

| Event | When |
|-------|------|
| `imessage_db_open_failed` | `sqlite3_open_v2` fails — logged for both access-denied and general open failures |
| `imessage_query_failed` | `sqlite3_prepare_v2` fails (malformed query, schema mismatch) |

All three capture points are at `level: .error`.

## Public Interface

```swift
actor iMessageReader {
    // Error types
    enum ReaderError: LocalizedError {
        case databaseNotFound   // chat.db doesn't exist
        case databaseEmpty      // query succeeded but all messages filtered out
        case accessDenied       // FDA not granted (sqlite3_open_v2 permission failure)
        case queryFailed(String) // any other SQLite error
    }

    struct ImportedMessage {
        let text: String
        let date: Date
        let handleId: String   // contact identifier from the handle table ("unknown" if NULL)
    }

    func databaseExists() -> Bool
    func readMessages(limit: Int = 2000) throws -> [ImportedMessage]
    func formatForAnalysis(_ messages: [ImportedMessage], maxMessages: Int = 500) -> String
}
```

## Verification

- **Happy path:** Grant FDA → onboarding → choose iMessage → verify messages appear in preview
- **FDA denied:** Revoke FDA → try iMessage → verify error with "Open System Settings" link
- **No database:** Temporarily rename `~/Library/Messages/chat.db` → verify fallback error
- **Message count:** Expect fewer messages than the 2000 limit — most are filtered by `shouldSkip()` (U+FFFC placeholders, tapbacks, emoji-only, single characters)
- **Build:** `bash build.sh` — requires `-lsqlite3` linker flag in build.sh
