# Transcripted

> Every meeting on your Mac, transcribed locally. No cloud. No subscription. No data leaves your machine.

## The Problem

You left a meeting ten minutes ago. The key decision — the one that changes the project timeline — is already blurring. You wrote nothing down.

Cloud transcription services like Otter.ai will happily solve this for $16.99/month. The trade-off: your raw audio streams through someone else's servers. Every salary discussion, every legal call, every private conversation — stored on infrastructure you don't control.

Apple's built-in dictation is free, but it can't tell speakers apart. A transcript that reads as one continuous monologue isn't a transcript. It's a wall of text.

Your meetings contain salary numbers, strategic plans, and candid feedback. That data deserves better than a Terms of Service promise.

## What Transcripted Does

Transcripted runs two NVIDIA AI models directly on your Mac's Neural Engine. **Parakeet TDT V3** converts speech to text. **Sortformer** identifies who said what. Both run locally — no internet connection required.

The result: timestamped, speaker-labeled Markdown transcripts saved to your Mac. No API keys. No subscription. No cloud.

<!-- TODO: Add demo GIF or screenshot -->

## How It Compares

| Feature | Transcripted | Otter.ai | Krisp | Apple Dictation |
|---------|-------------|----------|-------|-----------------|
| Runs 100% locally | ✅ | ❌ | ❌ | Partial |
| Speaker identification | ✅ | ✅ | ✅ | ❌ |
| Cost | Free | $16.99/mo | $8/mo | Free |
| Data stays on your Mac | ✅ | ❌ | ❌ | Partial |
| System audio capture | ✅ | ❌ | ✅ | ❌ |
| Voice fingerprinting | ✅ | ❌ | ❌ | ❌ |
| Open source | ✅ | ❌ | ❌ | ❌ |

## Features

**Recording**
- **Floating pill UI** — Dynamic Island-style interface that stays out of your way
- **Dual audio capture** — microphone + system audio (Zoom, Meet, Teams)
- **Auto-meeting detection** — starts recording when it hears bidirectional audio
- **Global hotkey** — start and stop from anywhere

**Transcription**
- **Parakeet TDT V3** — NVIDIA's speech-to-text running on Neural Engine (~600MB)
- **Sortformer** — speaker diarization that identifies who said what, and when
- **Qwen speaker naming** — on-device LLM infers speaker names from conversation context
- **Voice fingerprints** — learns voices over time via 256-dimensional embeddings stored in SQLite

**Output**
- Markdown transcripts with YAML frontmatter (date, duration, word count)
- `[MM:SS]` timestamps throughout
- Auto-save to `~/Documents/Transcripted/`
- Export to Markdown or plain text

## Quick Start

### Requirements

- macOS 14.2+ (Sonoma)
- ~2GB disk space for AI models
- Xcode 15+ (for building from source)

### Install

```bash
git clone https://github.com/r3dbars/transcripted.git
cd transcripted
open Transcripted.xcodeproj
# Set your Development Team in Signing & Capabilities, then Build & Run (⌘R)
```

### Permissions

| Permission | Why | Required |
|------------|-----|----------|
| Microphone | Capture your voice | Yes |
| Screen Recording | Capture system audio from meetings | For system audio |

Models download automatically from HuggingFace on first launch.

## Architecture

<details>
<summary>Project structure</summary>

```
Transcripted/
├── Core/                    # Audio capture, transcription pipeline, data persistence
├── Services/                # ML models (Parakeet, Sortformer, Qwen), speaker database
├── UI/
│   ├── FloatingPanel/       # Floating pill UI + components
│   └── Settings/            # Settings window
├── Design/                  # Design tokens, shared components
├── Onboarding/              # First-run experience
└── TranscriptedApp.swift    # App entry point
```

See [CONTRIBUTING.md](CONTRIBUTING.md) for architecture details.

</details>

## Privacy

- **All processing happens on your Mac.** No cloud. No API keys. No analytics.
- **Audio recordings are deleted** after successful transcription.
- **Transcripts are saved locally.** Nothing leaves your machine.

See [SECURITY.md](SECURITY.md) for full details.

## Contributing

Contributions are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) for setup instructions, architecture overview, and guidelines.

## License

MIT — see [LICENSE](LICENSE).

---

**Transcripted** — Your meetings, transcribed locally.
