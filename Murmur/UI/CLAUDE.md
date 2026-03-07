# UI — CLAUDE.md

## Purpose
Top-level UI directory. Contains Settings window and failed transcription management. The main floating pill UI lives in `FloatingPanel/` — see its own CLAUDE.md.

## Sub-component Routing

| Area | Read |
|---|---|
| Floating pill, transcript tray, speaker naming | `FloatingPanel/CLAUDE.md` |
| Settings window, stats, speaker management | `Settings/CLAUDE.md` |

## Files (this directory only)

| File | Responsibility |
|---|---|
| `FailedTranscriptionsView.swift` | Retry queue management: list of failed transcriptions with retry/delete per item, retry all button |

## Key Types

**FailedTranscriptionsView** (SwiftUI View):
- `@State retryingIds: Set<UUID>` — tracks which items are being retried
- Retry: calls `taskManager.retryFailedTranscription(failedId:)`
- Delete: confirmation alert, then `failedManager.deleteFailedTranscription(id:)`
- Opened from menu bar (Cmd+F) in a standalone 650×500 NSWindow

## Modification Recipes

| Task | Files to touch |
|---|---|
| Fix retry UI | `FailedTranscriptionsView.swift` — binds to FailedTranscriptionManager from Core/ |
| Fix retry logic | `Core/TranscriptionTaskManager.swift` — `retryFailedTranscription()` |
| Add new UI area | Create subdirectory with its own CLAUDE.md, import DesignTokens |

## Dependencies
**From Core/**: TranscriptionTaskManager, FailedTranscriptionManager
**From Design/**: DesignTokens (colors, spacing, animations)

## Logging
Subsystem: `ui`
