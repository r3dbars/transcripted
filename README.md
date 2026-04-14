<img width="625" height="329" alt="Screenshot 2026-04-10 at 7 31 17 PM" src="https://github.com/user-attachments/assets/86453a3e-9eee-4525-b985-777366296cf5" />

# Transcripted

Turn meetings and dictation into clean notes.

Transcripted is a local Mac app that records meetings, captures dictation, and
saves clean Markdown files on your Mac. You can read them yourself, or point
your agent at the folder later.

[Download the latest release](https://github.com/r3dbars/transcripted/releases/latest)
· [Visit transcripted.app](https://transcripted.app)

## What You Get

- Clean meeting notes with speaker names
- Dictation notes for your follow-up thoughts
- Plain Markdown files on disk
- Files you can hand to your agent later
- Local-first storage you can inspect yourself

## How To Get Started

1. Download Transcripted from the latest GitHub release.
2. Record a meeting or capture a dictation on your Mac.
3. Open the saved Markdown files yourself, or point your agent at the folder.

## Just Markdown. Not A Black Box.

Transcripted starts with readable Markdown. You do not need to learn a
proprietary format to get value from it.

Meeting example:

```md
# Product Review

## Summary

Keep annual pricing manual for now.
Onboarding friction is still the blocker.

## Transcript

[00:00] Sarah: Keep annual pricing manual for now.
[00:04] Michael: Onboarding friction is still the blocker.
```

Dictation example:

```md
# Dictation
2026-04-07 9:15 AM

Need to test the onboarding changes before touching pricing.
```

The main thing is simple: Transcripted saves readable Markdown files you can
open anywhere.

## Local By Default

- Audio stays on your Mac
- Saved files stay on your Mac
- Transcripted records from your Mac and does not join as a meeting bot
- By default, captures live under `~/Library/Application Support/Transcripted/captures/`

For the full storage map, compatibility paths, and migration details, see
[docs/storage-paths.md](docs/storage-paths.md).

## Works With Your Agent

Point Claude, Codex, Cursor, Obsidian, or any other file-reading tool at your
Transcripted folder.

On supported agents, Transcripted also includes a read-only local MCP server
for search, recap, and direct file access.

## Build From Source

```bash
bash build-deps.sh
bash build.sh
```

`build.sh` is the main app build. `Package.swift` exists for
`TranscriptedCore` tests and smoke coverage, not as the primary app build.

## Run Tests

```bash
bash run-tests.sh
```

If you touch `Sources/Meeting/` or `Sources/TranscriptedCore/`, also run:

```bash
bash run-integration-smoke.sh
```

If you touch `Package.swift` or the public `TranscriptedCore` seam, also run:

```bash
swift test
```

For build and release details, see [scripts/README.md](scripts/README.md) and
[docs/repo-layout.md](docs/repo-layout.md).

## Contributing And Security

- See [CONTRIBUTING.md](CONTRIBUTING.md) for development setup and architecture notes
- See [SECURITY.md](SECURITY.md) for privacy architecture and vulnerability reporting
