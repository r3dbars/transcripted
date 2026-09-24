# Lab control channel

A file-drop control channel that lets a local experiment harness drive the
**real running app**: start/stop dictation, start/stop a meeting, import an
audio file, and read status. The hill-climb lab uses it to measure
press-to-recording and Stop-to-notes on the real app instead of only on benches.

- **Lab builds only.** `bash build.sh --lab` (or `TRANSCRIPTED_LAB_BUILD=1 bash build.sh`)
  adds `-D TRANSCRIPTED_LAB_CONTROL`. Without it the channel isn't compiled in.
- App side: `Sources/Support/LabControlChannel.swift` (runtime, wrapped in
  `#if TRANSCRIPTED_LAB_CONTROL`) and `Sources/Support/LabControlCommand.swift`
  (pure parsing/validation and the file/dir accept rules, compiled into every
  build and covered by `Tests/LabControlCommandTests.swift`)
- Launch hook: one `#if TRANSCRIPTED_LAB_CONTROL` line at the end of
  `applicationDidFinishLaunching` in `Sources/TranscriptedApp.swift`
- Client: `scripts/hillclimb/lab_control.py` (stdlib Python, `--self-test` runs on Linux)

## Safety model

### Why it's compiled out of release builds

An earlier version shipped in every build and was switched on only by
`TRANSCRIPTED_LAB_CONTROL_DIR` in the launch environment. That's not a trust
boundary for this app. The release build is signed with the hardened runtime
and holds mic, system-audio, and Accessibility grants. Any process running as
the same user can put a variable into the app's launch environment without
touching its signature: `launchctl setenv` reaches every app launchd starts
afterwards (Finder, Dock, and login-item launches included) until logout, and
`open -n --env` relaunches it directly. With the channel on, that process
could record the mic and system audio, paste text into the frontmost app, or
make the app read any file it can reach, all under Transcripted's TCC grants
instead of its own. The old argument ("whoever sets the environment already
controls the process, they could attach a debugger or swap the binary") is
false here: the hardened runtime blocks attaching, and swapping the binary
breaks the code signature the TCC grants are tied to.

So the channel is compile-time only:

- `LabControlChannel.swift` and its launch hook sit behind
  `#if TRANSCRIPTED_LAB_CONTROL`. Only `build.sh --lab` sets that flag.
- `build-beta.sh` (the beta/release path, also used by
  `.github/workflows/release-candidate.yml`) never sets it, exits if
  `TRANSCRIPTED_LAB_BUILD` is set, and fails the build if the compiled app
  binary contains the string `TRANSCRIPTED_LAB_CONTROL_DIR`. That literal only
  exists inside the `#if` block, so the check trips only when the channel was
  compiled in.
- **Lab builds are local ad-hoc/dev builds. Never distribute one**, never sign
  one for anyone else's Mac, and don't leave one installed as your everyday
  copy. On a lab build the `launchctl setenv` problem above still applies to
  your own machine for as long as it's running.

### Checks inside a lab build

- Still **off unless launched with `TRANSCRIPTED_LAB_CONTROL_DIR`** set to an
  absolute path. No UI toggle, no `UserDefaults` key. A blank or relative value
  keeps it off and prints one `LAB_CONTROL | ignored` line to stderr.
- The control dir, `inbox/`, and `done/` must be real directories (checked with
  `lstat`, so a symlink is refused), owned by the app's uid, with mode `0700`
  exactly. Missing ones are created `0700` (only the last path component; the
  parent must exist). An existing one with another owner or mode, or a symlink,
  makes the channel refuse to start with one `LAB_CONTROL | disabled: ...`
  stderr line. It never chmods or chowns anything.
- `responses.jsonl`, if it exists, must be a regular file owned by the app's
  uid. It's opened `O_NOFOLLOW` and re-checked with `fstat` on every append,
  and created `0600`.
- The layout is re-checked on every 250 ms poll. If anything was swapped, the
  channel stops (`LAB_CONTROL | stopped: ...`).
- Command files are opened `O_RDONLY|O_NOFOLLOW|O_NONBLOCK`, then `fstat` on
  the open fd must say regular file, owned by the app's uid, at most 64 KB.
  A symlink fails the open. A FIFO opens without blocking and is then refused.
- Processed files move to `done/` with `rename(2)`, which never follows a
  symlink and replaces a same-named entry inside `done/` in place. If the move
  fails, only the inbox entry is unlinked. Nothing outside `inbox/` and `done/`
  is ever deleted.

What the channel itself never does:

- send anything to Sentry or PostHog, or write its own events to `events.jsonl`
  (it only writes `responses.jsonl` in the lab dir, plus stderr lines)
- echo transcript text, titles, device names, or file paths back in responses.
  Responses carry ids, booleans, a pid, short state names, and error codes.
- bring another app to the front, or paste unless a command explicitly says
  `"paste": true`
- touch audio threads. Everything runs on the main actor from a 250 ms polling task.

### Isolation and telemetry (`lab_control.py launch`)

The flows the channel triggers are the app's normal flows, so they write to
the capture library, the speaker database, dictation history and Home stats,
and **they emit normal telemetry**, just like a menu click. `POSTHOG_API_KEY`
and `SENTRY_DSN` can't be blanked from the environment (an empty value falls
back to `Info.plist`). So `launch` isolates by default and refuses otherwise:

