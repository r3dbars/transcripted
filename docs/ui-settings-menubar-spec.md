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

It uses a native macOS sidebar with these pages (`TranscriptedSettingsPage`):

- `Today` (the default page, ⌘1)
- `Meetings` (raw value `home`, kept so automation ids and analytics stay stable, ⌘2)
- `Dictations` (⌘3)
- `Writing` (⌘4)
- `Speakers` (raw value `people`, ⌘5)
- `Agent` (raw value `connectAgent`, ⌘6)
- `Settings` (a labelled row under the six, with Feedback and the version; one combined page, see "Card layout" below)

The old `Transcribe a file` page (raw value `files`) is retired: file import lives on Meetings, and `.files` redirects there so old deep links and analytics ids still land.

There is no separate `Advanced` page; the Settings page has one Advanced disclosure (below).

The per-area sections below (Shortcuts, General, Models, People, Dictation,
Storage, Agent, About) began as separate pages. Today Shortcuts, General,
Models, Dictation, Storage and About are cards on the one Settings page,
People is the Speakers page, and Agent is its own page. Their purpose lines
still hold.

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

- a status line while a meeting starts, a transcript is being made, or the
  voice model is warming up (with progress); saving shows on the button only
- a one-line shortcut warning, clickable when it has a fix to open

A ready, idle popover shows no header at all.

### Buttons

Two small buttons sit side by side at the top:

- `Record` (Record Meeting; becomes `Stop` with the elapsed time while recording)
- `Dictate` (Start Dictation; becomes `Done` while dictating)

Rules:

- each button shows its shortcut only when it fits; the full title stays the
  accessibility label
- setup or failure detail moves to the button's tooltip
- `Paste Last Dictation` has no row and no shortcut; a take that didn't paste says so on screen with Paste again

### Utility rows

Under the buttons:

- `Open Transcripted` (Settings lives inside it)
- `Quit`

The idle popover is four controls. An update row appears only while an update
downloads (`Downloading update`); a filled callout (`Update to X` / Install,
`X is ready` / Restart) appears when it needs a click. The manual check is
Settings › Advanced › About (`Check for updates`) and a click on the sidebar's
version line; there is no app-menu item. Words come from
`Sources/UI/Shared/UpdateStatusWords.swift`.

### Status item

A template glyph in every state, never tinted: outline (idle), filled
(dictating), filled with a dot (meeting), outline with a ring (making a
transcript), outline with a solid dot (the key needs Accessibility, or an
update needs a click). Left and right click open the same popover.

## Settings Window

### Meetings (`home`)

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

- one dictation key recorder, with its behavior (Hold or tap, Hold only, Tap to toggle)
- meeting shortcut recorder
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

Meeting start, recent meeting transcripts, and unfinished meeting repair live on `Meetings`.

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

The combined settings page shows four groups under mono section labels:
Dictation (Dictation key, Behavior, Microphone, Clean up pasted text,
Auto-send), Meetings (Meetings key, Auto-detect calls, Live transcript),
Library (Folder, Keep meeting audio, Keep dictation audio, Free up space) and
Privacy (Crash reports, Usage stats, Send diagnostics). One disclosure,
Advanced, holds everything else, grouped: Dictation (Sounds, Muffle, island in
screen sharing, Keyboard shortcuts), Meetings (mic mute control,
mic processing, People in the room), Transcription (voice model, meeting
language, Corrections, Transcribe a file), App (Launch at login, Show in Dock,
Support files), Permissions, About (version, Automatic updates, Feedback) and
Developer Preview. It remembers whether it's open. Permissions and the voice
model show above Dictation instead whenever they need attention. Auto-send's
send key and per-app switches show under it while it's on. Rows carry at most
a few words; each row's explanation lives in its ⓘ info popover. The page ends
with a privacy line. Corrections open in a sheet. While the Mac mic recorder
(`PinnedMicrophoneCapturePreferences`) is on, Microphone is one picker for
dictation and meetings (Automatic, a specific mic, or "Same as macOS Sound
settings") and Advanced drops "Use Mac-selected microphone". With it off,
Dictation keeps Faster Bluetooth dictation and its mic picker.

### About

Purpose:
Cover app identity, updates, and support links.

Contents:

It sits inside Settings › Advanced.

- current app version and update status on one line
- one update button whose word follows the status (`Check for updates`,
  `Install`, `Restart`, ...; see `UpdateStatusWords.buttonTitle`)
- `Automatic updates` (`Check on launch` / `Notify me` / `Download automatically`)
- `Feedback` (`Send feedback…`)

Send diagnostics is not here; it sits in the Privacy group next to Crash reports.

Optional supporting text can explain local-first behavior in one short paragraph.

## Behavior Contracts

### Paste Last Dictation

- Source of truth is the newest saved dictation
- action targets the last non-Transcripted app when possible
- action uses the same clipboard-restore paste behavior as live dictation
- if no saved dictation exists, disable the action and explain why

### Transcribe Audio File

- appears in Settings › Advanced › Transcription (`Transcribe a file`)
- appears in the Meetings page header's ⋯ menu, and on ⌘O and a file drop
- appears as the second action on the Meetings page's empty state
- does not appear in the menubar popover in this version

### Update Status

- update availability is probed silently in the background
- the menubar popover and `About` page reflect the same status model
- clicking the updates row always hands off to the normal Sparkle flow

## Out Of Scope

- no recents browser in the menubar popover
- no dedicated `Advanced` page (one Advanced disclosure on the Settings page)
- no dedicated `Audio Files` sidebar page
- no decorative theme treatment
