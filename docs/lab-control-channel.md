# Lab control channel

A file-drop control channel that lets a local experiment harness drive the
**real running app**: start/stop dictation, start/stop a meeting, import an
audio file, and read status. The hill-climb lab uses it to measure
press-to-recording and Stop-to-notes on the real app instead of only on benches.

- App side: `Sources/Support/LabControlChannel.swift` (runtime) and
  `Sources/Support/LabControlCommand.swift` (pure parsing/validation, covered by
  `Tests/LabControlCommandTests.swift`)
- Launch hook: one line at the end of `applicationDidFinishLaunching` in
  `Sources/TranscriptedApp.swift`
- Client: `scripts/hillclimb/lab_control.py` (stdlib Python, `--self-test` runs on Linux)

## Safety model

**Off unless the process was launched with `TRANSCRIPTED_LAB_CONTROL_DIR` set
to an absolute path.** That's the only switch. There's no UI toggle, no
`UserDefaults` key, and no plist override, so nothing a user clicks and nothing
persisted can turn it on. A Finder, Dock, or login-item launch never carries
that variable, so a normal user launch can't enable it. A blank or relative
value keeps it off (and prints one `LAB_CONTROL | ignored` line to stderr).

Why env-at-launch is the gate: whoever sets a process's environment already
controls that process. The same person could attach a debugger or swap the
binary. So the channel gives nothing to anyone who didn't already have it.

Why a same-user drop directory isn't a new trust boundary: any process running
as the same macOS user can already read that user's files, including every
saved meeting and dictation, and can already post synthetic key events if it
has Accessibility access. Being able to write into a directory that the user
chose at launch doesn't add a capability that process lacked. It's still off by
default anyway, because a debug hook that's always on invites surprises. The
channel creates `inbox/` and `done/` with mode `0700` and `responses.jsonl` with
`0600`. Pick a directory that only you can write to (not `/tmp` on a shared
machine).

What the channel itself never does:

- send anything to Sentry or PostHog, or write its own events to `events.jsonl`
  (it only writes `responses.jsonl` in the lab dir, plus one stderr line at startup)
- echo transcript text, titles, device names, or file paths back in responses.
  Responses carry ids, booleans, a pid, short state names, and error codes.
- touch audio threads. Everything runs on the main actor from a 250 ms polling task.

Heads-up: the dictation and meeting flows it triggers are the app's normal
flows, so **they still emit their normal telemetry**, just as they would from a
menu click. `POSTHOG_API_KEY` and `SENTRY_DSN` can't be blanked from the
environment (an empty value falls back to `Info.plist`). For lab runs on the
owner's Mac, turn off "Share anonymous analytics" and crash reporting in
Settings, or use a build without those keys.

## Protocol

Directory layout under `$TRANSCRIPTED_LAB_CONTROL_DIR`:

```
inbox/            drop commands here as *.json (write *.json.tmp, then rename)
done/             each processed command file is moved here
responses.jsonl   one JSON line per processed command, appended
```

Command file:

```json
{"id": "a1b2c3", "command": "start_meeting", "args": {}}
```

- `id`: 1–128 chars of `[A-Za-z0-9._:-]`. Echoed back so you can match the response.
- The app reads only files ending in `.json` that don't start with `.`, in
  file-name order. The client prefixes names with `time.time_ns()`, so send
  order is execution order.
- Commands run **serially**. `start_meeting`, `stop_meeting`, and
  `import_audio` wait for the app call to return before the next command runs.
- Each file is moved to `done/` **before** it runs, so a command never runs twice.
- Files over 64 KB, non-regular files (FIFOs, symlinks, dirs), malformed JSON,
  unknown commands, and unknown or ill-typed args all get an `ok: false`
  response and still move to `done/`. None of them can crash the app.

Response line:

```json
{"id": "a1b2c3", "command": "start_meeting", "file": "000…-a1b2c3.json", "ok": true,
 "result": {"meeting_state": "recording", "...": "..."},
 "at": "2026-09-23T10:00:03.412Z", "received_monotonic_ms": 812345, "monotonic_ms": 813901}
```

- `ok: false` comes with an `error` code. When the file wasn't usable JSON,
  `id` and `command` are `null`.
- `at` is wall-clock ISO 8601 with milliseconds, the same format as the
  `timestamp` field in `events.jsonl`, so the two can be compared directly.
- `received_monotonic_ms` is when the channel picked the file up.
  `monotonic_ms` is when the command finished. Both come from
  `ProcessInfo.systemUptime` (mach_absolute_time, pauses during sleep).
  `monotonic_ms - received_monotonic_ms` is how long the app call took.

### Commands