- `--container DIR` is required unless you pass `--use-real-library`. It sets
  `TRANSCRIPTED_CONTAINER_DIR`, which moves the default library, logs, and
  state under DIR.
- `UserDefaults` are **not** isolated by the container (same bundle id). If
  `defaults read com.justinbetker.draft transcriptSaveLocation` returns a
  path, the app saves into that relocated library even with `--container`, so
  `launch` refuses unless `--use-real-library`.
- `launch` also refuses unless both `observability-anonymous-analytics-enabled`
  and `observability-crash-reporting-enabled` read as `0` in that domain (a
  missing key means on). Turn off "Share anonymous analytics" and crash
  reporting in Settings, or pass `--allow-telemetry` if you really mean it.
- The client only reads preferences (`defaults read`). It never writes them.

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
- Files over 64 KB, non-regular files (FIFOs, symlinks, dirs), files owned by
  another user, malformed JSON, unknown commands, and unknown or ill-typed args
  all get an `ok: false` response and still move to `done/`. None of them can
  crash the app.

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
| `start_dictation` | none | `sessionController.startDictation(sourceApp: nil, trigger: .menu)`, the call Capture > Start Dictation (⌘D) ends in, minus its activate-the-last-app step | a dictation session began (`isDictating`); the mic opens asynchronously | `dictation_already_active`, `dictation_not_started` |
| `stop_dictation` | `paste`: bool, default `false` | `sessionController.stopDictationAndPaste(trigger: .menu, autoPaste:)` (status-item quick menu Stop Dictation) | stop was requested; transcribe/paste/save continue asynchronously | `dictation_not_active`, `invalid_arg:paste` |
| `start_meeting` | none | `meetingSession.startRecording(trigger: .menu)` (menu-bar panel Record) | the call returned `true`, so capture is recording | `meeting_capture_active`, `meeting_not_started` |
| `stop_meeting` | none | `stopRecording(reason: .menuBarStopButton)`, or `stopRecordingJoiningPendingStart` while starting (menu-bar panel Stop) | capture stopped and the meeting is queued for transcription | `meeting_not_recording` |
| `import_audio` | `path`: absolute path to an audio/video file | `meetingSession.importAudioFile(from:)` (what Capture > Transcribe Audio File… calls once its open panel returns; the panel is skipped) | the import was queued | `meeting_capture_active`, `file_not_found`, `import_not_started`, `missing_arg:path`, `invalid_arg:path` |

Every command can also fail with `malformed_json`, `not_an_object`,
`payload_too_large`, `not_a_regular_file`, `wrong_owner`, `unreadable_file`, `missing_id`,
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

`start_dictation` deliberately differs from the menu command in one way. The
menu path (`startDictationFromSettings`) calls `resolvedSourceApp()?.activate`
first, which brings the last frontmost external app to the front and makes it
the paste target. The channel calls the same
`DictationSessionController.startDictation(sourceApp:trigger:)` with no source
app instead, so nothing is activated and no paste target is captured. The
trigger is still `.menu`, so the events and start plan match a menu start.

`stop_dictation` defaults to `paste: false`: the transcript is transcribed and
saved, with no paste and no auto-send, and the paste stage is absent from
`stop_to_done_ms`. Only an explicit `{"paste": true}` pastes, into whatever app
is frontmost at stop time (and presses Return if auto-send is on). The client
refuses to send that unless you pass `--paste`.

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

