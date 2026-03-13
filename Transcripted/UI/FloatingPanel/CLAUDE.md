# FloatingPanel — CLAUDE.md

## Purpose
The main user-facing UI: a draggable floating pill that shows recording state, audio visualizations, processing progress, transcript tray, and speaker naming flow. Implements a state machine with animation guards and stuck-state recovery.

## Files

| File | Responsibility |
|---|---|
| `FloatingPanelController.swift` | NSWindowController for floating NSPanel, drag handling, position persistence, state observer wiring |
| `PillStateManager.swift` | State machine: idle → recording → processing, with transition guards and cooldown |
| `FloatingPanelView.swift` | Main SwiftUI composition, routes to state-specific views, manages trays and overlays |
| `Components/PillViews.swift` | Idle pill (collapsed 40×24 / expanded ~120×28), slide-out record/files buttons, badges |
| `Components/WaveformViews.swift` | EdgePeekView, WaveformMiniView (8-bar dual-layer), DormantWaveformView, MinimalWaveformIcon |
| `Components/AuroraIdleView.swift` | Idle state: collapsed capsule (40×20) or expanded with record/files buttons (200×44) |
| `Components/AuroraRecordingView.swift` | Canvas-based aurora fog (mic=coral, system=teal), timer, stop button. Auto-collapses after 5s |
| `Components/AuroraProcessingView.swift` | Progress-based aurora opacity/speed, status text with animated dots, warning for long runs |
| `Components/AuroraSuccessView.swift` | Green radial glow, checkmark bounce animation sequence (3 phases) |
| `Components/CelebrationViews.swift` | PillSuccessCelebration, CelebrationOverlay (.recordingStopped/.transcriptSaved) |
| `Components/ErrorViews.swift` | ToastNotificationView (slide-in, 5s auto-dismiss), PillErrorView (shake), ContextualError parser |
| `Components/AttentionPromptView.swift` | "Still recording?" silence prompt (triggers at 120s silence, 10s auto-dismiss) |
| `Components/TranscriptTrayView.swift` | Frosted glass tray (280×300), recent 10 transcripts, copy-to-clipboard, detail navigation |
| `Components/TranscriptDetailView.swift` | Chat bubble layout with MessageGroup grouping, right-aligned user/left-aligned others |
| `Components/SpeakerNamingView.swift` | Sticky naming tray, speaker cards with audio playback, merge awareness, NOT dismissible by Escape |
| `Helpers/LawsComponents.swift` | AnimatedDotsView, LawsButton, LawsStatusTextView, FloatingTooltipModifier, Triangle shape |

## Key Types

**PillState** (enum): `.idle` (40×20) | `.recording` (180×40) | `.processing` (180×40)

**PillStateManager** (@MainActor, ObservableObject):
- `@Published state: PillState`, `isTransitioning: Bool`, `isLocked: Bool`
- `transition(to:)` — main method with guards: cooldown, lock check, stuck-state timeout (2s)
- `lock()` / `unlock(transitionToIdle:)` — review mode control
- `forceUnlock()` — emergency recovery bypassing all guards
- Sound feedback: Pop (→recording), Tink (→processing), Glass (→idle)

**FloatingPanelController** (NSWindowController):
- Window: borderless, non-activating NSPanel, `.floating` level, `canJoinAllSpaces`
- Position persistence: UserDefaults `floatingPanelX`/`floatingPanelY`, saved on `windowDidMove`
- `hidesOnDeactivate = false` — stays visible when app loses focus
- Observers: `audio.isRecording` → pill state, `taskManager.displayStatus` → processing states, `taskManager.speakerNamingRequest` → naming tray

**ContextualError** (enum): Parses error messages → type, icon, color, recoveryHint. Maps permission/network/storage/processing errors to appropriate display.

## State Machine

```
idle → recording    (Audio.isRecording becomes true)
recording → processing  (Audio.isRecording becomes false, transcription starts)
processing → idle   (transcriptSaved, auto-reset after 2.5s celebration)
```

**Transition guards** (in order):
1. Stuck-state timeout: 2s max transition duration, auto-force-reset
2. Lock guard: don't transition while locked (except to .idle)
3. Same-state check: no-op if already in target state
4. Cooldown guard: `PillAnimationTiming.cooldownDuration` between transitions

**DisplayStatus → Pill transitions** (in FloatingPanelController):
- `gettingReady` → `.processing`, return to idle after 1.5s
- `transcriptSaved` → `.processing`, return to idle after 2.5s
- `failed` → `.processing`, return to idle after 4.0s

## View Composition

FloatingPanelView switches on `pillStateManager.state`:
- `.idle` → `AuroraIdleView` (collapsed/expanded capsule with record/files buttons)
- `.recording` → `AuroraRecordingView` (aurora fog + timer + stop) or legacy `PillRecordingView`
- `.processing` → `AuroraSuccessView` (if transcriptSaved) else `AuroraProcessingView`

**Overlays** (in VStack above pill):
- `SpeakerNamingView` — mutually exclusive with transcript tray, sticky (no Escape dismiss)
- `TranscriptTrayView` — only when .idle or .recording, dismissible by Escape
- `ToastNotificationView` — error display, auto-dismisses after 5s

**Escape key handling**: Dual local + global NSEvent monitors (panel is non-activating, so global catches when other apps have focus). Speaker naming is exempt from Escape dismissal.

## Modification Recipes

| Task | Files to touch |
|---|---|
| Fix pill state transitions | `PillStateManager.swift` — check guards, cooldown |
| Fix window position/dragging | `FloatingPanelController.swift` — NSPanel config |
| Fix recording animation | `AuroraRecordingView.swift` — audio level data from `Audio.audioLevelHistory` |
| Fix processing/success display | `AuroraProcessingView.swift` / `AuroraSuccessView.swift` |
| Fix error display | `ErrorViews.swift` — ContextualError parser or ToastNotificationView layout |
| Fix silence prompt | `AttentionPromptView.swift` — threshold is 120s from `Audio.silenceDuration` |
| Fix transcript tray | `TranscriptTrayView.swift` + `TranscriptDetailView.swift`, data from TranscriptStore |
| Fix speaker naming | `SpeakerNamingView.swift`, data from `SpeakerNamingRequest` |
| Add new pill visual state | `PillStateManager.swift` (add to enum) + new view in Components + update FloatingPanelView switch |

## Gotchas
- Window: `.borderless` + `.nonactivatingPanel` — clicks don't steal focus from other apps
- Position saved on every drag via `windowDidMove` delegate
- `hidesOnDeactivate = false` required to stay visible
- Audio level data from `Audio.audioLevelHistory` (circular buffer, 15 samples, 0-1 Float)
- Aurora recording auto-collapses to 72×36 after 5s, re-expands on hover
- Speaker naming tray has `canDismiss = false` for first 3s to prevent accidental dismiss

## Dependencies
**From Core/**: Audio (levels, isRecording), TranscriptionTaskManager (displayStatus, speakerNamingRequest), TranscriptStore, FailedTranscriptionManager
**From Design/**: DesignTokens (PillDimensions, PillAnimationTiming, all colors, animation presets)

## Logging
Subsystem: `ui` — pill transitions, blocked transitions, tray events
