# FloatingPanel

Morphing pill UI (Dynamic Island style) with aurora state views, saved notification card, transcript tray, and speaker naming dialog. 21 Swift files across root, Components/, and Helpers/.

## File Index

### Root (4 files)

| File | Purpose |
|------|---------|
| `PillStateManager.swift` | State machine: idle -> recording -> processing -> saved. Timeout recovery, sound feedback. |
| `FloatingPanelView.swift` | Root SwiftUI view. Tray mux (none/transcripts/speakerNaming), toast layer, pill content switch. |
| `FloatingPanelController.swift` | NSWindowController. Position persistence, Combine subscriptions to Audio/TaskManager, window setup. |
| `PillCalloutController.swift` | NSWindowController for onboarding callout positioned above the pill. |

### Components/ (16 files) — see Components/CLAUDE.md

| File | Purpose |
|------|---------|
| `AuroraIdleView.swift` | Collapsed pill (52x26px). Hover-expands to 160x36px with Record + Transcripts buttons. |
| `AuroraRecordingView.swift` | Recording state (160x36px). LED dots: coral (mic) + teal (system). Timer + stop. |
| `AuroraProcessingView.swift` | Processing state (160x36px). Progress bar + status text. Warning at 90s+. |
| `SavedPillView.swift` | Saved notification card (260x56px). Title, duration, speakers, Copy/Open buttons. Green accent. |
| `TranscriptTrayView.swift` | Recent transcript list (280x300px max). Frosted glass. Date separators. Click-outside dismissal. |
| `TranscriptRowView.swift` | Single row in transcript tray: title, relative date, duration, copy button. |
| `TranscriptDetailView.swift` | Single transcript viewer. Groups lines by speaker with colored left borders. |
| `SpeakerNamingView.swift` | Post-recording speaker naming. Play clips, confirm/reject names, merge profiles. |
| `SpeakerNamingCard.swift` | Individual speaker card: name input, autocomplete, confirm/reject/merge actions. |
| `ClipAudioPlayer.swift` | AVAudioPlayer wrapper for speaker clip playback (one at a time). |
| `ToastNotificationView.swift` | Slides in from bottom, shows error with context, auto-dismisses after 8s. |
| `ContextualErrorBanner.swift` | ContextualError enum: classifies errors by keyword into typed categories with recovery hints. |
| `PillErrorView.swift` | Coral-tinted pill with shake animation for errors. |
| `PillCalloutView.swift` | Coach mark callout SwiftUI view with arrow and glassmorphism background. |
| `PillOverlayViews.swift` | FailedBadgeOverlay (red circle count), RecordingDotView, SystemAudioWarningIndicator. |
| `AttentionPromptView.swift` | Silence warning + still-recording detection prompt. |

### Helpers/ (1 file)

| File | Purpose |
|------|---------|
| `LawsComponents.swift` | AnimatedDotsView (cycling "..." at 0.4s), LawsButton (hover/press states), LawsStatusTextView (DisplayStatus -> icon+text), FloatingTooltipModifier (1s hover delay), Triangle shape (connector), Color.retroGreen extension |

## Pill State Machine (PillStateManager.swift)
```
States:
  idle       -> 52x26px capsule (hover-expands to 160x36px)
  recording  -> 160x36px with LED dots + timer + stop button
  processing -> 160x36px with progress bar + status text
  saved      -> 260x56px notification card with title, duration, speakers

Timing:
  morphDuration: 0.175s    cooldownDuration: 0.175s
  contentFade: 0.1s        transitionTimeout: 2.0s (force-reset if stuck)

Sounds:
  -> recording:  "Pop"     recording -> processing: "Tink"
  any -> saved: "Glass"    -> failed: "Basso"

Lock mechanism:
  lock()   -> prevents state changes (during review tray)
  unlock() -> releases lock, optionally resets to idle
  forceUnlock() -> emergency: clears all flags, forces idle
```

## Tray States (mutually exclusive overlays)
```
case none           -> pill only
case transcripts    -> scrollable transcript list (dismisses when pill -> processing)
case speakerNaming  -> naming dialog (STICKY - persists during pill state changes)
```

## View Hierarchy (FloatingPanelView.swift)
```
FloatingPanelView (320pt wide)
  |-- Spacer (pushes content to bottom)
  |-- SpeakerNamingView OR TranscriptTrayView (conditional)
  |-- Toast layer (ToastNotificationView, floats 60pt above pill when no tray)
  +-- Pill content (morphs between states)
      |-- idle -> AuroraIdleView (failed badge, processing pulse dot)
      |-- recording -> AuroraRecordingView (LED dots, audio-reactive)
      |-- processing -> AuroraProcessingView (progress bar)
      +-- saved -> SavedPillView (title, duration, speakers, Copy/Open)
```

