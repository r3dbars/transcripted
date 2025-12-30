# Transcripted Visual Identity Specification

> **Document Created**: December 29, 2024
> **Status**: Approved for Implementation
> **Timeline**: Q1 2025 (2-3 months)

---

## Executive Summary

**Transformation**: From edge-docked panel → **Floating pill near dock with Dynamic Island-style morphing**

**Core Personality**: Warm, approachable, delightful tool that builds **confidence** through always being present and providing progressive feedback.

**Key Change**: The UI moves from the right edge of the screen to a floating pill centered above the macOS dock, with smooth morphing animations inspired by iPhone's Dynamic Island.

---

## 1. Core Design Philosophy

| Attribute | Decision |
|-----------|----------|
| **Personality** | Warm & Approachable |
| **Color Temperature** | Warm & Inviting (Creams/Terracottas) |
| **Visual Weight** | Always Present (never invisible) |
| **Experience Type** | Delightful Tool (functional + moments of joy) |
| **Core Emotion** | **Confidence** - "I'll never forget what was discussed" |
| **Primary Pain Point** | Forgetting action items after meetings |

### Design Principles

1. **Always Present**: The pill should be visible at all times, even during fullscreen apps
2. **Progressive Feedback**: Show status at every step (transcribing → extracting → saving)
3. **Warm Minimalism**: Frosted glass with cream/terracotta accents
4. **Delightful but Professional**: Satisfying interactions without gamification
5. **Confidence-Building**: Users should feel certain nothing was missed

---

## 2. The Floating Pill Concept

### Position & Behavior

| Property | Value |
|----------|-------|
| **Location** | Centered above macOS dock |
| **Idle Size** | Tiny: 40×20px |
| **Recording Size** | Medium: 180×40px (horizontal expansion) |
| **Movable** | Fixed position (muscle memory) |
| **Fullscreen Behavior** | Stay visible (critical for meetings) |

### 2.1 Idle State

```
┌─────────────────────┐
│  ▁ ▁ ▁ ▁ ▁ ▁ ▁ ▁   │  ← Dormant waveform (flat bars)
└─────────────────────┘
        40×20px
```

- **Visual**: Dormant audio visualizer with flat bars that "sleep"
- **Background**: Frosted glass (NSVisualEffectView with blur)
- **Behavior**: Awakens when recording starts
- **Discovery**: Always visible, gentle presence

### 2.2 Recording State

```
┌─────────────────────────────────────────────┐
│  🔴  ▃█▅▂▇▃█▄▆▂▅▇   00:42   ⏹              │
└─────────────────────────────────────────────┘
                   180×40px
```

