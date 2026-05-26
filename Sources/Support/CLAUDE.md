# Support Directory

## What this directory does

`Sources/Support/` holds app-wide helpers that do not belong to a single UI or pipeline surface. These types mostly wrap persisted preferences, shared constants, permission access, storage paths, or low-level paste / launch behavior used across dictation and meetings.

## Files

- `ActivationPolicyController.swift` — combines the Dock toggle with live-recording safety so Transcripted can idle as menu-bar-only but still surface itself in the macOS force-quit dialog during active capture
- `AudioStoragePreferences.swift` — persisted meeting-audio retention window for Settings and background retained-audio maintenance
- `ClaudeDesktopIntegrationInstaller.swift` — installs the bundled read-only MCP helper for Claude Desktop, safely merges Claude's config JSON, and runs the helper self-test
- `ClipboardRestoringTextPaster.swift` — paste helper that preserves clipboard contents while inserting the latest dictation into the target app
- `CustomDictionaryPreferences.swift` — persisted custom spoken-term replacements plus text post-processing helpers
- `DockVisibilityPreferences.swift` — persisted General setting for whether Transcripted should stay visible in the Dock while idle
- `DictationAutoSendPreferences.swift` — persisted auto-send rules, allowed bundle list, and keypress-sending helpers for pasted dictation
- `HotkeyPreferences.swift` — persisted shortcut mode, meeting shortcut compatibility, legacy Carbon hotkey migration helpers, right-Option toggle migration, display formatting, and validation
- `LaunchAtLoginController.swift` — app-facing wrapper for enabling or disabling launch-at-login behavior
- `LaunchAtLoginPreferences.swift` — persisted first-run preference state around launch-at-login UX
- `LocalSpeakerPreferences.swift` — persisted toggle for splitting the local mic channel into multiple named speakers during meeting review
- `MenuBarVisibilityPreferences.swift` — persisted Home toggles for optional menubar popover rows
- `MicrophoneProcessingPreferences.swift` — persisted meeting-mic processing mode, toggling between default software AGC and optional Apple voice processing (VPIO) for users who need the WebRTC-specific recovery path
- `PermissionsOnboardingPreferences.swift` — persisted completion and forced-rerun state for the first-run permissions onboarding flow
- `PhysicalDictationTriggerPreferences.swift` — canonical physical key / modifier trigger bindings for push-to-talk, hands-free dictation, and meeting shortcuts, including migration from older right-Option settings
- `QuitConfirmationPreferences.swift` — default-on quit safety policy and copy for warning before active meeting recordings are stopped by app quit
- `SpeakerNameSelectionPolicy.swift` — shared speaker-name matching, duplicate-label disambiguation, and owner-label policy used by people/review UI
- `TranscriptedConstants.swift` — shared timing thresholds and app-wide behavior constants
- `TranscriptedPermissionAccess.swift` — shared permission status, prompting, and Settings-deep-link helpers for microphone, accessibility, system-audio recording, and calendar access
- `TranscriptedPermissionKind.swift` — shared permission metadata, onboarding requirements, copy, icons, and action labels used by onboarding and Settings
- `TranscriptedStoragePaths.swift` — canonical app-support path helpers for captures, state, cache, logs, and temporary files
- `TranscriptionModelPreferences.swift` — persisted local transcription-model selection shared by dictation and meetings

## Current notes

- Keep preference keys and notification names centralized here so UI and controllers do not drift.
- `PhysicalDictationTriggerPreferences` is the canonical binding layer for push-to-talk, hands-free dictation, and meeting shortcuts. Avoid reintroducing ad hoc keycode logic or special-case right-Option handling in UI or capture code.
- `TranscriptionModelPreferences` is the shared switch between `Parakeet` and the available local Whisper variants. Model-specific runtime behavior still belongs in `Sources/Speech/` and `Sources/Meeting/`.
- `CustomDictionaryPreferences` and `DictationAutoSendPreferences` back the Settings `General` and `Dictation` pages. If you change parsing rules or policy thresholds, update the relevant tests.
- `TranscriptedPermissionAccess` plus `TranscriptedPermissionKind` are the app-level permission seams. UI flows should call into them instead of duplicating TCC branching, metadata, or user-facing permission copy.
- `SpeakerNameSelectionPolicy` keeps speaker search and "You" matching consistent across settings and review UI. Keep duplicate-name disambiguation here instead of in individual SwiftUI controls.
- `PermissionsOnboardingPreferences` is the canonical completion flag for the guided first-run permissions flow. Keep onboarding state out of view-local storage so forced reruns and completion state stay consistent.
- `TranscriptedStoragePaths` should stay as the canonical path resolver for the app target. `Sources/TranscriptedCore/Services/CoreStoragePaths.swift` is the injected library-side seam.
- `ClaudeDesktopIntegrationInstaller` owns the Claude Desktop config merge. Preserve existing MCP servers and back up invalid JSON instead of overwriting blindly.
- `DockVisibilityPreferences` is the canonical storage layer for the General Dock toggle. Keep the key and notification stable so upgrades preserve the setting.
- `ActivationPolicyController` is the canonical place for the app's force-quit visibility policy. Keep Dock/icon activation-policy switching out of recording controllers and UI views.
- `QuitConfirmationPreferences` should default on. Quitting during a live meeting stops capture, so the opt-out belongs in Settings instead of being hidden in the alert.
- `MicrophoneProcessingPreferences` is the canonical switch for meeting-mic cleanup mode. Default behavior is software AGC without playback ducking; Apple voice processing stays opt-in because it can duck other apps during recording.
- `AudioStoragePreferences` only stores the retention choice. Destructive cleanup behavior belongs in `Sources/Meeting/MeetingAudioStorageManager.swift` and should stay conservative: the Settings UI should ask before switching into a destructive 7-day or 30-day cleanup window.

## Verification

After changing support code:

```bash
bash build.sh
bash run-tests.sh
```

Relevant direct coverage includes:

- `Tests/ClaudeDesktopIntegrationInstallerTests.swift`
- `Tests/ActivationPolicyControllerTests.swift`
- `Tests/AudioStoragePreferencesTests.swift`
- `Tests/ClipboardRestoringTextPasterTests.swift`
- `Tests/CustomDictionaryPreferencesTests.swift`
- `Tests/DictationAutoSendPreferencesTests.swift`
- `Tests/HotkeyPreferencesTests.swift`
- `Tests/LaunchAtLoginPreferencesTests.swift`
- `Tests/MenuBarVisibilityPreferencesTests.swift`
- `Tests/MicrophoneProcessingPreferencesTests.swift`
- `Tests/PermissionsOnboardingPreferencesTests.swift`
- `Tests/PhysicalDictationTriggerPreferencesTests.swift`
- `Tests/QuitConfirmationPreferencesTests.swift`
- `Tests/SpeakerNameSelectionPolicyTests.swift`
- `Tests/TranscriptedConstantsTests.swift`
- `Tests/TranscriptedPermissionAccessTests.swift`
- `Tests/TranscriptedStoragePathsTests.swift`
- `Tests/TranscriptionModelPreferencesTests.swift`
