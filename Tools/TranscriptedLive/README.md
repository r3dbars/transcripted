# TranscriptedLive (experiment)

The meeting Transcripted is recording, live inside Claude Code.

Two pieces, and neither changes the app:

- `transcripted-live`, a small Swift helper. It finds a live recording by the app's
  `*.recording.json` journal in `~/Library/Application Support/Transcripted/tmp/recordings/`,
  reads the mic and system WAVs as they grow (read-only), and runs FluidAudio's streaming
  Parakeet EOU model on each. The mic is "you", system audio is "them". A mic line that
  mostly repeats what the call just said is dropped as speaker echo. Output goes to
  `~/Library/Application Support/TranscriptedLive/`: `session.json` plus one JSONL per meeting.
- `claude-mod/`, a Claude Code mod (plugin with a function-hooks module):
  - while a meeting is live (or ended in the last 30 minutes), each prompt you send carries
    the lines said since your last prompt as hidden context, so Claude just knows the call
    (`/meeting auto off` stops it)
  - a live helper asks Haiku every 45 s or so (only while recording, only after new lines) for
    questions aimed at you, decisions and action items, and a line you could say
    (`/meeting helper off` stops it)
  - `/meeting` status card, `/meeting catchup | actions | say | notes | attach [N|all]`
  - a `read_live` tool, and the app's `transcripted-mcp` server bundled (`.mcp.json`) for past
    meetings; its `start_meeting`, `stop_meeting` and `set_live_context_sharing` are denied
  - a live pane and status line on surfaces that draw mod UI. The terminal does; the desktop
    Code tab (Claude Code 2.1.284) runs the hooks but draws no mod UI yet.

  The hidden context and the helper send transcript text to Claude, the same as pasting it.

## Try it

```bash
Tools/TranscriptedLive/live.sh
```

That starts the helper, then Claude Code in fullscreen with the mod loaded. Record a
meeting in Transcripted and the pane opens on its own (docked at 110+ columns).

No meeting handy? Replay any audio as a pretend one, in real time:

```bash
Tools/TranscriptedLive/live.sh replay ~/path/to/audio.m4a
Tools/TranscriptedLive/live.sh replay --mic microphone.m4a --system system_audio.m4a
```

In the session:

- `/meeting` shows or hides the pane
- `/meeting attach [N|all]` hands Claude the last N minutes (default 5)
- ask "what did they just say about X?" and Claude can call `read_live` itself

## In the Claude desktop app

The Code tab can't take `--plugin-dir`, so point it at the mod from `~/.claude/settings.json`:

```json
"env": {
  "CLAUDE_CODE_ENABLE_FUNCTION_HOOKS": "1",
  "CLAUDE_CODE_PLUGIN_DIRS": "/path/to/Tools/TranscriptedLive/claude-mod",
  "CLAUDE_CODE_PLUGIN_DIR_WATCH": "1"
}
```

New sessions load it. Run the helper yourself: `.build/release/transcripted-live watch`.

## Notes

- Mods are early access in Claude Code: `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1` loads them,
  and the API can change between releases. `live.sh` sets it.
- First run downloads the EOU model (about 440 MB) to `~/Library/Application Support/FluidAudio`.
- Live text is the rough tier: lowercase, no punctuation. The saved transcript still
  comes from the app's normal post-meeting pipeline.
- Live speakers are only you/them. Names come after the meeting, as today.

## Checks

```bash
swift test --package-path Tools/TranscriptedLive
cd Tools/TranscriptedLive/claude-mod && CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 claude plugin validate . && CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1 claude plugin test .
```

Type-checking the mod needs Claude Code's declarations: run `/plugin-types` in a session
(or copy `mods/types/claude-code.d.ts` from anthropics/claude-code) into
`claude-mod/.claude/types/`, then `npx -p typescript tsc -p claude-mod/tsconfig.json`.
