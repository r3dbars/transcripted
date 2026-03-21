# FloatingPanel

Morphing pill UI (Dynamic Island style) with aurora visualizations, transcript tray, and speaker naming dialog. 16 Swift files.

## File Index

| File | Purpose |
|------|---------|
| **PillStateManager.swift** | State machine: idle -> recording -> processing. Timeout recovery, sound feedback. |
| **FloatingPanelView.swift** | Root SwiftUI view. Tray mux (none/transcripts/speakerNaming), toast layer, pill content switch. |
| **FloatingPanelController.swift** | NSWindowController. Position persistence, Combine subscriptions to Audio/TaskManager, window setup. |
| **AuroraIdleView.swift** | Collapsed pill (40x20px). Hover-expands to 200x44px with Record + Transcripts buttons. |
| **AuroraRecordingView.swift** | Recording state (180x40px). Live aurora fog: coral (mic, left) + teal (system, right). Timer + stop. |
| **AuroraProcessingView.swift** | Processing state (180x40px). Progress-based aurora intensity. Warning text at 90s+. |
| **AuroraSuccessView.swift** | Success feedback (200x44px). Animated checkmark + "Saved" + Copy/Open buttons. |
| **TranscriptTrayView.swift** | Recent transcript list (280x300px max). Frosted glass. Detail view for single transcript. |
| **TranscriptDetailView.swift** | Single transcript viewer. Groups lines by speaker with colored left borders. |
| **SpeakerNamingView.swift** | Post-recording speaker naming. Play clips, confirm/reject names, merge with existing profiles. |
| **WaveformViews.swift** | EdgePeekView, WaveformMiniView, DormantWaveformView, MinimalWaveformIcon. |
| **PillViews.swift** | Legacy pill views (PillIdleView, PillRecordingView, PillProcessingView) - mostly unused, replaced by Aurora. |
| **CelebrationViews.swift** | CelebrationOverlay with ring/checkmark animations. |
| **ErrorViews.swift** | ToastNotificationView (8s auto-dismiss), PillErrorView (shake), ContextualError enum. |
| **AttentionPromptView.swift** | Silence warning + still-recording detection prompt. |
| **LawsComponents.swift** | AnimatedDotsView, LawsButton, FloatingTooltipModifier, Triangle connector shape. |

## Pill State Machine
```
States:
  idle       -> 40x20px capsule (hover-expands to 200x44px)
  recording  -> 180x40px with live aurora + timer + stop button
  processing -> 180x40px with progress aurora + status text

Timing:
  morphDuration: 0.175s    cooldownDuration: 0.175s
  contentFade: 0.1s        transitionTimeout: 2.0s (force-reset if stuck)

Sounds:
  -> recording:  "Pop"     recording -> processing: "Tink"
  processing -> idle: "Glass"    -> failed: "Basso"

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

## View Hierarchy
```
FloatingPanelView (320pt wide)
  |-- Spacer (pushes content to bottom)
  |-- SpeakerNamingView OR TranscriptTrayView (conditional)
  |-- Toast layer (ToastNotificationView, floats 60pt above pill when no tray)
  +-- Pill content (morphs between aurora states)
      |-- idle -> AuroraIdleView (failed badge, processing pulse dot)
      |-- recording -> AuroraRecordingView (audio-reactive fog)
      +-- processing -> AuroraSuccessView OR AuroraProcessingView
```

## FloatingPanelController - Window Setup
- NSPanel: borderless, nonactivatingPanel, floating level, canJoinAllSpaces
- `isMovableByWindowBackground = true` (drag anywhere)
- Transparent background, no shadow, always visible (`hidesOnDeactivate = false`)
- `canBecomeKey = false` by default (doesn't steal focus). Set true during speaker naming.
- Position saved to UserDefaults: `floatingPanelX`, `floatingPanelY`
- Dock height detected via `visibleFrame.origin.y - screenFrame.origin.y`

## Combine Subscriptions (State Sync)
```
audio.$isRecording (.debounce 50ms):
  true  -> transition(to: .recording)
  false -> .processing (if status.isProcessing) or .idle

taskManager.$displayStatus:
  .gettingReady      -> show processing 1.5s, return to idle
  .transcriptSaved   -> show success 2.5s (guard: !isRecording, !speakerNaming)
  .failed            -> play error sound, show processing 4.0s

taskManager.$speakerNamingRequest:
  != nil -> panel.allowKeyFocus = true, makeKey()
  == nil -> panel.resignKey()
```

## Aurora Recording Visualization
- **Mic fog** (coral, biased LEFT): 2 orbs, audio-reactive (audioBoost: 0.6-2.1x)
- **System fog** (teal, biased RIGHT): 2 orbs, breathing only (not audio-reactive)
- Smoothing factor: 0.08 at 30fps (prevents jitter)
- Pseudo-noise: 4-wave sum for organic non-repeating motion
- `drawingGroup()` for GPU rendering, 8px blur
- Respects `accessibilityReduceMotion`

## Speaker Naming Flow
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

## Error Toast System
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

## Escape Key Handling
- Local monitor (app frontmost) + Global monitor (other app frontmost)
- Speaker naming: 3-second guard before allowing dismiss
- Transcript tray: dismiss immediately
- Monitors installed/removed on trayState change

## Design Tokens Used
Colors: panelCharcoal, panelCharcoalElevated, panelCharcoalSurface, panelTextPrimary/Secondary/Muted, recordingCoral, auroraCoral/CoralLight, auroraTeal/TealLight, accentBlue, statusSuccessMuted, statusErrorMuted, statusWarningMuted, systemAudioIndicator
Dimensions: PillDimensions (idleWidth:40, recordingWidth:180, trayWidth:280, trayMaxHeight:300)
Animations: .pillMorph, .trayExpand, .pillContentFade

## Gotchas
- Naming tray is STICKY (persists across pill states), transcript tray is NOT (auto-closes on processing)
- Toast notification space collapses to 0pt when tray is open
- AuroraSuccessView auto-dismiss (2.5s) is controlled by FloatingPanelController, not the view itself
- Speaker colors are hash-based (name % 5 palette), user always gets .accentBlue
- `hasSettled` in AuroraIdleView: starts false after success view to allow smooth size transition
- Silence prompt triggers at 120s of silence (not recording duration)
- Copy button in success view shows checkmark 1.5s then reverts
