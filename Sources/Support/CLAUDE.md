# Support Directory

## What this directory does

`Sources/Support/` holds app-wide helpers that do not belong to a single UI or pipeline surface. These types mostly wrap persisted preferences, shared constants, permission access, storage paths, or low-level paste / launch behavior used across dictation and meetings.

## Files (13 Swift files)

- `ClaudeDesktopIntegrationInstaller.swift` — installs the bundled read-only MCP helper for Claude Desktop, safely merges Claude's config JSON, and runs the helper self-test
- `ClipboardRestoringTextPaster.swift` — paste helper that preserves clipboard contents while inserting the latest dictation into the target app
- `CustomDictionaryPreferences.swift` — persisted custom spoken-term replacements plus text post-processing helpers
- `DictationAutoSendPreferences.swift` — persisted auto-send rules, allowed bundle list, and keypress-sending helpers for pasted dictation
- `HotkeyPreferences.swift` — persisted global hotkey bindings, dictation shortcut mode, right-Option toggle, display formatting, and validation
- `LaunchAtLoginController.swift` — app-facing wrapper for enabling or disabling launch-at-login behavior
- `LaunchAtLoginPreferences.swift` — persisted first-run preference state around launch-at-login UX
- `LocalSpeakerPreferences.swift` — persisted toggle for splitting the local mic channel into multiple named speakers during meeting review
- `MenuBarVisibilityPreferences.swift` — persisted Home toggles for optional menubar popover rows
- `TranscriptedConstants.swift` — shared timing thresholds and app-wide behavior constants
- `TranscriptedPermissionAccess.swift` — shared permission status, prompting, and Settings-deep-link helpers for microphone, accessibility, system-audio recording, and calendar access
- `TranscriptedStoragePaths.swift` — canonical app-support path helpers for captures, state, cache, logs, and temporary files
- `TranscriptionModelPreferences.swift` — persisted local transcription-model selection shared by dictation and meetings

## Current notes

- Keep preference keys and notification names centralized here so UI and controllers do not drift.
- `TranscriptionModelPreferences` is the shared switch between `Parakeet` and the available local Whisper variants. Model-specific runtime behavior still belongs in `Sources/Speech/` and `Sources/Meeting/`.
- `CustomDictionaryPreferences` and `DictationAutoSendPreferences` back the Settings `General` and `Dictation` pages. If you change parsing rules or policy thresholds, update the relevant tests.
- `TranscriptedPermissionAccess` is the app-level permission seam. UI flows should call into it instead of duplicating TCC branching.
- `TranscriptedStoragePaths` should stay as the canonical path resolver for the app target. `Sources/TranscriptedCore/Services/CoreStoragePaths.swift` is the injected library-side seam.
- `ClaudeDesktopIntegrationInstaller` owns the Claude Desktop config merge. Preserve existing MCP servers and back up invalid JSON instead of overwriting blindly.

## Verification

After changing support code:

```bash
bash build.sh
bash run-tests.sh
```

Relevant direct coverage includes:

- `Tests/ClipboardRestoringTextPasterTests.swift`
- `Tests/CustomDictionaryPreferencesTests.swift`
- `Tests/DictationAutoSendPreferencesTests.swift`
- `Tests/LaunchAtLoginPreferencesTests.swift`
- `Tests/MenuBarVisibilityPreferencesTests.swift`
- `Tests/TranscriptedConstantsTests.swift`
- `Tests/TranscriptedPermissionAccessTests.swift`
- `Tests/TranscriptedStoragePathsTests.swift`
- `Tests/TranscriptionModelPreferencesTests.swift`
