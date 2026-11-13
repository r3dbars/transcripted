# TranscriptedLive

Experiment: the meeting Transcripted is recording, live inside Claude Code. A standalone Swift helper (`transcripted-live`) plus a Claude Code mod. Neither changes the app's behavior. Install and usage are in `Tools/TranscriptedLive/README.md`; this file is the rules.

## What's here

- `Sources/TranscriptedLiveCore/` is the library. `RecordingLocator.swift` finds a live meeting by the app's `*.recording.json` journal; `WAVTail.swift` reads the growing mic and system WAVs; `StreamTranscriber.swift` runs FluidAudio's streaming EOU model; `EchoFilter.swift` drops mic lines that repeat the call; `LiveOutput.swift` writes `session.json` and a JSONL per meeting; `LiveRunner.swift` drives `watch` and `replay`.
- `Sources/TranscriptedLive/main.swift` is the CLI: `watch` and `replay`.
- `claude-mod/` is the plugin: `hooks/register.tsx` (state, `/meeting`, helper supervisor, Haiku notes, `read_live`), `hooks/ui.tsx` (pane and status line), `.mcp.json` (bundles the app's `transcripted-mcp`), `tests/`.
- `live.sh` starts the helper, then Claude Code with the mod loaded. `.claude-plugin/marketplace.json` at the repo root points at `claude-mod/`.

## Invariants

- **Read-only on the app's data.** The helper only reads the recording journal and WAVs. It writes only under `TranscriptedLive/` in Application Support (`TRANSCRIPTED_LIVE_DIR` overrides), never into the app's own folder. Keep it that way.
- **Standalone package.** It pulls FluidAudio from SwiftPM at an exact version and never links the app or `Sources/TranscriptedCore/`. That version must equal `FLUID_AUDIO_VERSION` in `scripts/entrypoints/build-deps.sh` (`scripts/dev/check-known-traps.py` enforces it). Bump both together.
- **One helper at a time.** The helper refuses a second copy (both would write the same `session.json`). The mod relies on this: several sessions share one helper.
- **Heartbeat contract.** An idle helper rewrites `session.json` about every 4 s (`LiveOutput.heartbeatSeconds`). The mod's `STALE_MS`, `HELPER_ALIVE_MS` and restart timers in `register.tsx` must stay well above that. Change one side, check the other.
- **Idle means models released.** Watch mode holds the two transcribers only while a meeting is live and reloads them (about 0.15 s) when one starts. `TRANSCRIPTED_LIVE_EXIT_WITH_PARENT=1` makes the helper exit when its parent goes away while no meeting is live.
- **Live text is rough and provisional.** Speakers are only "you" (mic) and "them" (system audio). The saved transcript still comes from the app's normal post-meeting pipeline; never present live text as final.
- **Transcript text goes to Claude** through the mod's hidden context and Haiku notes, same as pasting it. Both have off switches (`/meeting auto off`, `/meeting helper off`); keep them working.
- **The mod must not control the meeting.** Model-issued `start_meeting`, `stop_meeting` and `set_live_context_sharing` calls are denied (`PERSON_ONLY_TOOLS` in `register.tsx`). The intentional exception is person-confirmed Stop: after the person presses Stop twice, `stopRecording` sets `personStopFor` to the current session and permits that session's `stop_meeting`. Preserve the denial and this explicit person-initiated exception.
- **Mods are early access.** `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1` loads them and the API changes between Claude Code releases. `claude-mod/.claude/` (type declarations from `/plugin-types`) is generated and git-ignored.

## Ship path

`scripts/entrypoints/build.sh` builds the helper and bundles it at `Contents/Helpers/transcripted-live`; the mod starts that copy, so a helper change reaches users only with an app release. The mod itself ships through the marketplace.

## Test

```bash
swift test --package-path Tools/TranscriptedLive
python3 scripts/dev/test-live-claude-mod.py
```

**SDK execution is currently BLOCKED.** The integrity-pinned Claude Code 2.1.310 binary traps during Bun startup inside the proposed isolated host, before plugin validation; actual mod tests were **not run**. The canonical wrapper exits `3` without preparing a workspace, downloading a tool or launching an SDK. Do not remove this source gate or infer a pass from the wrapper-contract tests. Distinct genuine hosted-account proof remains pending.

The proposed host copies the mod/native CLI into an owned temporary root, enables function hooks, and confines them with a default-deny macOS sandbox. Its provider tests answer filesystem, process, model and MCP calls in memory; unanswered dispatch throws. The host/profile/SRI proposal is retained for review, not certified runnable SDK coverage. Swift CI and Linux checks run only `python3 scripts/dev/test-live-claude-mod-tests.py`: mocked wrapper contracts plus an owned C sandbox witness on macOS. `.agents/test-matrix.yml` also selects the canonical SDK wrapper for `Tools/TranscriptedLive/**` and the wrapper's own files (not for workflow edits), and `scripts/dev/agent-check.py` lists it in `MANUAL_COMMAND_FRAGMENTS`, so `bash check.sh` reports it BLOCKED (manual-proof-required) without running it. That keeps the SDK proof unknown, never green and never a false FAIL. No live Claude account/model, app integration or recording-control proof is claimed. To type-check the mod, see "Checks" in the README. For a manual run without a real call, use `Tools/TranscriptedLive/live.sh replay <audio>`; first run downloads the EOU model (about 440 MB).
