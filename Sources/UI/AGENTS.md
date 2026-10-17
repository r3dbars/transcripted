# Sources/UI

Every surface the person sees: the Notch island and dictation session, the menu bar popover, the main window (Today, Meetings, Dictations, Writing, Speakers, Agent, Settings), onboarding, and the helpers they share. Four modules, one folder each; each has its own card with the file list, rules and tests.

| Folder | Module | Card |
|---|---|---|
| `Overlay/` | `UIOverlay` | `Sources/UI/Overlay/AGENTS.md`: Notch island, dictation session, meeting and call-prompt controllers |
| `MenuBar/` | `UIMenuBar` | `Sources/UI/MenuBar/AGENTS.md`: status item and popover |
| `Settings/` | `UISettings` | `Sources/UI/Settings/AGENTS.md`: main window, Home, Today, speakers, onboarding, Agent page |
| `Shared/` | `UIShared` | `Sources/UI/Shared/AGENTS.md`: scanners, rename/delete/undo, playback, design tokens |

Read the card for the folder you're editing first. Dependency edges live in `.agents/modules.json`; `python3 scripts/dev/check-module-boundaries.py --explain <file>` names one file's module and what it may import. UIShared sits at the bottom and may not name UIOverlay, UIMenuBar, UISettings or AppState.

## Rules for all of UI

- **Controllers own state, views render it.** Controllers own Combine subscriptions and push explicit `update(...)` calls into AppKit views. Settings is the exception: its SwiftUI pages can hold local `@State` and `@ObservedObject` view models, but side effects still go through injected controllers, preference helpers or `TranscriptedSettingsActions`, so the window doesn't become another app coordinator.
- **Policy before view.** Copy, timing and "should this show" decisions live in Foundation-pure `*Policy` / `*Presentation` files with direct tests. Put a UI tweak there, not in a controller or view.
- **TCC prompts are user-initiated.** Background warmup never requests microphone, system-audio-recording or calendar access. Onboarding and Settings own those prompts so the dialog appears in context. Shared permission logic is `Sources/Support/TranscriptedPermissionAccess.swift`.
- **Overlays stay out of screen capture and never steal focus.** Details in the Overlay card.
- **Keep the product surface** (root `AGENTS.md`): meeting detection prompt, Speakers directory, per-app Auto Enter, model-cache cleanup, status-item click behavior, retained-audio playback.
- **Saved meetings change one way.** Rename, delete, Undo and dictionary fixes go through `Shared/` and the transcript-update serializer (Shared card).
- **Source pins.** Several UI files are pinned by tests that read source as text (`PermissionsOnboardingView.swift`, `QuietHomeLibrary.swift`, `MeetingOverlayController.swift`, `SpeakerPeopleSettingsSection.swift`, `DictationSessionController.swift`), and `Tests/OverlayScreenSharePrivacyTests.swift` scans all of `Sources/UI`. Run `python3 scripts/dev/check-source-pins.py --changed-only` before editing.
- **Finding a label.** Settings copy is inline. Grep the exact quoted text instead of reading the big files.

## Cross-surface behavior

- **Main window is content-first.** Sidebar order: Today, Meetings, Dictations, Writing, Speakers, Agent; it opens on Today. The sidebar gear opens one combined scrolling settings page (no tab strip). Meetings is the `.home` page case; the raw value stays `home` so automation ids and analytics `page_id` don't change. `HomeView` loads small paged slices, and `SettingsRecentCaptureRefreshPolicy` limits refreshes to the pages that need them.
- **Speaker naming happens in the island.** After a meeting, the island's speaker review (`NotchIslandSpeakerReviewView`, Overlay) names or confirms voices; `Settings/SpeakerNamingSheet.swift` only presents it, and never on top of a recording meeting. The Speakers page (Settings) is where unnamed voices wait. `TranscriptedSettingsView` owns the persisted local-mic diarization toggle.
- **Agent connect is a Settings page.** One row per agent found on the Mac with one Connect button, all pointing the agent's MCP config at the same installed helper; a copy-prompt row covers agents we can't configure; folders, the Codex inbox and config details stay under Advanced. Onboarding has no connect stage. Copy and paths: `Shared/AgentConnectionGuide.swift`.
- **Dictation shortcut.** One key with a behavior (hold or tap, hold only, tap to toggle; `Sources/Support/HotkeyPreferences.swift`). Presentation code takes the take's `DictationShortcutMode` (push-to-talk vs a take kept listening hands-free) only to word notices.

## Verify

```bash
bash build.sh --no-open
bash run-tests.sh                                  # or --filter <name>
bash scripts/ops/transcripted-qa-bench.sh --mode ui   # menu bar, Home, Settings, navigation; needs Accessibility
```

If `bash scripts/dev/concurrency-census.sh --check` flags new UI warnings, the usual fixes are a constant that becomes `nonisolated static let` (`Shared/CaptureUndo.swift`) and off-main work through a continuation over GCD (`Shared/RecentCaptureScanners.swift`). After clearing older warnings, `bash scripts/dev/concurrency-census.sh --shrink`.

Manual checks by area (do the ones your change touches):

- Dictation: starts, stops and pastes cleanly; the island's hover, messages and cap countdown still read right.
- Meetings: the detected-meeting prompt appears only when it should and Record / Not now / Remind work; the overlay records cleanly; imported audio from the menu bar lands in Meetings.
- Home: opens quickly and load-more works on a large library; retained audio plays (clicking a row's time plays from there; the transcript doesn't follow the playhead); failed meetings offer play, reveal in Finder and retry from the preserved files.
- Speakers: clips preview, duplicates surface, rename and merge work; the island review names voices, plays clips, and Later leaves the rest for Speakers.
- Menu bar, Settings window, permissions onboarding and the first-run window open correctly; first-run CTA copy follows permission and model state.

Direct tests live in `Tests/` named for the file they cover (`NotchIsland*Tests`, `Dictation*Tests`, `MenuBar*Tests`, `Home*Tests`, `Today*Tests`, `Speaker*Tests`); each card lists its own. `Tests/UIAutomationSurfaceContractTests.swift` pins the AX surface external automation relies on.
