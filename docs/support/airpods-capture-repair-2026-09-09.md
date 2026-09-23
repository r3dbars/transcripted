# AirPods capture repair — 2026-09-09

## Report and evidence

A customer reported failed AirPods dictation and missing local speech in meetings.
The retained diagnostic excerpt contains dictation events only. macOS input
and output were Bluetooth, but Transcripted selected `built_in` with
`selection_reason=preferredBuiltInForBluetoothHeadset`. Format readiness and
sample flow stayed false until `microphone_start_timeout`. No customer audio,
meeting diagnostics, app version, or hardware model was provided.

This proves an input override and a failed startup, not an AirPods hardware
fault or a particular meeting-capture root cause.

## Repair

- Normal dictation follows the selected macOS input, including AirPods.
  The existing Faster Bluetooth dictation opt-in still recommends a local mic
  and retains its external-capture and ownership protections. (Update
  2026-09-23: that opt-in was removed. It switched the Mac-wide mic, so Zoom
  followed it. The pinned-device recorder now records the built-in mic when
  Bluetooth headphones are the output, without touching the system default;
  see `ParakeetPinnedMicrophone.swift` in `Sources/Speech/CLAUDE.md`.)
- Recovery accepts matched native Bluetooth speech formats at 8, 16, and
  24 kHz. Invalid formats and stale mismatched speech buses still wait.
- The timeout message identifies the unavailable built-in mic without claiming
  Bluetooth caused the failure.
- Meetings retain automatic Bluetooth isolation by default. Settings → Meetings
  adds **Use Mac-selected microphone** for users who explicitly want AirPods or
  another macOS-selected input. It applies to the next recording; capture
  snapshots the preference and retains existing bounded route recovery.
- An explicit meeting input must be identified and bound successfully. A failed
  request must not start recording on an unverified microphone.

Keeping the meeting default matters: PRs #1537 and #1565 restored automatic
isolation after a report that Zoom lost outgoing speech while Transcripted held
the Bluetooth microphone. That report did not establish a universal hardware
cause; this repair gives users a choice without reversing the default.

## Verification

The original dictation selection policy replay selected the built-in input and
failed the headset-selection assertion. The patched replay selects Bluetooth
and passes. The focused selection suite passed all 78 assertions.

Matched Bluetooth recovery formats produced nine failed assertions before the
readiness repair and zero afterward. These tests use real selection/readiness
code and fake device binding; they do not record hardware audio.

The settings image in `.agent-review/visuals/meeting-microphone-settings.png`
renders the production row and controls in both states using an isolated
NSHostingView. It verifies layout, not the complete app interaction flow.

The independent review found a failed explicit-input bind could accept an
unverified graph; that finding is included in the repair. Final build and QA
results are recorded in the PR description.

## Live checks before release

1. Select AirPods in macOS Sound → Input.
   Dictate through a physical trigger; confirm transcript text and successful
   pasteback, then repeat after disconnect/reconnect and sleep/wake.
2. Turn on Use Mac-selected microphone. Record a meeting and confirm local
   speech in retained microphone audio and the transcript. Change the setting
   during capture; verify it changes only the next recording.
3. With a second Zoom/Meet participant, confirm outgoing speech before, during,
   and after both dictation and meeting capture. Check Bluetooth playback and
   test both automatic and explicit meeting modes.
4. Confirm built-in/USB routes retain their behavior. Failed explicit input
   binding must retry/fail without claiming that a different microphone is
   the selected one.

No email was sent and no user-facing release was published by this repair task.
