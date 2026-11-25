# UI tokens

One source for the look ("quiet paper, live green"): `Sources/UI/Shared/DesignTokens.swift`. `LibraryTokens` (main window), `MenuTokens` (popover) and `NotchIslandPalette` (island) all read from it, so use whichever name your file already uses. Don't add colors, sizes, radii, fonts or button looks in a screen; add the missing token there, small, and say so.

## Colors (`DesignTokens`, AppKit twins in `DesignTokens.NS`)

| Token | Use |
|---|---|
| `paper`, `paperSidebar` | Content and sidebar backgrounds |
| `ink`, `ink2`, `ink3` | Text: primary, secondary (meta), tertiary (hints, labels). `ink` is also the primary-button fill |
| `hairline`, `hairlineStrong` | Dividers; the secondary-button border |
| `fill`, `fillStrong` | The one neutral fill (hover, raised cards, chips); selected or pressed |
| `live` (`NS.liveOnDark` on the island) | Capture green. Live or just-worked only: listening, recording, pasted, live progress, played audio. The recording dot is this green everywhere (`LibraryTokens.recording`, `MenuTokens.statusRecordingNS`, `NotchIslandPalette.recording`) |
| `attention` (`NS.attentionOnDark` on the island) | Failed or needs action |
| `danger` | Only the confirm step of a destructive action (Discard this recording?, Move to Trash). Never recording, never a button at rest |
| `dictationStream`, `meetingsStream`, `writingStream` | Small marks per stream, never fills |
| `controlTint` | The window-root tint (below) |

Green is never a button, "starred", "copied", "saved", "ready", "You" or today's date. Those are `ink`/`ink2`. Speaker names use the voice-print palette (`HomeMeetingSpeakerColor`, `VoicePrintStyle`), so a person is one color everywhere.

## Shape

`DesignTokens.Radius.control` (6: buttons, rows, chips, inputs), `.surface` (12: cards, toasts, lists), `.pill(height:)`. `LibraryTokens.radiusControl` / `radiusRaised` are the same values. Minimum hit target: `DesignTokens.minimumHitTarget` (40).

## Text roles (`TextRole`)

| Role | Face | Use |
|---|---|---|
| `.display` | SF 28 semibold | Page titles (`LibraryTokens.title`, `SettingsPageIntro`) |
| `.heading` | SF 15 semibold | Card and sheet headings |
| `.body` | SF 13 (`.medium` for row titles) | Reading text, rows |
| `.meta` | SF 12 | Durations, counts, subtitles |
| `.small` | SF 11 | Footnotes, chips |
| `.label` | JetBrains Mono 10.5 medium, uppercase, tracked | Section labels (`LibrarySectionLabel`, `SettingsCardLabel`) |

SwiftUI: `Text("Today").textRole(.label)` applies font, tracking and case; `TextRole.heading.font()` gives just the font. AppKit: `TextRole.meta.nsFont(weight: .semibold)`. Timers use monospaced digits at a role's size, formatted `5:07` (`MeetingDurationFormatter.formatDuration`, `NotchIslandPresentation.timerText`).

The fonts ship in `Resources/Fonts` (SIL OFL, see `THIRD_PARTY_LICENSES.md`) and `BundledFonts` registers them for the process the first time a label role is drawn. Without the bundle (tests, smokes) the label falls back to system monospaced, same size. Page titles are the system font (the owner tried a serif and turned it down, 2026-11-19).

## Buttons (`Sources/UI/Shared/DesignButtonStyles.swift`)

```swift
Button("Record a meeting") { … }.buttonStyle(.transcriptedPrimary)   // ink fill, paper text
Button("Show in Finder") { … }.buttonStyle(.transcriptedSecondary)   // hairline border
Button("Not now") { … }.buttonStyle(.transcriptedQuiet)              // text only
```

Height follows `.controlSize`: mini 20, small 24, regular 28, large 40 (onboarding and setup nav). One primary per view. Destructive actions stay secondary or quiet ink behind their existing confirm; only the confirm itself is red. No `.borderedProminent`, no `.tint(.orange)`, no green or blue fills.

On the black island the same three are `NotchIslandButton.Style.accent` (white pill, the primary), `.plain` / `.subtle`, and `.link`; `.destructive` is red only for the confirm step that loses something (the island's "Discard this recording?"). Every drop-down's buttons come from `NotchIslandDropButtons` with a role (`NotchIslandPromptButtonRole`), never from the title. In the popover, filled rows (`MenuTokens.buttonBackgroundNS`) are the ink primary.

## Root tint

Each SwiftUI window root calls `.transcriptedRootTint()` (main window, onboarding, feedback popover), so switches, checkboxes, progress and focus are ink instead of the Mac's accent color. On dark it's a light grey so a switch's white knob still reads. Don't put `.tint(.accentColor)` on controls; let the root tint apply.
