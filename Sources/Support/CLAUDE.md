# Support Directory

## What this directory does

`Sources/Support/` holds app-wide helpers that do not belong to a single UI or pipeline surface. These types mostly wrap persisted preferences, shared constants, permission access, storage paths, or low-level paste / launch behavior used across dictation and meetings.

## Files

- `ActivationPolicyController.swift` — combines the Dock toggle with live-recording safety so Transcripted can idle as menu-bar-only but still surface itself in the macOS force-quit dialog during active capture
- `AutomatedLaunchEnvironment.swift` — the one check for "this launch is our own harness" (build.sh launch smoke, launch benchmark, packaged first-run smoke); analytics, Sentry, the setup resume step, Sparkle and the permission probes all skip real-user behavior when it is active
- `AudioStoragePreferences.swift` — persisted meeting-audio retention window for Settings and background retained-audio maintenance
- `AutoCallDetectionPreferences.swift` — persisted (default-on) toggle for ad-hoc call detection via mic activity; gates `MicActivityMonitor` and the General-page "Auto-detect calls" setting (see `docs/auto-call-detection-spec.md`)
- `AgentMCPConnector.swift` — per-agent MCP connect seam: detection, connection state, and config writers for Claude Code (via the `claude` CLI), Codex (`~/.codex/config.toml`), and Cursor (`~/.cursor/mcp.json`), all pointing at the shared installed helper
- `CaptureLibraryChangeBroadcaster.swift` — single source of truth for the debounced `.meetingCaptureArtifactsDidChange` notification; coalesces background WAV→M4A recompression and transcript-rename file mutations so Home can re-resolve its cached transcript/audio URLs (empty id set means a library-wide change of unknown scope)
- `CaptureLibraryPathSafety.swift` — the dependency-free (pure Foundation) definition of the save-path safety predicate (system-directory rejection with a home-directory escape hatch) so `RecordingValidator.validateSavePath` (TranscriptedCore), `CaptureLibraryResolver.validatedConfiguredDirectory` (TranscriptedCaptureKit), and `TranscriptedStoragePreferences.isSafeCaptureLibraryURL` here all enforce the same rule. This is a SYNCED COPY: byte-identical real files (not a symlink — a `core.symlinks=false` checkout would materialize one as a broken text file) also live at `Sources/TranscriptedCore/Services/CaptureLibraryPathSafety.swift` and `Tools/TranscriptedCaptureKit/Sources/TranscriptedCaptureKit/CaptureLibraryPathSafety.swift`. Edit all three together; `Tests/CaptureLibraryPathSafetySyncTests.swift` fails if they diverge.
- `CaptureLibraryMigrationPlanner.swift` — copy-only planning and execution for capture-library relocation: detects captures in the old folder, enumerates meeting Markdown plus retained `audio/*_audio/` directories plus dictation day files, skips destination collisions, and never deletes originals
- `CaptureLibrarySize.swift` — once-per-launch on-disk size measurement/bucketing for the capture library, reported next to the retention setting so unbounded retained-audio growth is visible in the event log
- `ClaudeDesktopIntegrationInstaller.swift` — installs the bundled read-only MCP helper for Claude Desktop, safely merges `mcpServers` JSON configs, runs the helper self-test, and silently refreshes a stale installed helper at app launch
- `ClipboardRestoringTextPaster.swift` — paste helper that preserves clipboard contents while inserting the latest dictation into the target app; its local-only timing separates clipboard preparation, Cmd+V dispatch, target read, and confirmation wait. When the target exposes no confirmation surface at all (common for Electron apps, which build no AX tree unless an assistive client asks), a post-dispatch target read ends the confirmation wait for Auto Enter and non-Auto-Enter pastes alike — no confirmation can ever arrive there, so the remaining window is dead time. Targets that do expose a confirmation surface keep the full wait. When nothing confirmed the paste but the target stayed frontmost and read the borrowed clipboard within `clipboardLikelyPasteReadWindow` of Cmd+V, the outcome is `.likelyPasted`: the overlay says "Pasted", the user's clipboard is restored after the longer fallback delay (the read isn't tied to a process, so a slower real reader must still get the dictation), telemetry reports `target_confirmation_mode=clipboard_read`, and Auto Enter still holds Return (`paste_unverified`). The borrowed clipboard item carries the nspasteboard.org `TransientType` marker so clipboard managers skip it instead of reading it. Otherwise the text stays on the clipboard for a manual Cmd+V with neutral wording (a slow target may still paste, so the notice must not invite a double paste), and the clipboard it replaced is kept in the shared `clipboardSavedBeforeFallback` slot for up to `clipboardSavedBeforeFallbackMaxAge`; the next paste from any paster restores it if nothing else was copied in between. A clipboard carrying an nspasteboard.org Concealed/Transient/AutoGenerated marker is never kept for later, and snapshots keep those empty markers so a restored password stays marked. A new paste first runs any other paster's still-waiting restore (unless that paster is mid-paste), and `restorePendingClipboardsBeforeQuit()` runs them all from `applicationWillTerminate`.
- `CustomDictionaryPreferences.swift` — persisted custom spoken-term replacements plus text post-processing helpers; `CustomDictionaryTextProcessor.matcher(for:)` is also what `Sources/UI/Shared/DictionaryPastMeetingFix.swift` uses to fix past meetings, so past and new fixes match the same way
- `DockVisibilityPreferences.swift` — persisted General setting for whether Transcripted should stay visible in the Dock while idle
- `DictationAutoSendPreferences.swift` — persisted auto-send rules, allowed bundle list, and keypress-sending helpers for pasted dictation
- `DictationPersistentInputPreferences.swift` — persisted faster-Bluetooth-dictation opt-in, preferred CoreAudio device UID, and crash-recovery ownership marker
- `DictationCleanupPreferences.swift` — persisted General toggle for filler-word cleanup after dictation
- `DictationFillerCleanupPolicy.swift` — text cleanup policy for light dictation filler removal
- `DictationOverlayPresentationPreferences.swift` — persisted overlay presentation mode for normal vs cursor-mini dictation UI
- `ExistingInstallModelPrefetchPolicy.swift` — protects existing Parakeet users by deciding when model files should be prefetched after app updates
- `HotkeyPreferences.swift` — persisted shortcut mode, meeting shortcut compatibility, legacy Carbon hotkey migration helpers, right-Option toggle migration, display formatting, and validation
- `LaunchAtLoginController.swift` — app-facing wrapper for enabling or disabling launch-at-login behavior, including the one-time post-onboarding default-enable (meeting detection is dead while the app is closed)
- `LaunchAtLoginPreferences.swift` — persisted preference state around launch-at-login UX: the explicit user choice plus the applied-once default-enable marker and its pure policy
- `MissedCallNudgePreferences.swift` — persisted (default-on) toggle for the post-call "that call wasn't recorded" nudge; written only by the nudge's "Don't show again" action (the Settings toggle was removed in the 2026-08 settings simplification)
- `LocalSpeakerPreferences.swift` — persisted toggle for splitting the local mic channel into multiple named speakers during meeting review
- `MeetingOverlayPillPreferences.swift` — persisted "keep controls visible" pin that opts the meeting pill out of resting to its compact capsule
- `MeetingMicrophonePreferences.swift` — explicit use of the macOS-selected meeting input, default off to retain Bluetooth call isolation; read before each recording, not during capture
- `MicrophoneProcessingPreferences.swift` — persisted mic processing mode, toggling between raw/off input, default software AGC, and optional Apple voice processing (VPIO) for users who need the WebRTC-specific recovery path in meetings or dictation. The in-meeting Boost Mic never writes it, and the Home row's "Boost mic next meeting" sets a one-shot request that the next successful meeting start uses up (meetings only). `migrateBoostedVoiceProcessingIfNeeded` runs once at launch to undo Boosts saved by older builds; it and the Home request also set `micBoostHintsHiddenThrough` so answered Home hints don't come back on older rows
- `CallAppMicrophoneSharingMonitor.swift` — watches for desktop call apps (Zoom, Teams, Webex, FaceTime) by app presence only, never opening audio. While one is open at a recording's start, meetings and dictation stay on software autogain instead of Apple voice processing. Mid-meeting, the Boost Mic prompt checks real mic use instead (`MicrophoneSharingPolicy.isCallAppUsingMicrophone`, fed by `MicActivityMonitor.currentMicInputBundleIDs()`), so Teams left open during a browser call doesn't block it
- `ZoomMicrophoneSharingMonitor.swift` — old names (`ZoomMicrophoneSharingMonitor`, `isZoomRunning`) kept for branches written before the rename; delete once nothing uses them
- `ModelCacheInventory.swift` — scans and cleans known local model cache roots for Settings storage controls; despite living in `Support/`, it inventories `Sources/Speech/` STT model caches (Parakeet/Whisper), not app-wide caches
- `SpeakerEmbedderFactory.swift` — app-layer resolution of the optional speaker-embedding model; keeps `Bundle.main`/filesystem lookups out of `TranscriptedCore` and hands the meeting controller a ready `SpeakerSegmentEmbedder` or nil
- `SpeakerEmbedderPreferences.swift` — persisted choice between the diarizer's built-in WeSpeaker embedder and the optional ERes2Net model used for same-voice consolidation and cross-call speaker matching; mirrors `TranscriptionModelPreferences`
- `OnboardingDictationShortcutPolicy.swift` — first-run shortcut policy that keeps dictation setup copy aligned with trigger preferences
- `PermissionsOnboardingPreferences.swift` — persisted completion and forced-rerun state for the first-run permissions onboarding flow
- `PhysicalDictationTriggerPreferences.swift` — canonical physical key / modifier trigger bindings for push-to-talk, hands-free dictation, paste-last-dictation, and meeting shortcuts, including migration from older right-Option settings
- `QuitConfirmationPreferences.swift` — always-on quit safety policy and copy for warning before active meeting recordings are stopped by app quit (the opt-out preference was removed by owner decision in the 2026-08 settings simplification)
- `SingleInstanceGuard.swift` — local guard used to keep duplicate app instances from racing shared app state
- `SpeakerNameSelectionPolicy.swift` — shared speaker-name matching, duplicate-label disambiguation, and owner-label policy used by people/review UI
- `TranscriptedConstants.swift` — shared timing thresholds and app-wide behavior constants
- `TranscriptedPermissionAccess.swift` — shared permission status, prompting, and Settings-deep-link helpers for microphone, accessibility, system-audio recording, and calendar access
- `TranscriptedPermissionKind.swift` — shared permission metadata, onboarding requirements, copy, icons, and action labels used by onboarding and Settings
- `TranscriptedStoragePaths.swift` — canonical app-support path helpers for captures, state, cache, logs, and temporary files
- `TranscriptionModelPreferences.swift` — persisted local transcription-model selection shared by dictation and meetings

