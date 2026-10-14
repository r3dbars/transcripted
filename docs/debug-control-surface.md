# Debug control surface

A local, debug-only hook so an agent or script can drive a `build.sh` Transcripted without clicking: start/stop dictation and meetings, import audio, open screens, change allowlisted settings, and read app state as JSON.

- App parser (every build, inert alone): `Sources/App/DebugControlCommand.swift`
- App runtime (`build.sh` only): `Sources/App/DebugControlChannel.swift`
- Launch hook: `#if TRANSCRIPTED_DEBUG_CONTROL` in `Sources/App/TranscriptedApp.swift`
- Client: `scripts/dev/transcripted-debug.py`
- Release proof: `scripts/dev/check-debug-control-release.py` and the binary grep in `scripts/entrypoints/build-beta.sh`

This is not the hill-climb lab channel (`docs/lab-control-channel.md`). That one needs `build.sh --lab`. This one is in every local `build.sh` and still stays off unless the automated harness is active.

## Safety

- **Debug builds only.** `build.sh` always passes `-D TRANSCRIPTED_DEBUG_CONTROL`. `build-beta.sh` never does, refuses if that flag is set, and fails if the compiled binary contains `TRANSCRIPTED_DEBUG_CONTROL_DIR`. The repo `Info.plist` does not register the URL scheme; only the copied debug plist does.
- **Off unless both are true:** `AutomatedLaunchEnvironment` is active (`TRANSCRIPTED_AUTOMATED_HARNESS=1`, or one of the existing launch-smoke keys) **and** `TRANSCRIPTED_DEBUG_CONTROL_DIR` is an absolute path. A `launchctl setenv` of the control dir alone is not enough.
- Control dir / `inbox/` / `done/` must be real directories this uid owns, mode `0700`. Command files are opened `O_NOFOLLOW`. Same accept rules as the lab channel (`LabControlFilePolicy`).
- No network. Responses never echo transcript text, titles, speaker names, emails, tokens, or file paths.
- `launch` requires `--container DIR` (or `--use-real-library`) and refuses when `transcriptSaveLocation` is relocated, because `UserDefaults` are not isolated by `HOME` / the container.
- `settings_get` reads what this process sees (`UserDefaults.standard`, including launch-arg overrides). `settings_set` writes the **argument domain only** (volatile, not persisted) and posts the same in-process notifications the real setters post. It never calls `UserDefaults.standard.set`, so `crash_reports`, `usage_stats`, and `island_in_screen_sharing` cannot leak into the owner's `com.justinbetker.draft` plist.

## Talk to a running debug app

```bash
python3 scripts/dev/transcripted-debug.py launch \
  --app build/Transcripted.app --dir DIR --container DIR
python3 scripts/dev/transcripted-debug.py state --dir DIR
python3 scripts/dev/transcripted-debug.py dictation start --dir DIR
python3 scripts/dev/transcripted-debug.py dictation stop --dir DIR
# optional paste into the frontmost app:
python3 scripts/dev/transcripted-debug.py dictation stop --dir DIR --paste
```

Drop a JSON file in `$TRANSCRIPTED_DEBUG_CONTROL_DIR/inbox/` (write `*.json.tmp`, then rename). The app moves it to `done/`, appends one line to `responses.jsonl`, and rewrites `last.json`.

```json
{"id": "a1b2c3", "command": "start_dictation", "args": {}}
```

`id` is 1–128 chars of `[A-Za-z0-9._:-]`. Unknown commands, bad args, and files over 64 KB get `ok: false` and still move to `done/`.

URL scheme (debug Info.plist only; still needs the harness + control dir so the response can be written):

```
transcripted-debug://state
transcripted-debug://dictation/start
transcripted-debug://dictation/stop?paste=true
transcripted-debug://meeting/start
transcripted-debug://meeting/stop
transcripted-debug://import?path=/tmp/x.wav
transcripted-debug://paste-target/open
transcripted-debug://open?screen=today
transcripted-debug://settings/get?key=show_in_dock
transcripted-debug://settings/set?key=show_in_dock&value=false
```

## Commands

| command | CLI | args | ok means | errors |
|---|---|---|---|---|
| `ping` | `ping` | none | channel is up; `result.pid` | none |
| `state` | `state` / `status` | none | snapshot in `result` | none |
| `start_dictation` | `dictation start` | none | a dictation session began; `result` is the snapshot after the settle wait | `dictation_already_active`, `dictation_not_started` |
| `stop_dictation` | `dictation stop` | `paste`: bool, default `false` | stop was requested; `result` is the snapshot after the settle wait | `dictation_not_active`, `invalid_arg:paste` |
| `start_meeting` | `meeting start` | none | capture is recording | `meeting_capture_active`, `meeting_not_started` |
| `stop_meeting` | `meeting stop` | none | capture stopped and transcription was queued | `meeting_not_recording` |
| `import_audio` | `import /abs/path` | `path`: absolute file | import was queued | `meeting_capture_active`, `file_not_found`, `import_not_started`, `missing_arg:path`, `invalid_arg:path` |
| `paste_target_open` | `paste-target open` | none | debug text field is on screen | none |
| `open_screen` | `open today` | `screen` | that screen was asked to open | `missing_arg:screen`, `invalid_arg:screen` |
| `settings_get` | `settings get show_in_dock` | `key` | `result.<key>` is `"true"` / `"false"` | `missing_arg:key`, `unknown_setting` |
| `settings_set` | `settings set show_in_dock false` | `key`, `value` | the allowlisted bool is visible to this process only (argument domain; not persisted) | `missing_arg:key`, `missing_arg:value`, `invalid_arg:value`, `unknown_setting` |

