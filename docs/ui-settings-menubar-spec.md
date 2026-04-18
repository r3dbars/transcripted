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
- `Shortcuts`
- `Meetings`
- `Dictations`
- `Storage`
- `Connect Your Agent`
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

## Settings Window

### Home

Purpose:
Show the simplest ways to use Transcripted and surface high-value status.

Contents:

- large action buttons for:
  - `Start Dictation`
  - `Start Meeting`
  - `Transcribe Audio File…`
  - `Connect Agent`
- setup/status cards for:
  - local model readiness
  - permissions health
  - capture library location
- app-wide transcription model controls for:
  - choosing the local speech model used by both dictation and meetings
  - showing whether that model is bundled, already cached, or needs a one-time download
  - saying which host Transcripted will contact when the selected model is missing
- quick links into the most important pages

### Shortcuts

Purpose:
Own all keyboard-trigger setup.

Contents:

- dictation shortcut recorder
- meeting shortcut recorder
- `Tap the right Option key to start dictation`

This page should not own privacy, storage, or analytics controls.

### Meetings

Purpose:
Own meeting-specific capture and meeting-speaker behavior.

Contents:

- `Start Meeting`
- `Transcribe Audio File…`
- local speaker split toggle
- speaker people management

Imported audio transcription lives here because it uses the meeting transcription pipeline.

### Dictations

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

### Connect Your Agent

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
- appears on `Meetings`
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
