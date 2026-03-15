# Draft

**Speak rough. Send polished. Sound like you.**

Draft is a macOS app that turns your voice into perfectly written messages — in *your* personal writing style. It runs 100% on-device. No cloud. No API keys. No subscriptions.

---

## Why Draft exists

You know the moment. You're staring at a Slack message, rewriting the same sentence for the third time. Too formal. Too casual. Too long. You know what you *want* to say — you just can't get it to *sound right*.

Here's what's strange: if someone asked you the same question out loud, you'd answer in two seconds flat. Speaking is effortless. Writing is labor.

Draft closes that gap.

---

## Two tools in one

Most voice-to-text apps do one thing: **dictation**. You speak, they transcribe, done. Apps like [SuperWhisper](https://superwhisper.com), [Wispr Flow](https://wisprflow.ai), and [VoiceInk](https://tryvoiceink.com) are great at this — but that's all they do.

Draft does dictation *and* something no other tool offers: **AI drafting with full conversation context.**

| | Dictation Mode | Draft Mode |
|---|---|---|
| **Shortcut** | `Option + Space` | `Option + D` |
| **What it does** | Speak and your words become text | Speak your intent and get a polished message written in your voice |
| **Context** | None needed | Screenshots the conversation, sees who you're talking to, detects the platform |
| **Output** | Exact transcription of what you said | A crafted reply that sounds like you wrote it |
| **Use case** | Filling out forms, writing notes, quick messages where your words are fine as-is | Replying to a Slack thread, composing an email, responding in iMessage |
| **Speed** | Instant | ~2-4 seconds |

**You get both.** Use dictation when you just want your words typed out. Use drafting when you want the AI to compose a polished message from your rough instructions.

---

## How Dictation Mode works

Dictation mode is the simplest way to get your voice into any text field on your Mac. It works in every app — Slack, iMessage, Notes, your browser, anywhere you can type.

### Step by step

1. **Click into any text field** — a Slack message box, an email compose window, a Google Doc, anything
2. **Press `Option + Space`** — a small overlay appears showing Draft is listening
3. **Speak naturally** — say whatever you want typed out. Draft shows a live transcription as you talk
4. **Press `Option + Space` again** — Draft pastes the transcription directly into the text field you were in
5. **Done** — the text is right where you need it. No copy-paste required

### What makes this different from built-in macOS dictation

- **It actually works** — Apple's built-in dictation is slow and often inaccurate. Draft uses Parakeet, a state-of-the-art speech model running locally via CoreML
- **It's instant** — transcription happens in real-time as you speak, not after a long processing delay
- **It never leaves your Mac** — your voice audio is processed on-device and discarded. Nothing is uploaded anywhere
- **It works offline** — no internet connection needed
- **It pastes automatically** — the text goes directly into whatever app you were using. No extra steps

### When to use dictation

- Writing emails or messages where your own words are exactly what you want
- Filling out forms or writing notes
- Any time you'd rather talk than type
- Jotting down quick thoughts

---

## How Draft Mode works

Draft mode is the feature that sets Draft apart from every other voice-to-text app. Instead of transcribing exactly what you say, it **reads the conversation you're looking at**, **listens to your intent**, and **writes a complete message in your personal writing style**.

Think of it like having a ghostwriter who knows how you talk, can see the conversation on your screen, and composes the perfect reply in seconds.

### Step by step

1. **Open any messaging app** — Slack, iMessage, email, Discord, Teams, or anything else
2. **Press `Option + D`** — Draft quietly captures a screenshot of the conversation and starts listening
3. **Speak your intent** — don't worry about grammar or phrasing. Just say what you mean:
   - *"Tell them I'm running ten minutes late but I'll bring coffee"*
   - *"Say that sounds good and ask when they want to meet"*
   - *"Politely decline the meeting and suggest next week instead"*
4. **Press `Option + D` again** — Draft stops listening and starts composing. You'll see the message appear word-by-word in a floating overlay
5. **Review the draft** — read it, edit it if you want, or leave it as-is
6. **Press `Enter`** — the message is pasted directly into the app you were using
7. **Or press `Escape`** — cancel and discard the draft. Nothing gets sent

### What happens behind the scenes

When you press `Option + D`, Draft does several things simultaneously:

- **Screenshots the conversation** — it captures what's on your screen so it knows the context
- **Extracts the conversation** — using Apple's Vision framework (on-device OCR), it reads every message in the thread, who sent what, and the overall tone
- **Identifies the platform** — it detects whether you're in Slack, iMessage, email, Discord, or Teams, and adjusts formatting accordingly
- **Gauges the formality** — a casual text to a friend gets a different style than a professional Slack message to your VP
- **Records your voice** — your spoken instructions are transcribed on-device
- **Composes the reply** — using all of this context plus your personal writing style profile, the on-device language model writes a message that sounds like you

All of this runs locally on your Mac. Nothing is sent to any server.

### When to use Draft Mode

- Replying to a Slack thread where you need to match the tone
- Composing an email response when you know what you want to say but not how to phrase it
- Responding to iMessages quickly without typing
- Any time you'd rather *describe* what you want to say instead of writing it yourself

---

## The floating overlay

Both modes use a floating overlay that appears above your current app. This is an important design detail:

- **Your app stays in focus** — Draft doesn't steal the window. Slack (or whatever you're in) stays frontmost the entire time
- **Paste goes to the right place** — when you press Enter, the text is pasted into the app you were using, not into Draft
- **No window switching** — you never have to switch between Draft and your messaging app. The overlay floats on top and disappears when you're done