## FloatingPanelController - Window Setup
- NSPanel: borderless, nonactivatingPanel, floating level, canJoinAllSpaces
- `isMovableByWindowBackground = true` (drag anywhere)
- Transparent background, no shadow, always visible (`hidesOnDeactivate = false`)
- `canBecomeKey = false` by default (doesn't steal focus). Set true during speaker naming.
- Position saved to UserDefaults: `floatingPanelX`, `floatingPanelY`
- Dock height detected via `visibleFrame.origin.y - screenFrame.origin.y`

## Combine Subscriptions (FloatingPanelController — State Sync)
```
audio.$isRecording (.debounce 50ms):
  true  -> transition(to: .recording)
  false -> .processing (if status.isProcessing) or .idle

taskManager.$displayStatus:
  .gettingReady      -> show processing 1.5s, return to idle
  .transcriptSaved   -> transition to .saved 10s (guard: !isRecording, !speakerNaming)
  .failed            -> play error sound, show processing 4.0s

taskManager.$speakerNamingRequest:
  != nil -> panel.allowKeyFocus = true, makeKey()
  == nil -> panel.resignKey()
```

## Recording Visualization (Components/AuroraRecordingView.swift)
- **LED dots** — point light source style, coral (mic, left) + teal (system, right)
- Core: 3-4.5px, opacity 40-100%. Halo: 8-22px diameter, opacity 8-33%, radial gradient
- Audio level smoothing: attack 0.55 (snappy rise), decay 0.15 (quick fade)
- Layout: stop button, mic LED, timer (14pt monospaced), system LED, transcripts button

## Speaker Naming Flow (Components/SpeakerNamingView.swift + SpeakerNamingCard.swift)
```
SpeakerNamingView appears -> 3-second dismiss guard (prevents accidental close)
  Per speaker (SpeakerNamingCard):
    - Play audio clip via ClipAudioPlayer (one at a time)
    - IF needsNaming: text input + autocomplete from SpeakerDatabase
    - IF needsConfirmation: show name + similarity% + Confirm/Reject
    - IF mergeCandidate: "Link to [name]?" + checkmark/X
  onUpdate callback: SpeakerNameUpdate { persistentSpeakerId, newName, action }
    actions: .named, .corrected, .confirmed, .merged(targetProfileId)
```

## Error Toast System (Components/ContextualErrorBanner.swift + ToastNotificationView.swift)
```
ContextualError.from(message: String) -> classifies by keywords:
  "microphone/mic" -> .microphoneError
  "speech/transcri" -> .transcriptionFailed
  "network/connection" -> .networkError
  "disk/storage/full" -> .storageFull
  "permission/denied" -> .permissionDenied
  default -> .unknown
Each has: icon, title, recoveryHint, color (amber or red)
Auto-dismiss: 8 seconds. Hidden when tray is open.
```

## Escape Key Handling (FloatingPanelController.swift)
- Local monitor (app frontmost) + Global monitor (other app frontmost)
- Speaker naming: 3-second guard before allowing dismiss
- Transcript tray: dismiss immediately
- Monitors installed/removed on trayState change

## Key Splits from Original Files
- `ErrorViews.swift` split into: ToastNotificationView, ContextualErrorBanner, PillErrorView
- `SpeakerNamingView.swift` split out: SpeakerNamingCard, ClipAudioPlayer
- `TranscriptTrayView.swift` split out: TranscriptRowView
- `PillCalloutController.swift` + `PillCalloutView.swift` are new (onboarding callout)
- `PillOverlayViews.swift` is new (badge + pulse dot extracted from other views)

## Design Tokens Used
Colors: panelCharcoal, panelCharcoalElevated, panelCharcoalSurface, panelTextPrimary/Secondary/Muted, recordingCoral, auroraCoral/CoralLight, auroraTeal/TealLight, accentBlue, statusSuccessMuted, statusErrorMuted, statusWarningMuted, systemAudioIndicator
Dimensions: PillDimensions (idleWidth:40, recordingWidth:160, recordingHeight:36, savedWidth:260, savedHeight:56, trayWidth:280, trayMaxHeight:300)
Animations: .pillMorph, .trayExpand, .pillContentFade

## All files are @MainActor (SwiftUI views + NSWindowControllers)

## Gotchas
- Naming tray is STICKY (persists across pill states), transcript tray is NOT (auto-closes on processing)
- Toast notification space collapses to 0pt when tray is open
- SavedPillView auto-dismiss (10s) is controlled by FloatingPanelController, not the view itself
- `.idle` status handler guards against collapsing pill when in `.saved` state (prevents 4s reset preempting 10s saved card)
- Speaker colors are hash-based (name % 5 palette), user always gets .accentBlue
- Silence prompt triggers at 120s of silence (not recording duration)
- Copy button in SavedPillView shows checkmark 1.5s then reverts
- PillCalloutController positions itself relative to the pill's NSWindow frame
- Click-outside monitor (global NSEvent) dismisses transcript tray when clicking outside the panel