| command | args | calls (same path as) | ok means | errors |
|---|---|---|---|---|
| `ping` | none | nothing | channel is up; `result.pid` | none |
| `status` | none | reads state only | snapshot in `result` | none |
| `start_dictation` | none | `menuStartDictation()` (Capture > Start Dictation, ⌘D) | a dictation session began (`isDictating`); the mic opens asynchronously | `dictation_already_active`, `dictation_not_started` |
| `stop_dictation` | `paste`: bool, default `true` | `sessionController.stopDictationAndPaste(trigger: .menu, autoPaste:)` (status-item quick menu Stop Dictation) | stop was requested; transcribe/paste/save continue asynchronously | `dictation_not_active`, `invalid_arg:paste` |
| `start_meeting` | none | `meetingSession.startRecording(trigger: .menu)` (menu-bar panel Record) | the call returned `true`, so capture is recording | `meeting_capture_active`, `meeting_not_started` |
| `stop_meeting` | none | `stopRecording(reason: .menuBarStopButton)`, or `stopRecordingJoiningPendingStart` while starting (menu-bar panel Stop) | capture stopped and the meeting is queued for transcription | `meeting_not_recording` |
| `import_audio` | `path`: absolute path to an audio/video file | `meetingSession.importAudioFile(from:)` (what Capture > Transcribe Audio File… calls once its open panel returns; the panel is skipped) | the import was queued | `meeting_capture_active`, `file_not_found`, `import_not_started`, `missing_arg:path`, `invalid_arg:path` |

Every command can also fail with `malformed_json`, `not_an_object`,
`payload_too_large`, `not_a_regular_file`, `unreadable_file`, `missing_id`,
`invalid_id`, `missing_command`, `invalid_command`, `unknown_command`,
`invalid_args`, `unknown_arg[:name]`, or `app_unavailable`.

`status` result keys: `pid`, `dictation_active`, `stt_recording`,
`stt_transcribing`, `stt_model_loaded`, `meeting_state` (`idle`,
`loading_models`, `ready`, `starting_recording`, `recording`,
`stopping_recording`, `transcribing`, `error`), and `meeting_capture_active`.
The successful start/stop/import commands return the same snapshot.

`import_audio` is included because a clean app entry point exists: the menu
command's open panel only picks a URL, then hands it to
`MeetingSessionController.importAudioFile(from:)`. The channel calls that same
function. It doesn't show the "stop the meeting first" alert. It returns
`meeting_capture_active` instead.

`start_dictation` pastes into whatever app `resolvedSourceApp()` picks (the last
frontmost external app), same as the menu command. Send
`stop_dictation {"paste": false}` to skip paste and auto-send and only
transcribe and save. That removes the paste stage from `stop_to_done_ms`.

## Where the timings come from

The channel doesn't duplicate event plumbing. The app already writes these
lines to `events.jsonl` (`~/Library/Application Support/Transcripted/logs/`, or
`$TRANSCRIPTED_CONTAINER_DIR/logs/`). Each line has `timestamp` (ISO 8601 with
ms), `engine`, `event`, `level`, and a string-valued `context`. Info-level lines
are buffered for up to 0.5 s before they hit disk. That delays when you can see
them but doesn't change the timestamps, which are taken when the event happens.
`lab_control.py tail-events --offset N --event NAME` reads new lines and keeps
only numeric context values and a few short labels.

### Dictation press-to-recording

- **Primary:** `dictation_started.context.request_to_recording_ms`. It runs
  from entry into `startDictation` (which `start_dictation` calls right away)
  to the mic being live. It's emitted on both the ready-engine fast path and
  the wait-for-engine path.
- Breakdown: `dictation_recording_fast_start` (fast path: `start_ms`,
  `pre_recording_overhead_ms`) or `dictation_started_after_wait` (slow path:
  `wait_ms`, `start_attempts`).
- Cross-check: `dictation_started.timestamp - dictation_start_requested.timestamp`.
- Channel overhead isn't part of either number. The file-pickup delay (up to
  250 ms of polling) happens before `startDictation` is called.

### Dictation Stop-to-done

- **Primary:** `dictation_stop_latency_measured.context.stop_to_done_ms`,
  measured from `stopDictationAndPaste` entry to the session being fully done.
- Also in the same event: `stop_to_paste_ms`, `stop_to_save_ms`,
  `stop_to_mic_stop_ms`, `model_wait_ms`, `decode_ms`, `cleanup_ms`,
  `paste_ms`, `auto_enter_ms`, `save_ms`, `finalization_ms`. A key is missing
  when that stage didn't run.

### Meeting press-to-recording

- **Primary:** `meeting_recording_started.timestamp - meeting_start_requested.timestamp`.
- Same-clock alternative with no log parsing: the `start_meeting` response's
  `monotonic_ms - received_monotonic_ms`. The command returns only after
  `startRecording` resolves, so this covers the whole start plus a few ms of
  channel work. Use it only when `ok` is `true`.

### Meeting Stop-to-notes

