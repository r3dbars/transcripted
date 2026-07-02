# Support Directory

## What this directory does

`Sources/Support/` holds app-wide helpers that do not belong to a single UI or pipeline surface. These types mostly wrap persisted preferences, shared constants, permission access, storage paths, or low-level paste / launch behavior used across dictation and meetings.

## Files

- `ActivationPolicyController.swift` — combines the Dock toggle with live-recording safety so Transcripted can idle as menu-bar-only but still surface itself in the macOS force-quit dialog during active capture
- `AudioStoragePreferences.swift` — persisted meeting-audio retention window for Settings and background retained-audio maintenance
- `AutoCallDetectionPreferences.swift` — persisted (default-on) toggle for ad-hoc call detection via mic activity; gates `MicActivityMonitor` and the General-page "Auto-detect calls" setting (see `docs/auto-call-detection-spec.md`)
- `AgentMCPConnector.swift` — per-agent MCP connect seam: detection, connection state, and config writers for Claude Code (via the `claude` CLI), Codex (`~/.codex/config.toml`), and Cursor (`~/.cursor/mcp.json`), all pointing at the shared installed helper
- `CaptureLibraryChangeBroadcaster.swift` — single source of truth for the debounced `.meetingCaptureArtifactsDidChange` notification; coalesces background WAV→M4A recompression and transcript-rename file mutations so Home can re-resolve its cached transcript/audio URLs (empty id set means a library-wide change of unknown scope)
- `CaptureLibraryMigrationPlanner.swift` — copy-only planning and execution for relocating the capture library from Settings: detects whether the old folder still holds captures, enumerates meeting Markdown + retained `audio/*_audio/` directories + dictation day files, skips name collisions instead of overwriting, and never deletes originals
- `ClaudeDesktopIntegrationInstaller.swift` — installs the bundled read-only MCP helper for Claude Desktop, safely merges `mcpServers` JSON configs, runs the helper self-test, and silently refreshes a stale installed helper at app launch
- `ClipboardRestoringTextPaster.swift` — paste helper that preserves clipboard contents while inserting the latest dictation into the target app
- `CustomDictionaryPreferences.swift` — persisted custom spoken-term replacements plus text post-processing helpers
- `DockVisibilityPreferences.swift` — persisted General setting for whether Transcripted should stay visible in the Dock while idle
- `DictationAutoSendPreferences.swift` — persisted auto-send rules, allowed bundle list, and keypress-sending helpers for pasted dictation
- `DictationCleanupPreferences.swift` — persisted General toggle for filler-word cleanup after dictation
- `DictationFillerCleanupPolicy.swift` — text cleanup policy for light dictation filler removal
- `DictationOverlayPresentationPreferences.swift` — persisted overlay presentation mode for normal vs cursor-mini dictation UI
- `ExistingInstallModelPrefetchPolicy.swift` — protects existing Parakeet users by deciding when model files should be prefetched after app updates
- `HotkeyPreferences.swift` — persisted shortcut mode, meeting shortcut compatibility, legacy Carbon hotkey migration helpers, right-Option toggle migration, display formatting, and validation
- `LaunchAtLoginController.swift` — app-facing wrapper for enabling or disabling launch-at-login behavior, including the one-time post-onboarding default-enable (meeting detection is dead while the app is closed)
- `LaunchAtLoginPreferences.swift` — persisted preference state around launch-at-login UX: the explicit user choice plus the applied-once default-enable marker and its pure policy
- `MissedCallNudgePreferences.swift` — persisted (default-on) toggle for the post-call "that call wasn't recorded" nudge; written by the nudge's "Don't show again" action and the Settings General toggle
- `LiveMeetingCodexPreferences.swift` — persisted opt-in toggle for the live-meeting sidecar, plus the meeting overlay transcript drawer's remembered open state and clamped height
- `LocalMeetingSummaryPreferences.swift` — persisted beta opt-in toggle and provider selection for local AI meeting summaries on Home
- `LocalSpeakerPreferences.swift` — persisted toggle for splitting the local mic channel into multiple named speakers during meeting review
- `MeetingOverlayPillPreferences.swift` — persisted "keep controls visible" pin that opts the meeting pill out of resting to its compact capsule
- `MenuBarVisibilityPreferences.swift` — persisted Home toggles for optional menubar popover rows
- `MicrophoneProcessingPreferences.swift` — persisted mic processing mode, toggling between raw/off input, default software AGC, and optional Apple voice processing (VPIO) for users who need the WebRTC-specific recovery path in meetings or dictation
- `ModelCacheInventory.swift` — scans and cleans known local model cache roots for Settings storage controls
- `OnboardingDictationShortcutPolicy.swift` — first-run shortcut policy that keeps dictation setup copy aligned with trigger preferences
- `PermissionsOnboardingPreferences.swift` — persisted completion and forced-rerun state for the first-run permissions onboarding flow
- `PhysicalDictationTriggerPreferences.swift` — canonical physical key / modifier trigger bindings for push-to-talk, hands-free dictation, paste-last-dictation, and meeting shortcuts, including migration from older right-Option settings
- `QuitConfirmationPreferences.swift` — default-on quit safety policy and copy for warning before active meeting recordings are stopped by app quit
- `SingleInstanceGuard.swift` — local guard used to keep duplicate app instances from racing shared app state
- `SpeakerNameSelectionPolicy.swift` — shared speaker-name matching, duplicate-label disambiguation, and owner-label policy used by people/review UI
- `SpeechModelBetaPreferences.swift` — persisted default-off beta opt-in for the Nemotron streaming transcription model; gates its visibility in the model picker and its runtime availability in `effectiveModel()`
- `TranscriptedConstants.swift` — shared timing thresholds and app-wide behavior constants
- `TranscriptedPermissionAccess.swift` — shared permission status, prompting, and Settings-deep-link helpers for microphone, accessibility, system-audio recording, and calendar access
- `TranscriptedPermissionKind.swift` — shared permission metadata, onboarding requirements, copy, icons, and action labels used by onboarding and Settings
- `TranscriptedStoragePaths.swift` — canonical app-support path helpers for captures, state, cache, logs, and temporary files
- `TranscriptionModelPreferences.swift` — persisted local transcription-model selection shared by dictation and meetings