- **Transform**: Morph/grow horizontally (Dynamic Island style animation)
- **Visualizer**: Classic bars with interlaced dual-audio colors
  - Warm coral (#FF6B6B) = Microphone audio
  - Cool blue (#4A90D9) = System audio
- **Recording Indicator**: Classic Red dot (#FF0000)
- **Timer**: Monospaced font (SF Mono), updates every second
- **Stop Button**: Visible, easy to tap

### 2.3 Processing State (Post-Recording)

```
┌─────────────────────────────────────────────┐
│  ⏳ Transcribing...                         │
└─────────────────────────────────────────────┘
            ↓ (after completion)
┌─────────────────────────────────────────────┐
│  ✨ Extracting action items...              │
└─────────────────────────────────────────────┘
            ↓ (after completion)
┌─────────────────────────────────────────────┐
│  📝 Preparing tasks...                      │
└─────────────────────────────────────────────┘
```

- **Progressive Feedback**: Show status at EVERY step
- **Steps**: Transcribing → Extracting action items → Preparing tasks
- **Animation**: Smooth transitions between states

### 2.4 Task Review Tray (Expands Upward)

```
      ╭───────────────────────────────────╮
      │  ☑ Send proposal to client        │
      │  ☑ Book flight for conference     │
      │  ☐ Review competitor analysis     │
      │  ☑ Follow up with Jack            │
      ├───────────────────────────────────┤
      │  [Skip]          [Add 3 Tasks ✓]  │
      ╰───────────────────────────────────╯
                      280px wide
                         ↑
                   Smooth grow upward
                         ↑
╭─────────────────────────────────────────────╮
│  ✓ 4 tasks extracted                        │
╰─────────────────────────────────────────────╯
```

- **Animation**: Smooth organic growth upward (like speech bubble emerging)
- **Width**: 280px (comfortable for reading task text)
- **Selection**: Checkboxes for each task (selected by default)
- **Actions**: Skip (dismiss) or Add Selected (submit to Reminders/Todoist)
- **Background**: Frosted glass + warm cream tint

---

## 3. Color Palette

### Primary Colors

| Name | Hex | RGB | Usage |
|------|-----|-----|-------|
| **Pure Cream** | `#FAF7F2` | 250, 247, 242 | Base background, tray bg |
| **Terracotta** | `#DA7756` | 218, 119, 86 | Primary accent, buttons, hover states |
| **Terracotta Hover** | `#C4654A` | 196, 101, 74 | Button hover state |
| **Terracotta Pressed** | `#B85A42` | 184, 90, 66 | Button pressed state |
| **Classic Red** | `#FF0000` | 255, 0, 0 | Recording indicator |
| **Mic Coral** | `#FF6B6B` | 255, 107, 107 | Microphone visualizer bars |
| **System Blue** | `#4A90D9` | 74, 144, 217 | System audio visualizer bars |

### Background Treatment

| Element | Treatment |
|---------|-----------|
| **Pill Background** | Frosted glass (NSVisualEffectView, .hudWindow material) |
| **Task Review Tray** | Frosted glass + warm cream tint overlay |
| **Onboarding Windows** | Same frosted glass (visual consistency) |
| **Settings Window** | Standard macOS window (native, not frosted) |

### Status Colors

| State | Hex | RGB | Usage |
|-------|-----|-----|-------|
| **Success** | `#4A9E6B` | 74, 158, 107 | Completion, checkmarks |
| **Warning** | `#D4A03D` | 212, 160, 61 | Duration warnings, silence detection |
| **Error** | `#E05A5A` | 224, 90, 90 | Errors, permission issues |
| **Processing** | `#7B68A8` | 123, 104, 168 | AI processing, transcribing |

### Dark Mode Considerations

- Pill uses frosted glass which automatically adapts
- Status colors remain consistent across modes
- Task tray maintains warm cream tint in both modes

---

## 4. Typography

| Element | Font | Weight | Size | Tracking |
|---------|------|--------|------|----------|
| **Pill Status Text** | SF Rounded | Regular | 12-13px | 0 |
| **Timer** | SF Mono | Medium | 13px | 0 |
| **Task Text** | SF Rounded | Regular | 14px | 0 |
| **Task Headings** | SF Rounded | Semibold | 16px | 0 |
| **Button Text** | SF Rounded | Semibold | 14px | 0.3px |
| **Onboarding Display** | SF Rounded | Bold | 28px | -0.5px |

### Font Choice Rationale

- **SF Rounded**: Softer, friendlier than SF Pro while remaining native macOS
- **SF Mono**: Clear timer display, retro-modern feel
- Aligns with "warm & approachable" personality

---

## 5. Iconography

### Icon System

| Property | Value |
|----------|-------|
| **Icon Set** | SF Symbols (native macOS) |
| **Style** | Filled variants preferred for visibility at small sizes |
| **Sizes** | 12px (pill), 16px (tray), 20px (buttons) |

### Key Icons

| Function | SF Symbol Name |
|----------|----------------|
| Record | `record.circle.fill` |
| Stop | `stop.circle.fill` |
| Microphone | `mic.fill` |
| Checkmark | `checkmark.circle.fill` |
| Processing | `sparkles` or `hourglass` |
| Settings | `gear` |
| Warning | `exclamationmark.triangle.fill` |
| Error | `xmark.circle.fill` |

### App Icon Concept

- **Design**: Microphone with integrated checkmark
- **Meaning**: Recording → Tasks completed
- **Style**: Rounded, warm colors (terracotta + cream)

### Menu Bar Icon

- **Behavior**: Status-reactive (changes based on state)
- **States**:
  - Idle: Simple waveform icon
  - Recording: Red dot overlay
  - Processing: Animated sparkle
  - Error: Warning badge

### Icon Animations

| Animation | Enabled | Description |
|-----------|---------|-------------|
| State Transitions | ✅ | Icons morph between states (play → pause) |
| Hover Effects | ✅ | Subtle scale/glow on mouse-over |
| Celebration Bursts | ✅ | Sparkle effect on success |
| Bounce on Tap | ❌ | Not used (too playful) |

---

## 6. Interactions & Micro-interactions

### Record Button

| Property | Value |
|----------|-------|
| **Press Feel** | Satisfying click effect |
| **Animation** | Visual compression + release (mechanical feel) |
| **Feedback** | Immediate state change |

### Audio Feedback

| Event | Sound |
|-------|-------|
| Recording Start | Soft start chime (gentle, non-intrusive) |
| Recording Stop | Different stop chime (clear endpoint) |
| Error | No sound (visual only) |

### Celebrations

| Event | Celebration Type |
|-------|------------------|
| Tasks Added | Count badge + warm glow ("3 tasks added") |
| Recording Saved | Subtle checkmark appearance |
| Errors | Shake animation + error toast |

### Transform Animations

| Transition | Animation | Duration |
|------------|-----------|----------|
| Idle → Recording | Horizontal morph/grow | 0.3s spring |
| Recording → Processing | Smooth content transition | 0.25s ease |
| Processing → Task Tray | Grow upward (speech bubble) | 0.4s spring |
| Task Tray → Idle | Shrink + settle | 0.3s ease |

---

## 7. Error Handling

### Permission Errors

| Error | Visual Response |
|-------|-----------------|
| No Microphone Permission | Pill shakes + error toast appears |
| No Screen Recording | Toast with "Open Settings" action |
| API Key Invalid | Toast with guidance |

### Recording Warnings

| Condition | Response |
|-----------|----------|
| 2+ hours recording | Duration warning (non-intrusive badge) |
| Silence detected (2+ min) | Amber indicator (current behavior) |
| Low disk space | Warning before recording starts |

---

## 8. Settings & Configuration

### Access Methods

| Method | Behavior |
|--------|----------|
| **Primary** | Menu bar icon click → dropdown menu → "Settings..." |
| **Secondary** | Right-click pill → context menu (optional) |

### Settings Window

| Property | Value |
|----------|-------|
| **Style** | Standard macOS window (native, not frosted) |
| **Size** | ~520×580px (current size) |
| **Layout** | Tabbed interface (Recording, AI Features, Advanced) |

### Quick Settings in Pill

- **None** - Keep the pill minimal and focused
- All configuration happens in Settings window

### Failed Transcriptions

| Location | Indicator |
|----------|-----------|
| Pill | Red badge/dot when failures exist |
| Menu Bar | Warning badge on icon |
| Settings | Dedicated section with retry options |

---

## 9. Onboarding Flow

### Overview

| Property | Value |
|----------|-------|
| **Steps** | 4 (current approach: Welcome, How It Works, Permissions, Ready) |
| **Style** | Frosted glass windows (matches pill aesthetic) |
| **Permissions** | All requested upfront (microphone + screen recording) |

### Ready State (Post-Onboarding)

1. Onboarding window fades out
2. Pill fades in at dock-center position
3. Gentle pulse animation draws attention
4. User is ready to record

---

## 10. Design Inspiration

### Emulate

| App/Feature | What to Take |
|-------------|--------------|
| **Things 3** | Elegant details, delightful micro-interactions |
| **Claude App** | Warm terracotta colors, sophisticated feel |
| **Wispr Flow** | Floating pill concept, compact presence |
| **Spotify Mini Player** | Compact pill controls, album art integration |
| **iPhone Dynamic Island** | Morphing contextual UI, smooth animations |
| **AirPods Connection Popup** | Beautiful, transient, purposeful animations |

### Avoid

| Style | Reason |
|-------|--------|
| **Corporate Enterprise** | Blue/gray sterile (Jira/Salesforce vibes) |
| **Skeuomorphic** | Dated faux textures |
| **Neon/Cyberpunk** | Too loud, gaming aesthetic |
| **Flat/Brutalist** | Too harsh, no warmth |

---

## 11. Implementation Specifications

### Window/Panel Configuration

```swift
// Pill Window
let pillWindow = NSPanel(
    contentRect: NSRect(x: 0, y: 0, width: 40, height: 20),
    styleMask: [.borderless, .nonactivatingPanel],
    backing: .buffered,
    defer: false
)
pillWindow.level = .floating
pillWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
pillWindow.isOpaque = false
pillWindow.backgroundColor = .clear
pillWindow.hasShadow = true
```

### Position Calculation

```swift
// Center above dock
func positionPillAboveDock() {
    guard let screen = NSScreen.main else { return }
    let dockHeight: CGFloat = 70 // Approximate dock height
    let padding: CGFloat = 8

    let x = (screen.frame.width - pillWidth) / 2
    let y = dockHeight + padding

    pillWindow.setFrameOrigin(NSPoint(x: x, y: y))
}
```

### Frosted Glass Effect

```swift
// SwiftUI
.background(.ultraThinMaterial)
.background(Color.cream.opacity(0.3)) // Warm tint

// AppKit
let visualEffect = NSVisualEffectView()
visualEffect.material = .hudWindow
visualEffect.blendingMode = .behindWindow
visualEffect.state = .active
```

### Morph Animation

```swift
// Dynamic Island-style expansion
withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
    pillWidth = isRecording ? 180 : 40
    pillHeight = isRecording ? 40 : 20
}
```

---

## 12. Complete Visual Flow

### 1. Idle State (Centered above dock)

```
                    ╭─ Frosted glass pill ─╮
                    │  ▁ ▁ ▁ ▁ ▁ ▁ ▁ ▁    │ ← Dormant waveform
                    ╰──────────────────────╯
                              ↓
    ┌──────────────────────────────────────────────────────┐
    │  [Apps...]  [Finder]  [Safari]  [...]  [Trash]       │ ← macOS Dock
    └──────────────────────────────────────────────────────┘
```

### 2. Recording (Morphed)

```
            ╭──────────────────────────────────────────╮
            │  🔴  ▃█▅▂▇▃█▄▆▂▅▇   00:42   ⏹           │
            ╰──────────────────────────────────────────╯
                              ↓
    ┌──────────────────────────────────────────────────────┐
    │  [Apps...]  [Finder]  [Safari]  [...]  [Trash]       │
    └──────────────────────────────────────────────────────┘
```

### 3. Processing (Status Steps)

```
            ╭──────────────────────────────────────────╮
            │  ⏳ Transcribing... (45%)                │
            ╰──────────────────────────────────────────╯

            ╭──────────────────────────────────────────╮
            │  ✨ Extracting action items...           │
            ╰──────────────────────────────────────────╯

            ╭──────────────────────────────────────────╮
            │  📝 Preparing 4 tasks...                 │
            ╰──────────────────────────────────────────╯
```

### 4. Task Review (Tray Expanded)

```
      ╭─────────────────────────────────────────────╮
      │  Action Items                    3 selected │
      ├─────────────────────────────────────────────┤
      │  ☑ Send proposal to client                  │
      │  ☑ Book flight for conference               │
      │  ☐ Review competitor analysis               │
      │  ☑ Follow up with Jack re: pricing          │
      ├─────────────────────────────────────────────┤
      │  [Skip]                    [Add 3 Tasks ✓]  │
      ╰─────────────────────────────────────────────╯
                          ↑
            ╭─────────────┴─────────────╮
            │  ✓ 4 tasks extracted      │
            ╰───────────────────────────╯
                          ↓
    ┌──────────────────────────────────────────────────────┐
    │  [Apps...]  [Finder]  [Safari]  [...]  [Trash]       │
    └──────────────────────────────────────────────────────┘
```

### 5. Success (Badge + Glow)

```
            ╭──────────────────────────────────────────╮
            │  ✓ 3 tasks added to Reminders  ✨        │ ← Warm glow effect
            ╰──────────────────────────────────────────╯
                     ↓ (shrinks back to idle after 2s)
```

---

## 13. Project Plan

### Phase 1: Foundation (Weeks 1-2)
- [ ] Create new `FloatingPill` SwiftUI component
- [ ] Implement pill positioning above dock
- [ ] Build frosted glass background
- [ ] Create dormant waveform visualizer

### Phase 2: Core Interactions (Weeks 3-4)
- [ ] Implement morph animation (idle ↔ recording)
- [ ] Build dual-audio interlaced visualizer
- [ ] Add recording timer and stop button
- [ ] Implement start/stop chimes

### Phase 3: Processing & Feedback (Weeks 5-6)
- [ ] Create progressive status indicators
- [ ] Build "smooth grow upward" animation for tray
- [ ] Implement task review UI in tray
- [ ] Add celebration animations (badge + glow)

### Phase 4: Polish & Integration (Weeks 7-8)
- [ ] Update onboarding to frosted glass style
- [ ] Implement menu bar status-reactive icon
- [ ] Add error handling (shake, toast)
- [ ] Integrate with existing TranscriptionTaskManager

### Phase 5: Testing & Refinement (Weeks 9-10)
- [ ] Beta testing with users
- [ ] Animation timing refinements
- [ ] Accessibility review (VoiceOver, reduce motion)
- [ ] Performance optimization

### Phase 6: Launch Preparation (Weeks 11-12)
- [ ] Final polish pass
- [ ] Documentation updates
- [ ] Marketing assets (screenshots, video)
- [ ] Release

---

## 14. Name & Branding (Pending)

| Element | Current Status |
|---------|----------------|
| **App Name** | "Transcripted" (to be revisited) |
| **Tagline** | "Turn every meeting into action" |
| **App Icon** | Microphone + Checkmark concept |
| **Preferred Name Style** | One word, real word, verb or noun |

### Name Exploration Notes
- User likes -er/-r endings (Uber, Tinder style)
- Themes: Action/Tasks + Voice/Sound
- Avoid: Made-up words, existing app names
- Inspiration: Momentum, Monologue, Monocle (as references, not options)

---

## 15. Decisions Summary

| # | Category | Decision |
|---|----------|----------|
| 1 | Personality | Warm & Approachable |
| 2 | Color Temp | Warm & Inviting (Creams/Terracottas) |
| 3 | Visual Weight | Always Present |
| 4 | Experience | Delightful Tool |
| 5 | Position | Bottom Edge/Dock Area |
| 6 | Idle Shape | Small Floating Pill (40×20px) |
| 7 | Expansion | Morph/Transform (Dynamic Island) |
| 8 | Max Size | Always Compact |
| 9 | Idle Visual | Dormant waveform visualizer |
| 10 | Dock Position | Centered Above Dock |
| 11 | Movable | Fixed Position |
| 12 | Record Transform | Expand Horizontally |
| 13 | Record Color | Classic Red |
| 14 | Visualizer | Classic Bars |
| 15 | Dual Audio | Split Colors (Interlaced) |
| 16 | End State | Progressive processing indicators |
| 17 | Recording Width | Medium (180px) |
| 18 | Tray Animation | Smooth Grow Upward |
| 19 | Tray Width | 280px |
| 20 | Base Color | Pure Cream (#FAF7F2) |
| 21 | Accent Color | Terracotta (#DA7756) |
| 22 | Pill Background | Frosted Glass |
| 23 | Tray Background | Frosted Glass + Warm |
| 24 | Typography | SF Rounded |
| 25 | Icons | SF Symbols |
| 26 | Icon Animations | State transitions, hover, celebrations |
| 27 | Text Size | Small (12-13px) |
| 28 | Record Feel | Satisfying Click Effect |
| 29 | Audio Feedback | Start & Stop chimes |
| 30 | Celebration | Count Badge + Glow |
| 31 | Easter Eggs | None (Professional) |
| 32 | Design Inspiration | Things 3, Claude, Wispr Flow |
| 33 | Audio Inspiration | Spotify Mini Player |
| 34 | macOS Inspiration | Dynamic Island, AirPods Popup |
| 35 | Anti-Inspiration | Corporate Enterprise |
| 36 | Onboarding | Warm Welcome (4 steps) |
| 37 | Permissions | All Upfront |
| 38 | Onboarding Style | Frosted Glass |
| 39 | Ready State | Pill + Gentle Pulse |
| 40 | Settings Access | Menu Bar Click |
| 41 | Settings Style | Standard macOS Window |
| 42 | Quick Settings | None in Pill |
| 43 | Failed Queue | Badge on Pill + Menu Bar |
| 44 | No Mic Error | Shake + Error Toast |
| 45 | Fullscreen | Stay Visible |
| 46 | Long Recording | Duration Warning |
| 47 | Shortcuts | None for now |
| 48 | App Icon | Mic with Checkmark |
| 49 | Menu Bar Icon | Status-Reactive |
| 50 | Core Emotion | Confidence |
| 51 | Pain Point | Forgetting Action Items |
| 52 | Polish Level | Beta Quality (80%) |
| 53 | Rollout | All at Once |
| 54 | Timeline | Quarter (2-3 months) |

---

## Document History

| Date | Version | Changes |
|------|---------|---------|
| 2024-12-29 | 1.0 | Initial specification created from comprehensive questionnaire |

---

*This specification captures all design decisions for the Transcripted visual identity redesign. Implementation should follow this document as the source of truth.*
