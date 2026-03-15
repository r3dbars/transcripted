<p align="center">
  <img src="assets/app-icon.png" alt="Transcripted" width="128" height="128">
</p>

<h1 align="center">Transcripted</h1>

<p align="center">
  <strong>Every meeting on your Mac, transcribed locally.<br>No cloud. No subscription. No data leaves your machine.</strong>
</p>

<p align="center">
  <a href="https://github.com/r3dbars/transcripted/releases"><img src="https://img.shields.io/github/v/release/r3dbars/transcripted?style=flat&label=release" alt="GitHub release"></a>
  <a href="https://github.com/r3dbars/transcripted/blob/main/LICENSE"><img src="https://img.shields.io/github/license/r3dbars/transcripted?style=flat" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/macOS-14.2%2B-blue?style=flat&logo=apple&logoColor=white" alt="macOS 14.2+">
  <img src="https://img.shields.io/badge/Swift-5.9-orange?style=flat&logo=swift&logoColor=white" alt="Swift 5.9">
  <a href="https://github.com/r3dbars/transcripted/stargazers"><img src="https://img.shields.io/github/stars/r3dbars/transcripted?style=flat" alt="GitHub stars"></a>
  <a href="https://github.com/r3dbars/transcripted/issues"><img src="https://img.shields.io/github/issues/r3dbars/transcripted?style=flat" alt="GitHub issues"></a>
  <a href="https://github.com/r3dbars/transcripted/pulls"><img src="https://img.shields.io/badge/PRs-welcome-brightgreen?style=flat" alt="PRs Welcome"></a>
</p>

<p align="center">
  <!-- TODO: Replace with actual demo GIF/screenshot -->
  <!-- <img src="assets/demo.gif" alt="Transcripted Demo" width="720"> -->
  <em>Demo GIF coming soon — recording, transcription, and speaker-labeled output in action.</em>
</p>

---

## Why Transcripted?

- **100% Private** — All processing happens on your Mac. Audio never leaves your machine. Ever.
- **Speaker Identification** — Knows who said what using voice fingerprints that improve over time.
- **Zero Cost** — No subscriptions, no API keys, no usage limits. Free and open source.
- **Works With Everything** — Captures audio from Zoom, Google Meet, Teams, FaceTime, and any other app.
- **Set It and Forget It** — Auto-detects meetings and starts recording. You just talk.

---

## The Problem

You left a meeting ten minutes ago. The key decision — the one that changes the project timeline — is already blurring. You wrote nothing down.

Cloud transcription services like Otter.ai will happily solve this for **$16.99/month**. The trade-off: your raw audio streams through someone else's servers. Every salary discussion, every legal call, every private conversation — stored on infrastructure you don't control.

Apple's built-in dictation is free, but it can't tell speakers apart. A transcript that reads as one continuous monologue isn't a transcript — it's a wall of text.

**Your meetings contain salary numbers, strategic plans, and candid feedback.** That data deserves better than a Terms of Service promise.

## What Transcripted Does

Transcripted runs two NVIDIA NeMo models directly on your Mac's Neural Engine:

| Model | Role | Size |
|-------|------|------|
| **Parakeet TDT V3** | Speech-to-text | ~600 MB |
| **Sortformer** | Speaker diarization (who said what) | Bundled |
| **WeSpeaker** | 256-dim voice embeddings for speaker matching | Bundled |
| **Qwen 3.5-4B** | Infers speaker names from conversation context | ~2.5 GB (optional) |

