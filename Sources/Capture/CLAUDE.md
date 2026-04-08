# Capture

## What This Contains

Screenshot and context-capture primitives used to build structured context for Draft.

Current Swift files: **2**

| File | Purpose |
|---|---|
| `CapturedContext.swift` | Shared structured model for captured screenshot/OCR context |
| `ContextCaptureEngine.swift` | Orchestrates active capture flows for meeting and dictation capture |

## Notes
- This directory is narrower than older docs that described a larger capture subsystem.
- Prefer this folder for context extraction, not speech transcription or UI state.