- **Primary:** `meeting_transcript_saved.timestamp - meeting_stop_requested.timestamp`.
  That's the Markdown transcript being written.
- Finished artifact: `meeting_transcript_artifact_ready.timestamp - meeting_stop_requested.timestamp`
  (after title/restyle).
- Breakdown: `meeting_recording_stopped` (capture teardown done) and
  `meeting_pipeline_phase` (`phase` = `getting_ready`, `transcribing` with
  `progress_pct`, `finishing`).
- Pairing: take the first `meeting_transcript_saved` after the
  `meeting_stop_requested`. That's only unambiguous when nothing else is
  queued, so check `status` shows `meeting_state` other than `transcribing`
  before you start, and run one meeting at a time. The `queue_depth` context
  field shows queued work.
- Imports: `meeting_file_import_requested` → `meeting_transcript_saved`.

Wall-clock differences are fine for these because both ends come from the same
process clock within seconds of each other. Don't subtract client
`time.monotonic()` values from app `monotonic_ms` unless you've checked the
clocks agree. Both should be mach_absolute_time on macOS, and a `ping` whose
`received_monotonic_ms` falls between the client's `sent_monotonic_ms` and
`received_monotonic_ms` confirms it.

## Try it by hand on the Mac

```bash
# 0. Quit any running Transcripted (the single-instance guard would make the lab copy exit).
osascript -e 'quit app "Transcripted"'

# 1. Build (or use an installed copy).
bash build.sh --no-open

# 2. Launch with the channel on. For an .app this uses `open -n --env ...`, so
#    LaunchServices starts it and the app itself (not Terminal) owns mic/TCC.
LAB=~/transcripted-lab/run1
python3 scripts/hillclimb/lab_control.py launch --dir "$LAB" --app build/Transcripted.app

# 3. Drive it.
python3 scripts/hillclimb/lab_control.py send status --dir "$LAB"
OFFSET=$(stat -f %z ~/Library/Application\ Support/Transcripted/logs/events.jsonl)
python3 scripts/hillclimb/lab_control.py send start_dictation --dir "$LAB"
sleep 3
python3 scripts/hillclimb/lab_control.py send stop_dictation --dir "$LAB" --args '{"paste": false}'
sleep 3
python3 scripts/hillclimb/lab_control.py tail-events --offset "$OFFSET" \
  --event dictation_started --event dictation_stop_latency_measured

python3 scripts/hillclimb/lab_control.py send start_meeting --dir "$LAB" --timeout 60
sleep 20
python3 scripts/hillclimb/lab_control.py send stop_meeting --dir "$LAB" --timeout 120
# poll until the notes land
python3 scripts/hillclimb/lab_control.py tail-events --offset "$OFFSET" \
  --event meeting_start_requested --event meeting_recording_started \
  --event meeting_stop_requested --event meeting_transcript_saved

python3 scripts/hillclimb/lab_control.py send import_audio --dir "$LAB" \
  --args '{"path": "/absolute/path/to/fixture.wav"}' --timeout 120

# 4. Quit normally when done (menu bar > Quit). Relaunch from Finder = channel off.
```

Manual equivalent without the client:

```bash
mkdir -p "$LAB/inbox"
printf '{"id":"p1","command":"ping"}' > "$LAB/inbox/1-p1.json.tmp" && mv "$LAB/inbox/1-p1.json.tmp" "$LAB/inbox/1-p1.json"
tail -n1 "$LAB/responses.jsonl"
```

Options on `launch`:

- `--container DIR` sets `TRANSCRIPTED_CONTAINER_DIR` so captures, logs, and
  state go to a throwaway root instead of the real library. Then read events
  with `tail-events --container DIR`. Model caches may re-download under a
  fresh container.
- `--allow-second-instance` sets `TRANSCRIPTED_DISABLE_SINGLE_INSTANCE_GUARD=1`.
  Only use it when a normal copy must keep running. Two copies share hotkeys,
  the mic, and (without `--container`) the same state files. Quitting the
  normal copy is better.
- `--exec` runs the binary directly instead of `open -n`. The app then
  inherits Terminal's TCC identity, so mic and system-audio prompts are
  attributed to Terminal.
- `launch` deletes leftover `inbox/*.json` from earlier runs before starting,
  and `send` withdraws its command file on timeout, so a stale `start_meeting`
  can't fire on a later launch.

## Limitations

- Swift side is unverified until the first Mac build. `build.sh` picks up new
  files under `Sources/` automatically. `LabControlCommand.swift` is also listed
  in `run-tests.sh` `APP_SOURCES` for the fast test.
- Serial processing means `status` waits behind an in-flight `start_meeting`,
  which can take several seconds.
- The channel starts at the end of `applicationDidFinishLaunching`, before
  model warmup finishes. An early `start_dictation` takes the wait-for-engine
  path, and `dictation_started_after_wait` shows that.
