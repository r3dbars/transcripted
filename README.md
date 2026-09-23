![Transcripted — meeting and dictation capture on macOS](docs/assets/transcripted-github-banner.png)

# Transcripted

[![Latest release](https://img.shields.io/github/v/release/r3dbars/transcripted?label=release&color=ee7b35)](https://github.com/r3dbars/transcripted/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/r3dbars/transcripted/total?label=downloads&color=ee7b35)](https://github.com/r3dbars/transcripted/releases)
[![macOS 26+ on Apple Silicon](https://img.shields.io/badge/macOS_26%2B-Apple_Silicon-1d1d1f?logo=apple&logoColor=white)](#install)
[![MIT license](https://img.shields.io/badge/license-MIT-3da639)](LICENSE)
[![100% local transcription](https://img.shields.io/badge/transcription-100%25_local-3da639)](#privacy)

**Turn your meetings and voice notes into text files your AI can read.**

Transcripted is a Mac app. It writes down what's said and saves it as a
plain text file on your Mac. Then you can ask Claude, or any AI, things like
*"what did I agree to this week?"*

**Free · Open source · Transcribes on your Mac · No bot joins your calls**

[**Download for macOS**](https://transcripted.app/download/) ·
[Try the demo](https://transcripted.app/#demo) ·
[transcripted.app](https://transcripted.app)

![Transcripted in 18 seconds: a meeting becomes a file you own, your AI answers from it, and dictation lands where you were typing](docs/assets/launch/transcripted-hero.gif)

## What it does

- **Records meetings.** Zoom, Meet, Teams, FaceTime, or a chat in the room.
  If your Mac can hear it, it works.
- **Types what you say.** Press a hotkey, talk, and the words show up where
  you were typing.
- **Transcribes files.** Drop in an audio or video file you already have.

Each one becomes a text file with timestamps and speaker names.

## Ask your AI

Point Claude, Codex, Cursor, or Obsidian at the folder. That's it.

```text
You:    What did I commit to in the product review?

Claude: From Product Review Sync (May 13):
        • Decide follow-ups from the launch feedback
        • Keep it a clean transcript, no meeting bot
        • Post a short summary before next standup
```

Using Claude Desktop? Open **Settings → Agent → Install in Claude** to give it
search tools for your meetings. It can read your notes, but never change or
delete them. More: [docs/agent-connect.md](docs/agent-connect.md).

## See it

<table>
  <tr>
    <td width="50%">
      <img src="docs/screenshots/launch/transcripted-home.png" alt="Transcripted Home window with one-click meeting recording and today's captures">
      <p align="center">Record or dictate in one click.</p>
    </td>
    <td width="50%">
      <img src="docs/screenshots/launch/transcripted-meeting-preview.png" alt="A finished meeting as a timestamped, speaker-labeled transcript with Open Markdown and Copy for agent actions">
      <p align="center">Every meeting becomes a transcript.</p>
    </td>
  </tr>
  <tr>
    <td width="50%">
      <img src="docs/screenshots/launch/transcripted-agent.png" alt="One-click Install in Claude from Transcripted's Agent settings">
      <p align="center">Connect Claude in one click.</p>
    </td>
    <td width="50%">
      <img src="docs/screenshots/launch/transcripted-people-speaker-review.png" alt="People view with speaker review and voice-match suggestions">
      <p align="center">Name a voice once. It remembers.</p>
    </td>
  </tr>
</table>

![Dictation in progress: the floating Listening control with a live waveform and a Stop button](docs/assets/launch/transcripted-dictation-recording.gif)

## What a file looks like

```md
# Product Review

Recorded Apr 10 at 3:01 PM  -  32:14  -  4,230 words

## Transcript

**00:00** [Sarah]
Keep annual pricing manual for now.

**00:04** [Michael]
Onboarding friction is still the blocker.
```

Files are saved here by default. You can pick any folder in Settings.

```text
~/Library/Application Support/Transcripted/captures/
```

## Install

You need an Apple Silicon Mac on macOS 26 or later.

[**Download the app**](https://transcripted.app/download/). It's signed and
updates itself.

Or use Homebrew:

```bash
brew tap r3dbars/transcripted https://github.com/r3dbars/transcripted
brew install --cask transcripted
```

## Privacy

- Your audio and transcripts never leave your Mac.
- No bot joins your calls.
- The app sends anonymous crash reports and usage stats. They never include
  audio, transcripts, names, or file paths. You can turn both off in
  **Settings → Privacy**.

Where everything is stored: [docs/storage-paths.md](docs/storage-paths.md).

## FAQ

**How accurate is it?**
Good enough to search and quote. It uses Parakeet V3 by default, which handles
many languages. You can switch models in **Settings → Model**, and add a
custom dictionary so names and jargon come out right.

**What does it cost?**
Nothing. No account, no subscription.

**Is there a command-line tool?**
Yes. See the [CLI instructions](Tools/TranscriptedCLI/README.md).

## For contributors

It's a native Swift app. Build and test:

```bash
bash build-deps.sh
bash build.sh --no-open
bash run-tests.sh
```

Start with [AGENT_START.md](AGENT_START.md) and
[CONTRIBUTING.md](CONTRIBUTING.md). Security reports:
[SECURITY.md](SECURITY.md).

If you find it useful, a star helps. You can also
[sponsor the project](https://github.com/sponsors/r3dbars).

## License

MIT. See [LICENSE](LICENSE). Bundled third-party code is listed in
[THIRD_PARTY_LICENSES.md](THIRD_PARTY_LICENSES.md).
