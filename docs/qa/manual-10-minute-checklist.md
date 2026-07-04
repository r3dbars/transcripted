# Transcripted 10-Minute Manual QA Checklist

Use this after building and launching the local app. Keep the notes synthetic
and privacy-safe. Do not paste private transcript text, meeting titles, speaker
names, file paths, device names, emails, tokens, or raw URLs into a report.

This is manual proof. Only mark a row passed when you actually observe it.
Bluetooth/AirPods, real meeting apps, permission prompts, pasteback feel, and
Sparkle install/update behavior are not proven by the automated bench.

## Setup

```bash
git fetch origin main --prune
git switch main
git pull --ff-only
bash build.sh --no-open
open build/Transcripted.app
```

Use a simple test phrase:

```text
Transcripted manual QA test one two three.
```

## Script

| Time | Area | Steps | Pass bar |
| --- | --- | --- | --- |
| 0:00-1:00 | Launch and permissions | Launch `build/Transcripted.app`. Open the menu bar app and check Home, Settings, and permission status. | App opens. No duplicate stale instance. Permissions are clear, or the missing permission is named. |
| 1:00-2:30 | Dictation start/stop | Put focus in TextEdit or Notes. Start dictation, speak the test phrase, stop. Repeat once through the configured hotkey or trigger if available. | Overlay starts and stops. Text is pasted, or copied with a clear reason. No stuck hotkey or stuck listening UI. |
| 2:30-3:30 | Pasteback fallback | Try one focused app that is not TextEdit, such as a browser textarea or Obsidian. Then try a secure/password field if safe. | Normal fields receive text. Secure/blocked fields do not lose text and show copy/fallback behavior. |
| 3:30-5:00 | Meeting prompt choices | Start or join a harmless meeting surface if available, or trigger the normal Start Meeting flow from the menu. If a detected-meeting prompt appears, try `Record` on one run and `Not now` or dismiss on another. | Prompt choices are clear. Dismiss does not start recording. Record starts the expected meeting UI. |
| 5:00-6:30 | Meeting record/save Markdown | Record 20-30 seconds with mic and system audio if available. Stop and wait for save/transcription state. | App returns to idle. Saved meeting Markdown appears in Home or the capture folder. Retained audio is present when expected. |
| 6:30-7:30 | Import audio | Use Settings or the menu import action with a small synthetic audio file. | Native picker works. Imported meeting reaches saved Markdown, or the blocker is named. |
| 7:30-8:30 | Settings toggles | Check Privacy toggles for crash reporting and anonymous analytics. Check General storage/model/update-related controls without changing real user settings unless intended. | Toggles are visible and understandable. No private data appears in diagnostics or reports. |
| 8:30-9:15 | Update UI | Run Check for Updates from the app UI. Do not publish, edit appcast, or install an update unless this is explicitly a release test. | The update UI gives a clear result. Existing-install upgrade is still separate unless actually completed. |
| 9:15-10:00 | Hardware route, if available | With AirPods/Bluetooth or another route connected, do one short dictation and one short meeting start/stop. | Route settles or fails clearly. Do not mark hardware proof if no device was connected and observed. |

## Result

Use this compact result line:

```text
Manual QA: PASS/PARTIAL/FAIL | app path | scenarios passed | blockers | hardware observed | saved Markdown path or not proven
```

If anything fails, keep the local notes and run the matching focused command
next:

```bash
bash run-daily-audio-reliability.sh --skip-build
bash scripts/ops/transcripted-qa-bench.sh --mode ui
bash scripts/ops/transcripted-qa-bench.sh --mode imported-audio-native
bash scripts/ops/transcripted-qa-bench.sh --mode sparkle-update
```