The overlay shows different things depending on the state:

| State | What you see |
|-------|-------------|
| **Listening** | A waveform animation + live transcription of what you're saying |
| **Composing** | A spinner while the model writes your draft |
| **Streaming** | Words appearing in real-time as the model generates them |
| **Review** | The finished draft in an editable text box. Press Enter to send, Escape to cancel |

---

## It sees what you see

Most AI writing tools work blind. You paste text in, get text back, paste it somewhere else.

Draft sees the full picture. When you press `Option + D`, it captures a screenshot of the conversation and extracts:

- **The conversation thread** — every message, who said what, in order
- **Who you're talking to** — pulled from the app's title bar or conversation header
- **The platform** — Slack, iMessage, email, Discord, Teams
- **The formality** — friends get casual. Clients get professional

This means Draft knows the difference between "reply to my mom on iMessage" and "reply to the VP on Slack." You don't configure anything. It just looks.

---

## Platform-aware formatting

Different apps expect different formatting. Draft detects the app you're in and adjusts automatically:

| Platform | What changes |
|----------|-------------|
| **Slack** | Uses `*bold*` instead of `**bold**`, short paragraphs, no subject lines |
| **iMessage** | Plain text only, no markdown, brief and conversational |
| **Email** | Full paragraphs, proper greeting and sign-off, markdown OK |
| **Discord** | Standard markdown, casual and conversational tone |
| **Teams** | Standard markdown, clean and professional |
| **Other apps** | Clean, neutral formatting |

You never pick a mode. Draft reads the bundle ID of the app in focus and adapts.

---

## Style learning

This is the core idea. Draft doesn't just polish text — it **learns how *you* write** and produces messages that are indistinguishable from ones you'd type yourself.

### How the learning loop works

1. **You accept a draft** — or edit it first, then accept
2. **Draft saves the pair** — what the AI wrote vs. what you actually sent
3. **It measures the gap** — how much did you change? What did you remove? What did you rephrase?
4. **Every few drafts, it updates your profile** — the model analyzes patterns in your edits and refines its understanding of your voice

### What your profile captures