## Current notes

- Naming trap: `Support/CaptureLibrary*.swift` (`CaptureLibraryChangeBroadcaster`, `CaptureLibraryMigrationPlanner`, `CaptureLibrarySize`) is capture-**library** migration/relocation/change-broadcast logic — the user-relocatable folder of saved meeting/dictation Markdown and audio. It is unrelated to `Sources/Capture/`, which is screen/audio capture triggering (`ContextCaptureEngine`, physical hotkey routing). Same "capture" word, different subsystem — do not conflate them when searching or routing changes.
- Naming trap: `ModelCacheInventory.swift` lives in `Support/` but inventories `Sources/Speech/` STT model caches, not a generic app cache. If you're looking for Speech model cache logic, check here first.
- Keep preference keys and notification names centralized here so UI and controllers do not drift.
- `PhysicalDictationTriggerPreferences` is the canonical binding layer for push-to-talk, hands-free dictation, paste-last-dictation, and meeting shortcuts. Avoid reintroducing ad hoc keycode logic or special-case right-Option handling in UI or capture code.
- `TranscriptionModelPreferences` is the shared switch between `Parakeet` and the available local Whisper variants; unknown persisted raw values (including the retired Nemotron beta) fall back to the default model. The experimental `parakeetUltraExperimental` choice maps to `ParakeetModelVariant.ultra`, a local-install-only variant (never downloaded or bundled) that `ModelCacheInventory` resolves from `~/Library/Application Support/Transcripted/models/parakeet-ultra/parakeet-tdt-0.6b-v3` only when the install marker is present; `TranscriptionModelVisibilityPolicy` hides it from the picker until then. See `scripts/models/parakeet-ultra/README.md`. Model-specific runtime behavior still belongs in `Sources/Speech/` and `Sources/Meeting/`.
- `CustomDictionaryPreferences` and `DictationAutoSendPreferences` back the Settings `General` and `Dictation` pages. If you change parsing rules or policy thresholds, update the relevant tests.
- `TranscriptedPermissionAccess` plus `TranscriptedPermissionKind` are the app-level permission seams. UI flows should call into them instead of duplicating TCC branching, metadata, or user-facing permission copy. Meeting audio uses the narrow `systemAudioRecording` tier and never requests full Screen Recording access.
- `SpeakerNameSelectionPolicy` keeps speaker search and "You" matching consistent across settings and review UI. Keep duplicate-name disambiguation here instead of in individual SwiftUI controls.
- `PermissionsOnboardingPreferences` is the canonical completion flag for the guided first-run permissions flow. Keep onboarding state out of view-local storage so forced reruns and completion state stay consistent.
- `TranscriptedStoragePaths` should stay as the canonical path resolver for the app target. `Sources/TranscriptedCore/Services/CoreStoragePaths.swift` is the injected library-side seam.
- `ClaudeDesktopIntegrationInstaller` owns the `mcpServers` JSON config merge (Claude Desktop and Cursor). Preserve existing MCP servers and back up invalid JSON instead of overwriting blindly.
- `ClaudeDesktopIntegrationInstaller` also refreshes the helper's owner-only `mcp-observability.plist`; copy only validated app version/channel/revision values and remove the file when anonymous analytics is off or PostHog config is invalid.
- `AgentMCPConnector` is the seam for connecting more agents. New agents should get a detect/isConnected/connect triple here instead of bespoke UI logic; never rewrite `~/.claude.json` directly — Claude Code's CLI owns that file.
- `DockVisibilityPreferences` is the canonical storage layer for the General Dock toggle. Keep the key and notification stable so upgrades preserve the setting.
- `ActivationPolicyController` is the canonical place for the app's force-quit visibility policy. Keep Dock/icon activation-policy switching out of recording controllers and UI views.
- Quit confirmation during meeting work is always on; there is no opt-out preference. Quitting during a live meeting stops capture, so the dialog is not optional.
- `MicrophoneProcessingPreferences` is the canonical switch for mic cleanup mode. Default behavior is software AGC without playback ducking; Apple voice processing stays opt-in because it can duck other apps during recording, and can be enabled from Settings. The in-meeting boost prompt and the Home "Boost mic next meeting" row apply it to one meeting only.
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
- `Tests/CaptureLibraryPathSafetySyncTests.swift`
- `Tests/ClaudeDesktopIntegrationInstallerTests.swift`
- `Tests/ActivationPolicyControllerTests.swift`
- `Tests/AudioStoragePreferencesTests.swift`
- `Tests/ClipboardRestoringTextPasterTests.swift`
- `Tests/CustomDictionaryPreferencesTests.swift`
- `Tests/DictationAutoSendPreferencesTests.swift`
- `Tests/DictationOverlayPresentationPreferencesTests.swift`
- `Tests/HotkeyPreferencesTests.swift`
- `Tests/LaunchAtLoginPreferencesTests.swift`
- `Tests/MeetingOverlayPillPreferencesTests.swift`
- `Tests/MicrophoneProcessingPreferencesTests.swift`
- `Tests/PermissionsOnboardingPreferencesTests.swift`
- `Tests/PhysicalDictationTriggerPreferencesTests.swift`
- `Tests/QuitConfirmationPreferencesTests.swift`
- `Tests/SpeakerNameSelectionPolicyTests.swift`
- `Tests/TranscriptedConstantsTests.swift`
- `Tests/TranscriptedPermissionAccessTests.swift`
- `Tests/TranscriptedStoragePathsTests.swift`
- `Tests/TranscriptionModelPreferencesTests.swift`