# 1. Build a LAB build. A normal or installed copy has no channel.
bash build.sh --no-open --lab

# 2. Check the preflight inputs (read-only). Turn analytics and crash reporting
#    off in Settings first; clear a relocated library or use --use-real-library.
defaults read com.justinbetker.draft transcriptSaveLocation
defaults read com.justinbetker.draft observability-anonymous-analytics-enabled
defaults read com.justinbetker.draft observability-crash-reporting-enabled

# 3. Launch with the channel on, isolated in a throwaway container. For an .app
#    this uses `open -n --env ...`, so LaunchServices starts it and the app
#    itself (not Terminal) owns mic/TCC.
mkdir -p ~/transcripted-lab
LAB=~/transcripted-lab/run1
CONTAINER=~/transcripted-lab/container1
python3 scripts/hillclimb/lab_control.py launch --dir "$LAB" --container "$CONTAINER" --app build/Transcripted.app

# 4. Drive it.
python3 scripts/hillclimb/lab_control.py send status --dir "$LAB"
OFFSET=$(stat -f %z "$CONTAINER/logs/events.jsonl")
python3 scripts/hillclimb/lab_control.py send start_dictation --dir "$LAB"
sleep 3
python3 scripts/hillclimb/lab_control.py send stop_dictation --dir "$LAB"   # no paste unless --paste
sleep 3
python3 scripts/hillclimb/lab_control.py tail-events --container "$CONTAINER" --offset "$OFFSET" \
  --event dictation_started --event dictation_stop_latency_measured

python3 scripts/hillclimb/lab_control.py send start_meeting --dir "$LAB" --timeout 60
sleep 20
python3 scripts/hillclimb/lab_control.py send stop_meeting --dir "$LAB" --timeout 120
# poll until the notes land
python3 scripts/hillclimb/lab_control.py tail-events --container "$CONTAINER" --offset "$OFFSET" \
  --event meeting_start_requested --event meeting_recording_started \
  --event meeting_stop_requested --event meeting_transcript_saved

python3 scripts/hillclimb/lab_control.py send import_audio --dir "$LAB" \
  --args '{"path": "/absolute/path/to/fixture.wav"}' --timeout 120

# 5. Quit normally when done (menu bar > Quit). Don't keep the lab build as
#    your everyday copy; reinstall/relaunch the normal app.
```

Manual equivalent without the client (the dirs must be `0700`):

```bash
mkdir -m 700 -p "$LAB" && mkdir -m 700 -p "$LAB/inbox" "$LAB/done"
printf '{"id":"p1","command":"ping"}' > "$LAB/inbox/1-p1.json.tmp" && mv "$LAB/inbox/1-p1.json.tmp" "$LAB/inbox/1-p1.json"
tail -n1 "$LAB/responses.jsonl"
```

Options on `launch`:

- `--container DIR` (required unless `--use-real-library`) sets
  `TRANSCRIPTED_CONTAINER_DIR` so captures, logs, and file state go to a
  throwaway root instead of the default library. Preferences stay shared, and a
  relocated `transcriptSaveLocation` still wins, which is why `launch` refuses
  in that case. Read events with `tail-events --container DIR`. Model caches
  may re-download under a fresh container.
- `--use-real-library` allows launching without a container, or with a
  relocated library. Lab meetings, imports, and dictations then land in the
  real library, speaker database, and dictation history.
- `--allow-telemetry` launches even when analytics or crash reporting is on.
- `--dir` must be a new directory (created `0700`) or an existing one that's
  already `0700` and yours. The client never chmods an existing directory.
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

- Swift side is unverified until the first Mac build (`bash build.sh --no-open
  --lab`, plus a normal `bash build.sh --no-open` to confirm the channel
  compiles out). `build.sh` picks up new files under `Sources/` automatically.
  `LabControlCommand.swift` is also listed in `run-tests.sh` `APP_SOURCES` for
  the fast test; `LabControlChannel.swift` isn't, and needs no stub there.
- Serial processing means `status` waits behind an in-flight `start_meeting`,
  which can take several seconds.
- The channel starts at the end of `applicationDidFinishLaunching`, before
  model warmup finishes. An early `start_dictation` takes the wait-for-engine
  path, and `dictation_started_after_wait` shows that.