- **Tone** — warm but direct, uses humor sparingly, never stiff
- **Signature phrases** — actual quotes from your writing: *"honestly though"*, *"yo"*, *"sounds good to me"*
- **Hard rules** — never uses "utilize," always starts emails with first name only, keeps Slack messages under 3 sentences
- **Quantitative fingerprint** — average sentence length, emoji frequency, contraction rate, exclamation point habits
- **Platform differences** — how you write differently in Slack vs. email vs. iMessage

### Graduated refinement

Early on (first 20 drafts), Draft refines your profile every 3 accepted messages — it's learning fast. As the edit distance shrinks (meaning it's getting you right), it slows to every 10. The profile is a living document that adapts as your writing evolves.

### Cold-start onboarding

You don't have to wait 20 drafts to get good results. On first launch, Draft offers two ways to bootstrap your style profile immediately:

- **Import from iMessages** (recommended) — Draft reads your sent messages from iMessage and analyzes them locally to build an instant profile. Requires Full Disk Access permission. Your messages are analyzed on-device and discarded after profile generation.
- **Paste writing samples** — Copy-paste some of your Slack messages, emails, or texts into a text box. Draft analyzes them locally and builds your profile.

Either way, the analysis runs entirely on your Mac using the local language model. No data leaves your machine.

---

## 100% local — nothing leaves your Mac

Draft is built on the principle that your voice, your writing style, and your conversations should never leave your computer.

| Component | Technology | Where it runs |
|-----------|-----------|---------------|
| **Voice recognition** | Parakeet (CoreML) | On your Mac |
| **Message drafting** | Qwen 3.5-4B via MLX | On your Mac |
| **Style learning** | Qwen 3.5-4B via MLX | On your Mac |
| **Screen reading** | Apple Vision framework | On your Mac |
| **Conversation analysis** | Qwen 3.5-4B via MLX | On your Mac |

- **No API keys** — you don't need an account with OpenAI, Anthropic, or anyone else
- **No subscriptions** — Draft is free and open source
- **No internet required** — Draft works completely offline after the initial model download
- **No telemetry** — no usage data, analytics, or crash reports are sent anywhere. Debug logs are local files only
- **Your voice is never recorded** — audio is processed in real-time and discarded. There is no recording saved

### Performance

On Apple Silicon (M1 and later), the on-device language model generates text at approximately 30-50 tokens per second. The first words of a draft appear in about 200 milliseconds. The entire drafting process typically takes 2-4 seconds.

---

## Requirements

- **macOS 14 or later** (Sonoma or newer)
- **Apple Silicon** (M1, M2, M3, M4 — any variant)
- **Microphone permission** — so Draft can hear you speak
- **Screen Recording permission** — so Draft can see the conversation you're replying to (Draft Mode only)
- **~3.1 GB of disk space** — for the speech model (~600MB) and language model (~2.5GB), downloaded once on first launch

---

## Installation

### Download the app

