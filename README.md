![Transcripted meeting and dictation capture on macOS](docs/assets/transcripted-github-banner.png)

# Transcripted

Turn spoken work into local memory for your agents.

Transcripted is a local Mac app for meetings, dictation, and audio files. It
turns the things you say out loud into clean Markdown files on your Mac, so
Claude, Codex, Cursor, Obsidian, or any file-reading agent can understand what
happened and help you use it later.

[Download for macOS](https://github.com/r3dbars/transcripted/releases/latest)
· [Visit transcripted.app](https://transcripted.app)

## Why Audio Context Matters

Your agents can only help with the context they can see.

A lot of your most useful context is spoken. It happens in meetings, calls,
quick dictations, voice notes, and half-formed ideas you say before they become
writing.

Most of that context disappears.

Transcripted makes spoken work readable. It saves it as local Markdown, in
folders your tools can search, quote, summarize, and reason over.

Before Transcripted:

- A meeting ends and the useful details fade
- A good spoken idea never makes it into your notes
- Your agent has to guess because it cannot see the conversation

After Transcripted:

- Your meetings become searchable files
- Your dictations become a running memory of what you were thinking
- Your agent can answer from the things you actually said

## What Transcripted Does

Transcripted captures spoken context and turns it into files you own.

- Record meetings from your Mac
- Capture quick dictation and paste it back where you were typing
- Import audio files you already have
- Save readable Markdown files on disk
- Give your agents a folder of real spoken context
- Keep audio and transcripts local by default

That is the whole idea: your spoken work stops being throwaway audio and becomes
useful memory.

## What You Can Ask

Transcripted is for the moments where you need to remember, decide, and follow
through.

Ask your agent things like:

- What did I promise to follow up on this week?
- What did we decide in the pricing call?
- Find every time we talked about onboarding.
- What am I repeating across conversations?

The point is not just transcription. The point is that your tools can finally
use the spoken context that used to vanish.

## What You Get

You get a local memory layer for spoken work.

Not a meeting bot joining your calls.
Not a closed notes database.
Not another place where your context gets trapped.

Just local files your tools can read.

Use Transcripted with the tools people already reach for:

- Claude for meeting recall and everyday questions
- Codex for project context and repo work
- Obsidian as your second brain
- Any agent that can read local Markdown files or connect to MCP

## How It Works

1. Capture a meeting, dictate a thought, or import an audio file.
2. Transcripted transcribes it locally.
3. Transcripted saves the result as Markdown on your Mac.
4. You point your agent or notes app at the folder.
5. You ask questions across your spoken context.

Default folders:

```text
~/Library/Application Support/Transcripted/captures/meetings/
~/Library/Application Support/Transcripted/captures/dictations/
```

You can also choose a different capture library in Settings.

## Plain Local Markdown

Transcripted saves normal Markdown files. You can open them yourself, search
them, sync them, back them up, or hand them to an agent.

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

The files are plain enough for you to read and structured enough for agents to
use.

## Connect Your Agent

You can use Transcripted two ways:

- Point your agent at the capture folder
- Install the optional read-only MCP server for richer tools

The MCP server gives supported agents tools for recent context, search, recaps,
meeting reads, dictation reads, and speaker lookup.

For Claude Desktop, open Transcripted Settings, go to `Agent`, then click
`Install for Claude Desktop`. Transcripted installs the local server, writes the
Claude Desktop config, checks your local library, and tells you when to restart
Claude Desktop.

See [docs/agent-connect.md](docs/agent-connect.md).

## Feature List

Capture spoken work:

- Local meeting recording with mic and system audio
- Dictation with paste-back
- Audio file import

Make it readable:

- Local transcription models, with Parakeet as the default and Whisper as an advanced option
- Speaker labels and speaker review
- Custom dictionary for names, acronyms, and uncommon words
- Local Markdown capture library

Connect it to your workflow:

- One-click Claude Desktop direct tools
- Auto Enter for selected apps after dictation
- Launch at login

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

For contributors:

```bash
bash build-deps.sh
bash build.sh
```

`build.sh` is the main app build. `Package.swift` exists for
`TranscriptedCore` tests and smoke coverage.

## Run Tests

For contributors:

```bash
bash run-tests.sh
```

If you touch meeting capture or `TranscriptedCore`, also run:

```bash
bash run-integration-smoke.sh
```

If you touch `Package.swift`, `Sources/TranscriptedCore/`, or the public core
package seam, also run:

```bash
swift test
```

More details:

- [CONTRIBUTING.md](CONTRIBUTING.md)
- [docs/repo-layout.md](docs/repo-layout.md)
- [SECURITY.md](SECURITY.md)

## License

MIT
