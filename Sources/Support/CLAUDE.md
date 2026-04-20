# Support helpers

## What this directory does

`Sources/Support/` contains app-wide utility types that cut across features. These are standalone helpers shared by dictation, meeting, capture, and UI code without belonging to any single feature directory.

## Files

- `ClipboardRestoringTextPaster.swift` — pastes text into the target app by briefly borrowing the clipboard and restoring prior contents after Cmd+V completes; reports paste/copy/fail outcomes for diagnostics
- `HotkeyPreferences.swift` — data model, persistence, display, and validation for customizable keyboard shortcuts (dictation, meeting, draft hotkey bindings)
- `LocalSpeakerPreferences.swift` — preference flag for local mic-channel speaker diarization; when enabled, the meeting pipeline runs offline diarization on the mic track and surfaces multiple local speakers in the post-meeting naming sheet
- `TranscriptedConstants.swift` — centralized configuration constants for timeouts, thresholds, limits, buffer sizes, and version metadata
- `TranscriptedPermissionAccess.swift` — unified permission checks for microphone, accessibility, system audio recording, and calendar; shared by the meeting prompt detector, settings, and onboarding flows
- `TranscriptedStoragePaths.swift` — app-support path helpers for the Transcripted capture library, state, cache, logs, and tmp layout, including user-configurable capture library relocation

## Key invariants

- `TranscriptedPermissionAccess` is the canonical place for app-level TCC permission queries. Keep duplicate permission branching out of feature-specific code.
- `LocalSpeakerPreferences` defaults to off. The meeting pipeline reads this flag at recording time, so changes take effect on the next meeting.
- `ClipboardRestoringTextPaster` runs on the main thread and uses brief async delays for the paste round-trip. Keep the clipboard borrow window tight.
- `TranscriptedStoragePaths` resolves the capture library from `UserDefaults` first, falling back to the default Application Support location. App-owned state, cache, logs, and temp files always stay under the fixed Application Support root.

## Verification

```bash
bash build.sh
bash run-tests.sh
```

Relevant direct coverage:

- `Tests/TranscriptedConstantsTests.swift`
- `Tests/TranscriptedPermissionAccessTests.swift`
- `Tests/TranscriptedStoragePathsTests.swift`