All models run locally via [FluidAudio](https://github.com/FluidAudio) — **no internet connection required**.

The result: timestamped, speaker-labeled Markdown transcripts saved to your Mac.

### Sample Output

```markdown
---
date: 2026-03-14
duration: "12:47"
speakers:
  - name: "Sarah"
    source: db_match
    confidence: high
  - name: "Jack"
    source: qwen_inferred
    confidence: medium
total_word_count: 2341
---

[00:00] Sarah: Alright, let's kick off the sprint planning.
[00:03] Jack: Sure. I've got the backlog pulled up.
[00:08] Sarah: First item — the authentication refactor. Where are we on that?
[00:14] Jack: I finished the token rotation yesterday. The migration is ready
       but I want to run it by the security team before we merge.
[00:23] Sarah: Good call. Let's block that until Tuesday.
```

Every transcript includes YAML frontmatter with date, duration, word count, speaker metadata, capture quality metrics, and more.

---

## How It Compares

### vs. Cloud Transcription Services

These tools send your audio to remote servers for processing. Some add a visible bot to your meetings.

| | Transcripted | Otter.ai | Fireflies.ai | Fathom | tl;dv |
|---|:---:|:---:|:---:|:---:|:---:|
| **Processing** | 100% local | Cloud | Cloud | Cloud | Cloud |
| **Meeting bot joins call** | No | Yes | Yes | Yes | Yes |
| **Speaker diarization** | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Learns voices over time** | ✅ | ❌ | ❌ | ❌ | ❌ |
| **Speaker name inference** | ✅ (on-device LLM) | ❌ | ❌ | ❌ | ❌ |
| **System audio capture** | ✅ | ❌ (bot captures) | ❌ (bot captures) | ❌ (bot captures) | ❌ (bot captures) |
| **Auto meeting detection** | ✅ | ❌ | ❌ | ❌ | ❌ |
| **Works offline** | ✅ | ❌ | ❌ | ❌ | ❌ |
| **Open source** | ✅ MIT | ❌ | ❌ | ❌ | ❌ |
| **Free tier** | **Unlimited** | 300 min/mo | 20 AI credits/mo | 5 summaries/mo | 10 lifetime summaries |
| **Paid price** | **Free forever** | $8.33–$30/mo | $10–$39/mo | $15–$39/mo | $18–$59/mo |
| **Data location** | Your Mac | US cloud | US cloud | US cloud | EU cloud |
| **Audio retained** | Deleted after transcription | Stored on servers | Stored on servers | Stored on servers | Stored on servers |
| **Privacy lawsuits** | N/A | [Yes (2025)](https://meetily.ai/blog/meetily-vs-otter-ai-privacy-first-alternative-2025) | [Yes (biometrics)](https://www.ebglaw.com/insights/publications/ai-meeting-assistants-and-biometric-privacy-lessons-from-the-fireflies-ai-lawsuit) | No | No |

### vs. Privacy-Focused & Local Tools

These tools process audio on your device or emphasize privacy. Closer to what Transcripted does.

| | Transcripted | Granola | Krisp | MacWhisper | Meetily |
|---|:---:|:---:|:---:|:---:|:---:|
| **Processing** | 100% local | Hybrid (audio local, AI cloud) | On-device (English) | 100% local | 100% local |
| **STT model** | Parakeet TDT V3 | Proprietary (cloud) | Proprietary | Whisper | Parakeet or Whisper |
| **Speaker diarization** | ✅ Sortformer | ❌ desktop / ✅ iPhone | ✅ | ⚠️ Beta (WhisperKit) | ⚠️ Proof of concept |
| **Learns voices over time** | ✅ (256-dim embeddings) | ❌ | ❌ | ❌ | ❌ |
| **Speaker name inference** | ✅ Qwen 3.5-4B | ❌ | ❌ | ❌ | ❌ |
| **Meeting bot** | No | No | No | No | No |
| **System audio capture** | ✅ | ✅ | ✅ (virtual device) | ✅ | ✅ |
| **Auto meeting detection** | ✅ | ❌ (manual start) | ❌ | ❌ | ❌ |
| **Works fully offline** | ✅ | ❌ (needs cloud for AI) | ✅ (English only) | ✅ | ✅ |
| **AI summaries** | ❌ (transcripts only) | ✅ | ✅ | ❌ | ✅ (via Ollama) |
| **Open source** | ✅ MIT | ❌ | ❌ | ❌ | ✅ MIT |
| **Cost** | **Free** | $14–$35/mo | $8–$16/mo | $80 one-time | Free (Pro $10/mo) |
| **Platforms** | macOS | macOS, Windows, iOS | macOS, Windows, mobile | macOS | macOS, Windows |

### vs. Apple Built-in

| | Transcripted | Apple Dictation | Voice Memos | Notes (macOS 15+) |
|---|:---:|:---:|:---:|:---:|
| **Speaker diarization** | ✅ up to 4 speakers | ❌ | ❌ | ❌ |
| **System audio capture** | ✅ | ❌ | ❌ | ❌ |
| **Auto meeting detection** | ✅ | ❌ | ❌ | ❌ |
| **Works offline** | ✅ | ✅ (Apple Silicon) | ✅ | ✅ |
| **Meeting transcription** | ✅ | ❌ (text input only) | ❌ (no speaker labels) | ❌ (no speaker labels) |
| **Structured output** | Markdown + YAML | Plain text | Searchable text | Inline text |
| **Voice fingerprints** | ✅ | ❌ | ❌ | ❌ |
| **Cost** | Free | Free | Free | Free |

Apple's `SpeechAnalyzer` API (WWDC 2025) is fast and efficient, but provides no speaker diarization, no meeting detection, and no system audio capture. Transcripted fills all three gaps.

---

## Features

### Recording

- **Floating pill UI** — A Dynamic Island-style interface (40×20px idle, 180×40px recording) that floats above all windows without interrupting your workflow. Includes aurora animations with color-coded audio sources (coral for mic, teal for system audio).
- **Dual audio capture** — Records both your microphone and system audio simultaneously. Captures audio from Zoom, Google Meet, Microsoft Teams, Webex, FaceTime, Loom — anything that plays through your speakers.
- **Auto-meeting detection** — Monitors for meeting apps (Zoom, Teams, Webex, FaceTime, Loom) and automatically starts recording when it detects sustained bidirectional speech for 5+ seconds. Stops when audio drops for 15+ seconds or the meeting app quits.
- **Global hotkey** — Press **⌘⇧R** from any app to toggle recording. No need to switch windows.
- **Recording health monitoring** — Real-time quality tracking: capture quality grades (excellent/good/fair/degraded), audio gap detection, and device switch monitoring.

### Transcription

- **Parakeet TDT V3** — NVIDIA's speech-to-text model running on Apple's Neural Engine. Processes audio locally with no internet dependency.
- **Sortformer diarization** — Identifies up to 4 simultaneous speakers and labels who said what at each timestamp.
- **Persistent voice fingerprints** — Stores 256-dimensional voice embeddings in a local SQLite database. Uses cosine similarity matching with adaptive thresholds that relax as more speech segments are available (0.85 → 0.80 → 0.75 → 0.70). Embeddings are refined over time using exponential moving average blending (α=0.15).
- **Qwen speaker naming** — An optional on-device LLM (Qwen 3.5-4B, 4-bit quantized) that analyzes the first 15 minutes of transcript text to infer speaker names from conversational context (e.g., "Hey Sarah, can you pull up the report?"). Loads on-demand, unloads immediately after inference.
- **Smart post-processing** — Pairwise speaker merging via union-find transitive closure, database-informed splitting for mismatched segments, and 34 hardcoded name variant pairs (Mike↔Michael, Nate↔Nathan, etc.).

### Output

- **Markdown transcripts** — Clean, readable output with YAML frontmatter containing date, duration, word count, speaker metadata, capture quality, and audio source information.
- **`[MM:SS]` timestamps** — Every utterance is timestamped for easy reference.
- **Auto-save** — Transcripts are saved to `~/Documents/Transcripted/` (customizable in settings).
- **Export** — Copy or export transcripts as Markdown or plain text via the transcript tray.
- **Obsidian integration** — Optional Obsidian-compatible frontmatter with tags, aliases, and CSS classes.
- **Agent-ready output** — JSON sidecar files + index for automation workflows.

### Stats & Tracking

- Total hours transcribed, recording count, and active days
- Current and longest recording streaks
- Average meeting duration
- Monthly activity heatmap
- Recent transcript quick-access

---

## Quick Start

### Requirements

- **macOS 14.2+** (Sonoma or later)
- **~3 GB disk space** (~600 MB for Parakeet, ~2.5 GB for Qwen if enabled)
- **Xcode 15+** and **Swift 5.9+** (for building from source)

### Build from Source

```bash
# Clone the repository
git clone https://github.com/r3dbars/transcripted.git
cd transcripted

# Open in Xcode
open Transcripted.xcodeproj
```

1. In Xcode, select your **Development Team** under Signing & Capabilities
2. Press **⌘R** to build and run
3. Models download automatically from HuggingFace on first launch

### First Launch

Transcripted walks you through a 4-step onboarding:

1. **Welcome** — Introduction to the app
2. **How It Works** — Animated walkthrough of the recording → transcription → analysis pipeline
3. **Permissions** — Microphone access (required). Screen Recording permission is needed separately for system audio capture.
4. **Ready** — Quick-start tips and you're good to go

### Permissions

| Permission | Purpose | Required |
|------------|---------|:--------:|
| Microphone | Capture your voice | ✅ Yes |
| Screen Recording | Capture system audio from Zoom, Meet, Teams, etc. | For system audio |

### Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| **⌘⇧R** | Toggle recording (global — works from any app) |
| **⌘,** | Open Settings |
| **Escape** | Dismiss transcript tray |

---

## How It Works

```
┌─────────────┐     ┌─────────────┐
│  Microphone  │     │ System Audio │
│  (your voice)│     │ (Zoom, Meet) │
└──────┬───────┘     └──────┬───────┘
       │                     │
       ▼                     ▼
┌──────────────────────────────────┐
│     Audio Capture & Resampling   │
│       16 kHz · Mono · Float32    │
└───────────────┬──────────────────┘
                │
        ┌───────┴───────┐
        ▼               ▼
┌──────────────┐ ┌──────────────┐
│ Parakeet TDT │ │  Sortformer  │
│    V3 (STT)  │ │ (Diarization)│
│  Neural Engine│ │  ≤4 speakers │
└──────┬───────┘ └──────┬───────┘
       │                │
       ▼                ▼
┌──────────────────────────────────┐
│   Speaker Matching & Merging     │
│  256-dim embeddings · SQLite DB  │
│  Cosine similarity · EMA blend   │
└───────────────┬──────────────────┘
                │
                ▼
┌──────────────────────────────────┐
│   Qwen 3.5-4B (Optional)        │
│   Infers names from context      │
│   "Hey Sarah" → Speaker 0 = Sarah│
└───────────────┬──────────────────┘
                │
                ▼
┌──────────────────────────────────┐
│    Markdown Transcript Output    │
│  ~/Documents/Transcripted/*.md   │
└──────────────────────────────────┘
```

---

## Configuration

All settings are accessible via the Settings window (**⌘,**):

| Setting | Default | Description |
|---------|---------|-------------|
| Save location | `~/Documents/Transcripted/` | Where transcripts are saved |
| Your name | — | Used for speaker attribution |
| Auto-record meetings | Off | Automatically start when meeting apps are detected |
| Qwen speaker naming | On | Use on-device LLM to infer speaker names |
| UI sounds | On | Play sounds on recording start/stop/save |
| Obsidian format | Off | Add Obsidian-compatible metadata to transcripts |
| Aurora animation | Off | Enhanced recording animation |

---

## Architecture

<details>
<summary><strong>Project structure</strong></summary>

```
Transcripted/
├── Core/                        # Audio capture, transcription pipeline, persistence
│   ├── Audio.swift              # Microphone capture via AVAudioEngine
│   ├── SystemAudioCapture.swift # System audio via CoreAudio process taps
│   ├── Transcription.swift      # Orchestrates STT + diarization pipeline
│   ├── TranscriptionTaskManager.swift  # Background queue with retries
│   ├── TranscriptSaver.swift    # Markdown + YAML frontmatter output
│   ├── TranscriptStore.swift    # Transcript file discovery & parsing
│   ├── TranscriptExporter.swift # Export to Markdown / plain text
│   ├── StatsService.swift       # Recording statistics aggregation
│   ├── StatsDatabase.swift      # SQLite stats persistence
│   └── FailedTranscriptionManager.swift  # Retry queue for failed jobs
│
├── Services/                    # ML models & external integrations
│   ├── ParakeetService.swift    # Parakeet TDT V3 (speech-to-text)
│   ├── SortformerService.swift  # Sortformer (speaker diarization)
│   ├── QwenService.swift        # Qwen 3.5-4B (speaker name inference)
│   ├── SpeakerDatabase.swift    # Voice fingerprint storage (SQLite)
│   ├── AudioResampler.swift     # Resampling to 16kHz mono Float32
│   └── MeetingDetector.swift    # Auto-detection of meeting apps
│
├── UI/
│   ├── FloatingPanel/           # Floating pill UI + aurora animations
│   │   ├── FloatingPanelController.swift  # NSPanel (floating, non-activating)
│   │   ├── PillStateManager.swift         # State machine (idle → recording → processing)
│   │   ├── Components/                    # Aurora views, trays, toasts
│   │   └── ...
│   └── Settings/                # Settings window + stats dashboard
│
├── Design/                      # Design tokens, colors, shared components
├── Onboarding/                  # First-run experience (4 steps)
└── TranscriptedApp.swift        # App entry point (LSUIElement — no dock icon)
```

</details>

<details>
<summary><strong>Threading model</strong></summary>

Transcripted has strict threading rules due to CoreAudio's real-time requirements:

| Component | Thread | Notes |
|-----------|--------|-------|
| Audio, Transcription, TaskManager | `@MainActor` | UI-bound state |
| PillStateManager, all Services | `@MainActor` | UI-bound state |
| SystemAudioCapture | `DispatchQueue` + `NSLock` | Real-time audio I/O |
| SpeakerDatabase, StatsDatabase | Serial `DispatchQueue` | Sync reads, async writes |
| CoreAudio I/O callbacks | Real-time thread | **No I/O, locks, allocations, or ObjC calls** |

CoreAudio I/O callbacks run on real-time threads. Buffers are deep-copied before async dispatch — never processed in-place.

</details>

<details>
<summary><strong>Data storage</strong></summary>

| Data | Location | Format |
|------|----------|--------|
| Transcripts | `~/Documents/Transcripted/` | Markdown (.md) |
| Speaker database | `~/Documents/Transcripted/speakers.sqlite` | SQLite (WAL mode) |
| Recording stats | `~/Documents/Transcripted/stats.sqlite` | SQLite |
| Failed queue | `~/Documents/Transcripted/failed_transcriptions.json` | JSON |
| Speaker clips | `~/Documents/Transcripted/speaker_clips/` | WAV |
| Application logs | `~/Library/Logs/Transcripted/app.jsonl` | JSON Lines (rolling 2000 entries) |
| Qwen model cache | `~/Library/Caches/models/mlx-community/` | MLX 4-bit quantized |

All user data stays in `~/Documents/Transcripted/`. No hidden directories, no cloud sync, no telemetry.

</details>

<details>
<summary><strong>Speaker identification deep dive</strong></summary>

The speaker identification pipeline works in several stages:

**1. Embedding extraction** — WeSpeaker generates a 256-dimensional, L2-normalized vector for each audio segment.

**2. Adaptive matching** — Cosine similarity against the speaker database, with thresholds that relax as more segments are available:

| Segments | Threshold | Rationale |
|----------|-----------|-----------|
| 1 | 0.85 | High confidence needed with limited data |
| 2 | 0.80 | Slightly relaxed |
| 3 | 0.75 | More data to confirm |
| 4+ | 0.70 | Sufficient data for lower threshold |

**3. EMA blending** — When a match is found, the stored embedding is updated: `new = (1 - 0.15) × old + 0.15 × new`. This allows voice profiles to adapt over time (e.g., different microphones, colds).

**4. Post-processing:**
- **Pairwise merge** — Union-find transitive closure at 0.85 cosine threshold merges over-segmented speakers.
- **DB-informed split** — Per-segment 0.62 threshold with ≥8 segments required, splits incorrectly merged speakers.
- **Name variants** — 34 hardcoded pairs handle common nicknames (Mike↔Michael, Nate↔Nathan, etc.).
- **Pruning** — Removes unnamed profiles with 1 call, low confidence, and >1 hour since last seen.

**5. Name inference** — Qwen 3.5-4B analyzes the first 15 minutes of transcript text to infer names from conversational cues. Critical rule: "Hey Jack" means Jack is the *listener*, not the speaker.

</details>

<details>
<summary><strong>Meeting auto-detection</strong></summary>

Transcripted monitors for these meeting apps by bundle ID:

| App | Bundle ID |
|-----|-----------|
| Zoom | `us.zoom.xos` |
| Microsoft Teams | `com.microsoft.teams2`, `com.microsoft.teams` |
| Webex | `com.webex.meetingmanager`, `com.cisco.webex.meetings` |
| FaceTime | `com.apple.FaceTime` |
| Loom | `com.loom.desktop` |

**Detection flow:**
1. NSWorkspace monitors app launches
2. When a meeting app is detected, lightweight audio metering begins (no recording yet)
3. Audio levels are polled every 1 second
4. When both mic and system audio exceed 0.02 threshold for ≥5 continuous seconds → recording starts
5. When audio drops below threshold for ≥15 seconds → recording stops
6. Meeting app quit → immediate stop

</details>

---

## Privacy & Security

Transcripted is built on a simple principle: **your conversations are yours**.

- **All processing is local.** Audio is processed by on-device models running on your Mac's Neural Engine. No data is sent to any server. No API calls. No analytics. No telemetry.
- **Audio is ephemeral.** Raw audio is held in memory during recording and discarded after transcription. Audio files are not persisted to disk beyond temporary processing.
- **Transcripts are local files.** Saved as plain Markdown to `~/Documents/Transcripted/`. You own them. Back them up however you want. Delete them whenever you want.
- **No network access.** Transcripted makes no outbound network connections during normal operation. Models are downloaded once from HuggingFace on first launch; after that, everything runs offline.
- **Open source.** Every line of code is auditable. There are no hidden data collection mechanisms.

See [SECURITY.md](SECURITY.md) for vulnerability reporting and the full privacy architecture.

### A Note on Recording Ethics

Transcripted is a powerful tool. With that comes responsibility:

- **Know your local laws.** Many jurisdictions require consent from all parties before recording a conversation. Some require only one-party consent. Check your local regulations.
- **Be transparent.** When recording meetings, consider informing participants.
- **Use responsibly.** This tool is designed for your own productivity — capturing meetings you're a part of so you don't lose important details. It is not designed for surveillance.

---

## Troubleshooting

<details>
<summary><strong>Common issues</strong></summary>

**No system audio being captured**
- Grant Screen Recording permission: System Settings → Privacy & Security → Screen Recording → enable Transcripted
- Restart Transcripted after granting the permission

**Models not loading**
- Check disk space (~3 GB needed)
- Check `~/Library/Logs/Transcripted/app.jsonl` for detailed error logs
- Models download from HuggingFace on first launch — ensure internet connectivity for initial setup

**Qwen not identifying speakers**
- Ensure "Qwen speaker naming" is enabled in Settings
- Requires ~4 GB free RAM to load the model
- Works best with 15+ minutes of conversation containing name mentions

**Transcript quality is poor**
- Check the `capture_quality` field in transcript frontmatter
- Ensure microphone is positioned correctly
- System audio quality depends on the meeting app's output

**App doesn't appear in dock**
- This is by design — Transcripted runs as a menu bar app (LSUIElement). Look for the microphone icon in your menu bar.

</details>

---

## Contributing

Contributions are welcome! Whether it's bug reports, feature requests, documentation improvements, or code contributions — we'd love your help.

- **Bug reports & feature requests** → [GitHub Issues](https://github.com/r3dbars/transcripted/issues)
- **Code contributions** → See [CONTRIBUTING.md](CONTRIBUTING.md) for setup instructions, architecture overview, coding guidelines, and the PR process
- **Good first issues** → Look for the [`good first issue`](https://github.com/r3dbars/transcripted/issues?q=is%3Aissue+is%3Aopen+label%3A%22good+first+issue%22) label

Please read our [Code of Conduct](CODE_OF_CONDUCT.md) before contributing.

---

## Acknowledgements

Transcripted is built on the shoulders of remarkable open-source work:

- **[NVIDIA NeMo](https://github.com/NVIDIA/NeMo)** — Parakeet TDT V3 (speech-to-text) and Sortformer (speaker diarization)
- **[FluidAudio](https://github.com/FluidAudio)** — Swift framework for running NeMo models on Apple Silicon
- **[WeSpeaker](https://github.com/wenet-e2e/wespeaker)** — Speaker embedding extraction
- **[Qwen](https://github.com/QwenLM/Qwen)** — On-device LLM for speaker name inference
- **[MLX](https://github.com/ml-explore/mlx)** — Apple's machine learning framework for efficient on-device inference

---

## Roadmap

- [ ] Pre-built `.dmg` releases for one-click install
- [ ] Homebrew cask (`brew install --cask transcripted`)
- [ ] Real-time live transcription overlay
- [ ] Custom vocabulary / jargon support
- [ ] Multi-language transcription
- [ ] Transcript search across all recordings
- [ ] Calendar integration for meeting metadata
- [ ] Summary generation (key decisions, action items)

Have an idea? [Open an issue](https://github.com/r3dbars/transcripted/issues/new?template=feature_request.md) — we'd love to hear it.

---

## License

[MIT](LICENSE) — use it, modify it, ship it.

---

<p align="center">
  <strong>Transcripted</strong> — Your meetings, transcribed locally.
  <br><br>
  If you find Transcripted useful, consider giving it a ⭐ — it helps others discover the project.
</p>
