# Deepgram Saga Prep Brief

Call: Ingrid at Deepgram, Wednesday, May 27, 2026, 2:30 PM Central.

Basis: current Transcripted repo plus the Saga beta email thread. Saga claims four relevant betas: meeting recorder, working session memory, style importer, and app-aware formatting.

## What Transcripted Already Does Better

- **Local meeting capture is the clearest wedge.** Transcripted records mic plus system audio from the Mac, uses local transcription, saves Markdown, and does not join calls as a bot.
- **Meeting output is already agent-ready.** The app writes plain Markdown with timestamps, speaker labels, metadata, and retained audio links. Claude Desktop, Codex, and local agents can read it through files, CLI, or the read-only MCP server.
- **Memory is durable and user-owned.** Meetings and dictations live in the capture library, can be moved in Settings, and are searchable through `recent_context`, `search_context`, `recap`, `who_is`, and direct file reads.
- **Meeting reliability is deeper than the beta headline.** Transcripted has permission gates, Calendar and meeting-app prompts, ScreenCaptureKit system-audio capture, silence warnings, retained-audio retry, imported-audio transcription, speaker review, and failed-meeting recovery.
- **Privacy story is stronger.** Transcripted keeps audio, transcripts, app state, logs, and temp files local by default. Off-device observability explicitly excludes transcript text, audio, names, emails, paths, URLs, and meeting titles.

## Where Saga May Be Ahead

- **App-aware dictation polish.** Saga says it reads existing text in the field and formats dictation to flow with it. Transcripted can read focused text fields and paste back, but it does not yet use existing field text to rewrite the dictation.
- **Per-app style controls.** Saga promises casual Slack, polished Gmail, and app-specific cleanup. Transcripted has source-app metadata, custom corrections, filler cleanup, and per-app auto-send, but not per-app style profiles.
- **Style importer.** Saga can connect Slack, Gmail, or Google Docs and learn from prior writing. Transcripted has a manual correction dictionary, not a writing-style importer.
- **Working session memory inside the product.** Transcripted exposes saved meetings and dictations to agents, but Saga may be making "pick up where you left off" a native product moment instead of something the user asks an external agent to do.

## Smart Questions To Ask

1. For meeting recorder, is Saga capturing mic plus system audio locally, joining as a bot, or using another capture path?
2. What does "review your meetings" mean in practice: transcript only, audio playback, speaker labels, summaries, action items, or editable artifacts?
3. For working session memory, what data gets retrieved, how far back does it look, and can the user inspect or delete the memory it used?
4. Does app-aware formatting use existing field text, app identity, user style, or all three? How do they avoid secure fields and private content surprises?
5. For style importer, does learning happen locally or in Deepgram's cloud, and are the learned styles editable as rules the user can understand?
6. Which beta is getting the strongest pull from users: meetings, working session memory, style importer, or app-aware formatting?
7. What are users still asking to export into Claude, Obsidian, docs, or local files after using Saga?

## Product Implications

1. **Add lightweight app-aware dictation before a big style importer.** Transcripted already tracks source app and can read focused text safely. A narrow first version could offer per-app style presets and context-aware casing/punctuation without connecting Gmail or Slack.
2. **Make local memory feel active.** The agent tools already make recent meetings and dictations searchable. The product gap is a visible "resume my last working session" surface that turns that local memory into an obvious next action after a meeting or context switch.
