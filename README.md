<img width="625" height="329" alt="Transcripted meeting and dictation capture on macOS" src="https://github.com/user-attachments/assets/86453a3e-9eee-4525-b985-777366296cf5" />

# Transcripted

Audio context for your agent.

Transcripted is a local Mac app that turns meetings, dictation, and audio files
into clean Markdown on your Mac. Point Claude, Codex, Cursor, Obsidian, or any
file-reading agent at the folder and ask it what happened, what matters, and
what you should do next.

[Download the latest release](https://github.com/r3dbars/transcripted/releases/latest)
· [Visit transcripted.app](https://transcripted.app)

## Why This Exists

A lot of your best context is spoken.

It happens in meetings, calls, quick thoughts, voice notes, and half-formed
ideas you say out loud before they ever become writing.

Most of that context disappears.

Transcripted saves it as plain local Markdown so your agent and second brain can
use it later.

Ask things like:

- What did I promise to follow up on this week?
- What did we decide in the pricing call?
- Find every time we talked about onboarding.
- Turn my last three dictations into a plan.
- Pull the strongest product ideas from my recent meetings.
- What am I repeating across conversations?

## What It Does

- Records meetings from your Mac
- Captures quick dictation and pastes it back where you were typing
- Imports audio files you already have
- Saves readable Markdown files on disk
- Keeps audio and transcripts local by default
- Gives your agent a folder of real spoken context

## The Outcome

You get a local memory layer for spoken work.

Not another trapped notes database.
Not a meeting bot joining your calls.
Not a black box.

Just files your tools can read.

Use Transcripted with:

- Obsidian as a second brain
- Claude or Claude Code for meeting recall
- Codex for project context
- Cursor for engineering and product memory
- Any agent that can read local files

## Local Markdown

Transcripted saves normal Markdown files.

Meeting example:

```md
# Product Review

Recorded Apr 10 at 3:01 PM  -  32:14  -  4,230 words

## Transcript

**00:00** [Sarah]
Keep annual pricing manual for now.

**00:04** [Michael]
Onboarding friction is still the blocker.
```

Dictation example:

```md
# Dictations for April 10, 2026

## 9:15 AM

Need to test the onboarding changes before touching pricing.
```

You can open these files yourself, search them, sync them, back them up, or hand
them to an agent.

## Agent Setup

The simplest path:

1. Open Transcripted.
2. Record a meeting, capture a dictation, or import audio.
3. Point your agent at the Transcripted capture folder.
4. Ask questions across your spoken context.

Default folders:

```text
~/Library/Application Support/Transcripted/captures/meetings/
~/Library/Application Support/Transcripted/captures/dictations/
```

Transcripted also includes an optional read-only MCP server for agents that
support MCP. It gives tools for recent context, search, recaps, meeting reads,
dictation reads, and speaker lookup.

For Claude Desktop, open Transcripted Settings, go to `Agent`, then click
`Install for Claude Desktop`. Transcripted installs the local server, writes the
Claude Desktop config, checks your local library, and tells you when to restart
Claude Desktop.

See [docs/agent-connect.md](docs/agent-connect.md).

## Features

- Local meeting recording with mic and system audio
- Dictation with paste-back
- Audio file import
- Speaker labels and speaker review
- Custom dictionary for names, acronyms, and uncommon words
- Local transcription models, with Parakeet as the default and Whisper as an advanced option
- Auto Enter for selected apps after dictation
- Launch at login
- Local Markdown capture library
- Optional MCP access for agents

## Privacy

Transcripted is local-first.

- Audio stays on your Mac
- Markdown files stay on your Mac
- Transcripted records from your Mac and does not join meetings as a bot
- You choose what folders your agents can read
- App state, logs, and temporary files stay under Transcripted Application Support

For the full storage map, see [docs/storage-paths.md](docs/storage-paths.md).

## Install

Download the latest `.dmg`:

[github.com/r3dbars/transcripted/releases/latest](https://github.com/r3dbars/transcripted/releases/latest)

Requirements:

- macOS 26+
- Apple Silicon Mac recommended

### Homebrew

```bash
brew tap r3dbars/transcripted https://github.com/r3dbars/transcripted
brew install --cask transcripted
```

To update:

```bash
brew upgrade --cask transcripted
```

Transcripted also supports in-app updates through Sparkle.

## Build From Source

```bash
bash build-deps.sh
bash build.sh
```

`build.sh` is the main app build. `Package.swift` exists for
`TranscriptedCore` tests and smoke coverage.

## Run Tests

```bash
bash run-tests.sh
```

If you touch meeting capture or `TranscriptedCore`, also run:

```bash
bash run-integration-smoke.sh
swift test
```

More details:

- [CONTRIBUTING.md](CONTRIBUTING.md)
- [docs/repo-layout.md](docs/repo-layout.md)
- [SECURITY.md](SECURITY.md)

## License

MIT