`start_dictation` / `stop_dictation` / meeting start and stop call the same session APIs as the menu bar (minus bringing another app forward on dictation start). `stop_dictation` only pastes when `paste` is true.

`--dir`, `--timeout`, and `--paste` are accepted before or after the subcommand (`dictation start --dir DIR` or `--dir DIR dictation start`).

### Dictation start/stop settle

`startDictation` returns as soon as `isDictating` is true, while the mic/STT graph is still coming up — an immediate snapshot shows `stt_recording: false`. `stopDictationAndPaste` returns before `isDictating` flips — an immediate snapshot still shows `dictation_active: true`.

The channel waits up to 2 seconds (20 ms polls) for:

- start: `dictation_active && stt_recording`
- stop: `!dictation_active`

Then it writes `result` from the latest snapshot. A timeout is still `ok: true` if the session command itself succeeded — check the flags in `result`, not only `ok`. Meeting start/stop already await the session APIs, so they do not use this wait.

Every command can also fail with `harness_inactive`, `control_dir_required`, `malformed_json`, `not_an_object`, `payload_too_large`, `not_a_regular_file`, `wrong_owner`, `unreadable_file`, `missing_id`, `invalid_id`, `missing_command`, `invalid_command`, `unknown_command`, `invalid_args`, `unknown_arg[:name]`, `unknown_scheme`, `malformed_url`, or `app_unavailable`.

### Screens

`today`, `home`, `dictations`, `writing`, `general`, `people`, `connect_agent`, `onboarding`, `menubar`. Settings page ids match `TranscriptedSettingsPage.analyticsValue`.

### Settings allowlist (bools only)

`show_in_dock`, `auto_detect_calls`, `dictation_sounds`, `cleanup_pasted_text`, `crash_reports`, `usage_stats`, `people_in_room`, `island_in_screen_sharing`.

Paths, names, and `transcriptSaveLocation` are not writable through this surface.

## State JSON (`schema_version` 1)

Successful `state` (and the mutating commands) put this object in `result`. `ping` only returns `pid`.

```json
{
  "schema_version": 1,
  "ok": true,
  "id": "a1b2c3",
  "command": "state",
  "at": "2026-10-10T12:00:00.000Z",
  "result": {
    "schema_version": 1,
    "pid": 12345,
    "harness_active": true,
    "dictation_active": false,
    "stt_recording": false,
    "stt_transcribing": false,
    "stt_model_loaded": true,
    "meeting_state": "ready",
    "meeting_capture_active": false,
    "open_screen": "none",
    "paste_target_open": false,
    "settings": {
      "show_in_dock": true,
      "auto_detect_calls": true,
      "dictation_sounds": true,
      "cleanup_pasted_text": true,
      "crash_reports": true,
      "usage_stats": true,
      "people_in_room": false,
      "island_in_screen_sharing": false
    },
    "automation_ids": {
      "status_item": "transcripted.status-item.button",
      "start_meeting": "transcripted.menubar.primary.start-meeting",
      "start_dictation": "transcripted.menubar.primary.start-dictation",
      "open_transcripted": "transcripted.menubar.utility.open-transcripted",
      "check_updates": "transcripted.menubar.utility.check-updates",
      "quit": "transcripted.menubar.utility.quit",
      "paste_target_field": "transcripted.debug.paste-target.field"
    }
  }
}
```

`meeting_state` uses the same names as the lab channel: `idle`, `loading_models`, `ready`, `starting_recording`, `recording`, `stopping_recording`, `transcribing`, `error`. `open_screen` is `onboarding`, `menubar`, a settings page id, or `none`.

The paste-target field is a debug-only `NSPanel` excluded from screen sharing. Click a row's time in a saved meeting still plays from there; this surface does not change that.

## Mac proof (debug build, no clicking)

From a clean checkout on an Apple Silicon Mac. Uses a throwaway container so it does not touch the real capture library.

```bash
bash build.sh --no-open
CTRL="$(mktemp -d /tmp/transcripted-debug-XXXX)"
CONTAINER="$(mktemp -d /tmp/transcripted-container-XXXX)"
chmod 700 "$CTRL" "$CONTAINER"

python3 scripts/dev/transcripted-debug.py launch \
  --app build/Transcripted.app --dir "$CTRL" --container "$CONTAINER"
# ping in the launch report should be ok: true

python3 scripts/dev/transcripted-debug.py state --dir "$CTRL"
# result.schema_version == 1, result.dictation_active == false

python3 scripts/dev/transcripted-debug.py dictation start --dir "$CTRL"
# that response's result.dictation_active == true and result.stt_recording == true
# (waits up to 2 seconds; if STT never starts, ok is still true and stt_recording may stay false)

python3 scripts/dev/transcripted-debug.py dictation stop --dir "$CTRL"
# that response's result.dictation_active == false
```

Quit the debug app when finished. A release/beta binary must not contain `TRANSCRIPTED_DEBUG_CONTROL_DIR`; `bash build-beta.sh` fails if it does.

Offline checks that do not need the app:

```bash
python3 scripts/dev/check-debug-control-release.py
python3 scripts/dev/transcripted-debug.py --self-test
bash run-tests.sh --filter DebugControlCommand
bash run-e2e-smoke.sh
```
