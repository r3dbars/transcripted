# Settings And Menu Bar UI Spec

## Goal

Make Transcripted feel simple, clear, and trustworthy.

Two surfaces stay in play:

- the menubar popover for fast actions
- the settings window for everything that needs explanation or setup

The menubar popover should help users do something immediately.
The settings window should explain what each area is for and keep related controls together.

## Product Shape

### Menubar popover

The menubar popover is a single lightweight page with:

1. a compact status header
2. primary actions
3. secondary utility actions

It should no longer include:

- inline shortcut editing
- recent meetings / recent captures browsing
- embedded multi-page navigation

### Settings window

The settings window becomes the app's control center.

It uses a native macOS sidebar with these pages:

- `Home`
- `Recording`
  - `Dictation`
  - `People`
  - `Shortcuts`
- `Setup`
  - `General`
  - `Models`
  - `Storage`
  - `Agent`
- `Trust`
  - `Privacy`
  - `About`

There is no first-class `Advanced` page in this version.

## Visual Direction

- native macOS first
- adaptive light/dark appearance
- simple source-list sidebar
- clear page titles and one-sentence intros
- rounded content cards for grouped controls
- subtle background polish, not a themed or decorative UI
- emphasis on readable labels and secondary explanatory text

## Menubar Popover

### Header

The header has no title. It only shows up when it has something to say:

- a status line while a meeting records, a transcript is being made, or the
  voice model is warming up (with progress)
- a one-line shortcut warning, clickable when it has a fix to open

A ready, idle popover shows no header at all.

### Buttons

Two small buttons sit side by side at the top:

- `Record` (Record Meeting; becomes `Stop` with the elapsed time while recording)
- `Dictate` (Start Dictation; becomes `Stop` while dictating)

Rules:

- each button shows its shortcut only when it fits; the full title stays the
  accessibility label
- setup or failure detail moves to the button's tooltip
- `Paste Last Dictation` has no row; its shortcut (default ⌥⇧V) still works

### Utility rows

Under the buttons:

- `Open Transcripted` (Settings lives inside it)
- dynamic updates row: `Check for Updates`, `Checking for Updates…`, or an
  update state; a prominent update callout replaces it when an update needs a click
- `Quit`

## Settings Window

### Home

Purpose:
Show the simplest ways to use Transcripted and surface high-value status.

Contents:

- top-of-page unfinished meeting warnings, when a meeting needs retry/delete
- overall dictation and meeting stats
- recent activity for:
  - meetings, including retained-audio playback when available
  - dictations
- compact setup issues only when something needs attention

### Shortcuts

Purpose:
Own all keyboard-trigger setup and send-after-paste rules.

Contents:

- dictation shortcut recorder
- meeting shortcut recorder
- right Option dictation toggle
- send-after-paste app allowlist

This page should not own privacy, storage, or analytics controls.

### General

Purpose:
Own basic app behavior, audio import, dictation cleanup, and custom words.

Contents:

- launch at login
- Dock icon visibility
- feedback sounds
- imported-audio transcription
- dictated-text cleanup
- custom words and spoken-text corrections
- compact dictation hotkey summary with editing handoff to `Shortcuts`

### Models

Purpose:
Show the active local transcription engine and keep model switching tucked away.

Contents:

- active model status
- model file status
- optional model picker

### People

Purpose:
Own meeting speaker cleanup.

Contents:

- deferred speaker names
- speaker sample playback
- duplicate cleanup
- local speaker split toggle

Meeting start, recent meeting transcripts, and unfinished meeting repair live on `Home`.

### Dictation

Purpose:
Own dictation-specific behavior after speech has been captured.

Contents:

- `Paste Last Dictation`
- explanation of paste-back behavior
- `Feedback sounds`
- dictation folder shortcut or supporting storage context

### Storage

Purpose:
Explain where user content lives and let users change the capture library safely.

Contents:

- capture library chooser
- reset to default
- rows for:
  - capture library
  - meeting captures
  - dictation captures
  - app state
  - app cache
  - app logs
  - temporary recordings

### Agent

Purpose:
Keep agent setup discoverable without forcing it into the menubar flow.

Contents:

- copy main agent prompt
- copy MCP setup
- copy folder paths
- reveal meetings folder
- reveal dictations folder

This page should reuse the simple "prompt first, manual setup second" mental model.

### Card layout (2026-08 restyle)

The combined settings page has no disclosures: every setting is an
always-visible row inside a rounded card, grouped under plain gray section
labels (Dictation, Microphone, Send after dictation, Meetings,
Speakers, Transcription, App, Permissions, Privacy, Storage, About, Support).
Rows carry at most a few words; each row's explanation lives in its ⓘ info
popover. The page ends with the privacy line "Transcripts and audio never
leave this Mac." Corrections open in a sheet; permissions render as status
rows with a request action; mic processing sits in the Meetings card.
While the Mac mic recorder (`PinnedMicrophoneCapturePreferences`) is on, the
Microphone card holds one picker for dictation and meetings (Automatic, a
specific mic, or "Same as macOS Sound settings") and the Meetings card drops
"Use Mac-selected microphone". With it off, the card keeps Faster Bluetooth
dictation and its mic picker.

### About

Purpose:
Cover app identity, updates, and support links.

Contents:

- current app version
- current update status
- `Check for Updates` or `Update Available`
- `Submit Feedback`

Optional supporting text can explain local-first behavior in one short paragraph.

## Behavior Contracts

### Paste Last Dictation

- Source of truth is the newest saved dictation
- action targets the last non-Transcripted app when possible
- action uses the same clipboard-restore paste behavior as live dictation
- if no saved dictation exists, disable the action and explain why

### Transcribe Audio File

- appears on `General`
- does not appear in the menubar popover in this version

### Update Status

- update availability is probed silently in the background
- the menubar popover and `About` page reflect the same status model
- clicking the updates row always hands off to the normal Sparkle flow

## Out Of Scope

- no recents browser in the menubar popover
- no dedicated `Advanced` page
- no dedicated `Audio Files` sidebar page
- no decorative theme treatment