Download the latest `.dmg` from [Releases](https://github.com/r3dbars/draft-releases/releases). Open it and drag Draft to your Applications folder.

The DMG is notarized and stapled by Apple — just double-click to open. No right-click workaround needed.

### First launch

When you open Draft for the first time, it will:

1. **Ask for permissions** — microphone and screen recording. Draft walks you through granting these in System Settings
2. **Download the speech model** (~600MB) — Parakeet, a CoreML model for voice recognition. This happens once
3. **Download the language model** (~2.5GB) — Qwen 3.5-4B, the model that writes your drafts. This also happens once
4. **Walk you through the basics** — an interactive onboarding shows you how to use dictation and drafting with a practice conversation
5. **Optionally import your writing style** — you can import from iMessage or paste writing samples to get personalized results immediately

After setup, Draft lives in your menu bar. The models are cached locally and load automatically on future launches.

### Updating

When a new version is available, Draft will prompt you to update. Updates download and install automatically.

---

## Build from source

If you'd like to build Draft yourself:

```bash
git clone https://github.com/r3dbars/Draft.git
cd Draft
bash build-deps.sh   # Build FluidAudio + MLX dependencies (~2 min, one-time)
bash build.sh        # Compile + sign + launch (~5s)
bash run-tests.sh    # Run 147 pure-function tests (~2s)
```

No Xcode project. No CocoaPods. No SPM. Just `swiftc` and Apple frameworks.

### What the build scripts do

- **`build-deps.sh`** — Downloads and compiles [FluidAudio](https://github.com/nicholasgasior/FluidAudio) (speech recognition) and [mlx-swift-lm](https://github.com/ml-explore/mlx-swift-examples) (local inference) into a single static library. Also compiles the Metal shaders that MLX uses for GPU acceleration. You only need to run this once.
- **`build.sh`** — Compiles all Swift source files into a single binary, signs the app bundle, and launches it. Takes about 5 seconds.
- **`run-tests.sh`** — Compiles and runs the test suite. 147 pure-function tests covering context parsing, platform formatting, refusal detection, message filtering, style utilities, and more. No XCTest or Xcode required. Runs in about 2 seconds.

---

## Keyboard shortcuts

These are the default shortcuts. You can customize them in Draft's settings (click the menu bar icon, then the gear icon).

### Core shortcuts

| Shortcut | What it does |
|----------|-------------|
| **`Option + D`** | **Draft Mode** — press once to start (screenshots + records), press again to generate the draft |
| **`Option + Space`** | **Dictation Mode** — press once to start recording, press again to transcribe and paste |

### While the overlay is open

| Shortcut | What it does |
|----------|-------------|
| **`Enter`** | Accept the draft and paste it into the app you were using |
| **`Shift + Enter`** | Insert a newline (for editing multi-line drafts) |
| **`Escape`** | Cancel and close the overlay. Nothing gets pasted |

### Quick reference

```
Draft Mode:     ⌥D  →  speak your intent  →  ⌥D  →  review  →  Enter
Dictation Mode: ⌥Space  →  speak  →  ⌥Space  →  text is pasted
Cancel anytime: Escape
```

---

## Comparison with other tools

| Feature | Draft | SuperWhisper | Wispr Flow | VoiceInk | macOS Dictation |
|---------|-------|-------------|------------|----------|-----------------|
| Dictation (voice to text) | Yes | Yes | Yes | Yes | Yes |
| AI drafting (voice to polished message) | **Yes** | No | No | No | No |
| Sees your conversation context | **Yes** | No | No | No | No |
| Learns your writing style | **Yes** | No | Partial | No | No |
| Platform-aware formatting | **Yes** | No | Partial | No | No |
| 100% on-device | **Yes** | Partial | No | Partial | Yes |
| No API keys required | **Yes** | No | No | No | Yes |
| Free and open source | **Yes** | No | No | Yes (GPL) | N/A |
| Works offline | **Yes** | Partial | No | Partial | Partial |

---

## Architecture

```
Sources/
├── Speech/        ← On-device STT (Parakeet CoreML + audio pipeline)
├── Local/         ← On-device LLM inference (Qwen 3.5-4B via MLX)
├── Capture/       ← Screenshot, context extraction (Apple Vision OCR), hotkey registration
├── Draft/         ← Drafting engine + platform formatting
├── Style/         ← Style learning + refinement scheduling
├── Prompts/       ← Externalized prompt templates
├── Feedback/      ← Training pair logging + usage stats
├── Analysis/      ← Feedback pattern analysis + prompt improvement
├── Messages/      ← iMessage database reader (onboarding import)
├── Accessibility/ ← AXUIElement queries for text field positioning
├── Observability/ ← Structured event logging
└── UI/            ← Floating overlay, menubar panel, onboarding
```

~50 files. ~9,600 lines of Swift. Zero third-party runtime dependencies — only Apple frameworks plus FluidAudio and MLX built from source.

Each subfolder has its own `CLAUDE.md` with detailed component documentation — architecture decisions, gotchas, and modification guides.

---

## Troubleshooting

### Draft doesn't hear me

- Check that microphone permission is granted: **System Settings > Privacy & Security > Microphone** — Draft should be listed and enabled
- Check that your input device is working: **System Settings > Sound > Input** — speak and verify the level meter moves
- If you use a USB audio interface (like BEACN Mic), Draft automatically handles format conversion. If audio still fails, try switching to the built-in microphone temporarily

### Draft doesn't see the conversation

- Check that Screen Recording permission is granted: **System Settings > Privacy & Security > Screen Recording** — Draft should be listed and enabled
- After granting permission, you may need to restart Draft
- Note: rebuilding the app from source may invalidate the permission (new code signature). Re-grant it in System Settings

### The model is still loading

On first launch, Draft downloads two models:
- **Parakeet** (~600MB) — speech recognition
- **Qwen 3.5-4B** (~2.5GB) — language model

These download once and are cached. If the download is interrupted, restart Draft and it will resume.

The menu bar icon shows an orange dot while models are loading. It turns green when everything is ready.

### The draft doesn't sound like me

Draft gets better over time. Each message you accept (or edit and accept) teaches it more about your writing style. After about 20 accepted drafts, most people notice a significant improvement.

To accelerate this, use the style onboarding: click the menu bar icon and import your iMessages or paste writing samples. This gives Draft a head start.

### Checking the logs

If something isn't working and you want to dig deeper:

```bash
# Recent errors
tail -50 ~/Library/Application\ Support/Draft/events.jsonl | grep '"level":"error"'

# Check a specific engine (parakeet, draft, capture, style, overlay)
grep '"engine":"parakeet"' ~/Library/Application\ Support/Draft/events.jsonl | tail -20

# Full narrative log
tail -200 ~/draft-debug.log
```

---

## FAQ

### Is my voice recorded?

No. Audio is processed in real-time by the on-device speech model and discarded immediately. There is no audio recording saved anywhere.

### Does Draft send my data anywhere?

No. Everything runs locally on your Mac — voice recognition, message drafting, style learning, and conversation reading. There are no network calls for any AI functionality. Draft works completely offline.

### Do I need an API key?

No. Draft uses on-device models (Parakeet for speech, Qwen 3.5-4B for text). No API keys, accounts, or subscriptions are needed.

### How much disk space does Draft need?

About 3.1 GB for the two models (downloaded once on first launch), plus the app itself (~50 MB). Your style profile and feedback logs are small text files (typically under 1 MB).

### Does it work with [specific app]?

Draft works in any app with a text field. It has special formatting rules for Slack, iMessage, email, Discord, and Teams. For all other apps, it uses clean, neutral formatting.

### Can I customize the keyboard shortcuts?

Yes. Click the Draft menu bar icon, then the gear icon, and you'll find the shortcut recorder.

### How does style learning work with privacy?

Your writing style profile is stored locally at `~/Library/Application Support/Draft/style.md`. Training pairs (what the AI drafted vs. what you actually sent) are stored in `feedback.jsonl` in the same folder. These files never leave your machine. When Draft refines your profile, it runs the analysis on-device using the local language model.

### What language models does Draft use?

- **Parakeet** — a CoreML speech recognition model from FluidAudio. Runs on the Neural Engine
- **Qwen 3.5-4B-4bit** — a quantized language model from the [Qwen](https://huggingface.co/Qwen) family, run via [MLX](https://github.com/ml-explore/mlx) on Apple Silicon GPU. This is the model that writes your drafts, refines your style profile, and analyzes feedback patterns

---

## Contributing

Draft is open source under the MIT license. Contributions are welcome.

- **Bug reports** — open an issue with steps to reproduce
- **Feature requests** — open an issue describing the use case
- **Pull requests** — fork the repo, make your changes, and submit a PR

Before submitting code changes, make sure both build and tests pass:

```bash
bash build.sh && bash run-tests.sh
```

---

## License

[MIT](LICENSE)

---

*Draft is built by [r3dbars](https://github.com/r3dbars).*