## Current notes

- Keep preference keys and notification names centralized here so UI and controllers do not drift.
- `PhysicalDictationTriggerPreferences` is the canonical binding layer for push-to-talk, hands-free dictation, paste-last-dictation, and meeting shortcuts. Avoid reintroducing ad hoc keycode logic or special-case right-Option handling in UI or capture code.
- `TranscriptionModelPreferences` is the shared switch between `Parakeet`, the available local Whisper variants, and the beta-gated Nemotron streaming model (`SpeechModelBetaPreferences` controls its availability; `effectiveModel()` falls back to the default while the gate is off). Model-specific runtime behavior still belongs in `Sources/Speech/` and `Sources/Meeting/`.
- `CustomDictionaryPreferences` and `DictationAutoSendPreferences` back the Settings `General` and `Dictation` pages. If you change parsing rules or policy thresholds, update the relevant tests.
- `TranscriptedPermissionAccess` plus `TranscriptedPermissionKind` are the app-level permission seams. UI flows should call into them instead of duplicating TCC branching, metadata, or user-facing permission copy.
- `SpeakerNameSelectionPolicy` keeps speaker search and "You" matching consistent across settings and review UI. Keep duplicate-name disambiguation here instead of in individual SwiftUI controls.
- `PermissionsOnboardingPreferences` is the canonical completion flag for the guided first-run permissions flow. Keep onboarding state out of view-local storage so forced reruns and completion state stay consistent.
- `TranscriptedStoragePaths` should stay as the canonical path resolver for the app target. `Sources/TranscriptedCore/Services/CoreStoragePaths.swift` is the injected library-side seam.
- `ClaudeDesktopIntegrationInstaller` owns the `mcpServers` JSON config merge (Claude Desktop and Cursor). Preserve existing MCP servers and back up invalid JSON instead of overwriting blindly.
- `AgentMCPConnector` is the seam for connecting more agents. New agents should get a detect/isConnected/connect triple here instead of bespoke UI logic; never rewrite `~/.claude.json` directly — Claude Code's CLI owns that file.
- `DockVisibilityPreferences` is the canonical storage layer for the General Dock toggle. Keep the key and notification stable so upgrades preserve the setting.
- `ActivationPolicyController` is the canonical place for the app's force-quit visibility policy. Keep Dock/icon activation-policy switching out of recording controllers and UI views.
- `QuitConfirmationPreferences` should default on. Quitting during a live meeting stops capture, so the opt-out belongs in Settings instead of being hidden in the alert.
- `MicrophoneProcessingPreferences` is the canonical switch for mic cleanup mode. Default behavior is software AGC without playback ducking; Apple voice processing stays opt-in because it can duck other apps during recording, and can be enabled from Settings or the in-meeting boost prompt.
- `AudioStoragePreferences` only stores the retention choice. Destructive cleanup behavior belongs in `Sources/Meeting/MeetingAudioStorageManager.swift` and should stay conservative: the Settings UI should ask before switching into a destructive 7-day or 30-day cleanup window.

## Verification

After changing support code:

```bash
bash build.sh --no-open
bash run-tests.sh
```

Relevant direct coverage includes:

- `Tests/AgentMCPConnectorTests.swift`
- `Tests/CaptureLibraryChangeBroadcasterTests.swift`
- `Tests/CaptureLibraryMigrationPlannerTests.swift`
- `Tests/ClaudeDesktopIntegrationInstallerTests.swift`
- `Tests/ActivationPolicyControllerTests.swift`
- `Tests/AudioStoragePreferencesTests.swift`
- `Tests/LiveMeetingCodexPreferencesTests.swift`
- `Tests/ClipboardRestoringTextPasterTests.swift`
- `Tests/CustomDictionaryPreferencesTests.swift`
- `Tests/DictationAutoSendPreferencesTests.swift`
- `Tests/DictationOverlayPresentationPreferencesTests.swift`
- `Tests/HotkeyPreferencesTests.swift`
- `Tests/LaunchAtLoginPreferencesTests.swift`
- `Tests/LocalMeetingSummaryPreferencesTests.swift`
- `Tests/MeetingOverlayPillPreferencesTests.swift`
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
- `Tests/SpeechModelBetaPreferencesTests.swift`
