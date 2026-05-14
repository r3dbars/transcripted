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

The header shows:

- app name
- current readiness summary
- progress or warning detail only when needed

Examples:

- `Ready for dictation and meetings`
- `Meeting tools are still loading`
- `Local voice setup needs attention`

### Primary actions

The first action group contains:

- `Start Dictation`
- `Start Meeting`
- `Paste Last Dictation`

Rules:

- `Paste Last Dictation` pastes the newest saved dictation into the current text field
- if automatic paste is not possible, it falls back to copying and explains why
- buttons should show short supporting detail text, not just labels

### Secondary actions

The second action group contains:

- `Connect Agent`
- `Submit Feedback`
- dynamic updates row
- `Open Settings`
- `Quit`

The updates row changes state:

- default: `Check for Updates`
- while probing: `Checking for Updates…`
- update found: `Update Available`

When an update is found, the row also shows the available version as supporting text, for example:

- `Version 1.1.10 ready`

Primary action rows can be hidden from switches on the matching Settings
`Home` action tiles where the control is surfaced:

- `Start Dictation`
- `Start Meeting`

These switches default on. Hovering a switch explains that it shows or hides the
matching row in the menu bar popover. The action arrow on each tile should read
as an explicit icon button and expose a short hover description for the action.

Utility rows such as `Connect Agent`, `Submit Feedback`, updates, `Settings`,
and `Quit` remain visible in this version.

## Settings Window

### Home

Purpose:
Show the simplest ways to use Transcripted and surface high-value status.

Contents:

- top-of-page unfinished meeting warnings, when a meeting needs retry/delete
- large action buttons for:
  - `Start Dictation`
  - `Start Meeting`
  - `Transcribe Audio File…`
  - `Connect Agent`
- recent activity for:
  - meetings, including retained-audio playback when available
  - dictations
- setup/status cards for:
  - local model readiness
  - permissions health
  - capture library location
- quick links into the most important pages

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
Own startup and custom words.

Contents:

- launch at login
- custom words and spoken-text corrections

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

Meeting start, audio import, recent meeting transcripts, and unfinished meeting repair live on `Home`.

### Dictation

Purpose:
Own dictation-specific behavior after speech has been captured.

Contents:

- `Paste Last Dictation`
- explanation of paste-back behavior
- `Play dictation feedback sounds`
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

### Privacy

Purpose:
Keep permissions and off-device reporting controls together.

Contents:

- permission status rows for:
  - microphone
  - accessibility
  - system audio recording
  - calendar
- meeting microphone processing toggle
- `Send crash and error reports`
- `Send anonymous usage statistics`
- `Send Test Sentry Event`

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

- appears on `Home`
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
