# Draft

**Speak rough. Send polished. Sound like you.**

---

You know the moment. You're staring at a Slack message, rewriting the same sentence for the third time. Too formal. Too casual. Too long. You know what you *want* to say — you just can't get it to *sound right*.

Here's what's strange: if someone asked you the same question out loud, you'd answer in two seconds flat. Speaking is effortless. Writing is labor.

Draft closes that gap.

Press a hotkey. Say what you mean — rough, unfiltered, full of "ums" and half-thoughts. Draft rewrites it in *your voice*, with *the full conversation* as context, formatted for *the exact platform* you're in. Then it pastes it back. You never leave the app you're working in.

The whole thing takes about four seconds.

## What makes this different

Every AI writing tool gives you the same generic polish. Draft does something else entirely: **it learns how you write.**

Every message you accept trains a personal style profile. Your sentence length. Your favorite phrases. The way you open a message to your boss vs. a group chat with friends. The emoji habits you don't even realize you have.

By your twentieth draft, it's not Claude anymore. It's you — just faster.

## How it works

```
⌥D  →  speak  →  ⌥D  →  review  →  Enter
```

That's the whole flow. No mouse. No window switching. No copy-paste gymnastics.

Here's what happens under the hood:

1. **⌥D in any app** — Draft screenshots the conversation and captures who you're talking to, what's been said, and the formality of the thread. All automatic.

2. **Speak your intent** — Talk naturally. "Tell them I'm running ten minutes late but I'll bring coffee." Live transcription appears as you speak (on-device, your voice never leaves your Mac).

3. **⌥D again** — Claude drafts a polished message in your style, streamed token-by-token into a floating overlay. First words appear in ~200ms.

4. **Review and edit** — The draft is editable. Tweak anything. Or don't.

5. **Enter** — Pastes directly into the app you were using. Escape to cancel. That's it.

The overlay floats above your current app without stealing focus. When you press Enter, the paste goes to Slack (or iMessage, or your email) — not to Draft. This is a small detail that changes everything about how it feels to use.

## It sees what you see

Most AI writing tools work blind. You paste text in, get text back, paste it somewhere else.

Draft sees the full picture. When you press the hotkey, it captures a screenshot and extracts:

- **The conversation thread** — every message, who said what
- **Who you're talking to** — pulled from the app's title bar
- **The platform** — Slack, iMessage, email, Discord, Teams
- **The formality** — friends get casual. Clients get professional.

This means Draft knows the difference between "reply to my mom on iMessage" and "reply to the VP on Slack." You don't configure anything. It just looks.

## Platform-aware formatting

Draft detects the app and adjusts:

| Platform | What changes |
|----------|-------------|
| **Slack** | `*bold*` not `**bold**`, short paragraphs, no subject line |
| **iMessage** | Plain text, brief, conversational |
| **Email** | Full paragraphs, greeting, sign-off |
| **Discord** | Markdown-friendly, casual tone |
| **Generic** | Clean, neutral formatting |

You don't pick a mode. Draft reads the bundle ID of the frontmost app and adapts.

## Style learning

This is the core idea. Draft doesn't just polish — it *becomes you*.

**How the loop works:**

1. You accept a draft (or edit it first, then accept)
2. Draft saves the pair: what the AI wrote vs. what you actually sent
3. It measures the gap — how much did you change?
4. Every few drafts, it analyzes the pattern and updates your style profile

Your profile captures things like:

- **Tone** — warm but direct, uses humor sparingly
- **Signature phrases** — actual quotes from your writing ("honestly though", "yo", "sounds good to me")
- **Rules** — never uses "utilize," always starts emails with first name only, keeps Slack messages under 3 sentences
- **Quantitative fingerprint** — average sentence length, emoji frequency, contraction rate

Early on, Draft refines every 3 messages. As the edit distance shrinks (meaning it's getting you right), it slows to every 10. The profile is a living document — it adapts as your writing evolves.

## Privacy-first architecture

- **Voice stays local** — Parakeet STT runs on-device via CoreML. Your mic audio never hits a server.
- **Style learning is local** — Qwen 3.5-4B runs via MLX on Apple Silicon (~30-50 tok/s). Your training pairs stay on your Mac.
- **Only the final prompt goes to the API** — The drafted message uses Claude, but your raw voice, training history, and style profile never leave your machine.
- **No telemetry** — Structured logs exist for debugging (`events.jsonl`), but they're local files. Nothing phones home.

## Requirements

- macOS 14+
- Apple Silicon (M1/M2/M3/M4)
- Microphone permission
- Screen capture permission (for conversation context)
- Anthropic API key or Claude subscription token

## Install

Download the latest `.dmg` from [Releases](https://github.com/r3dbars/draft-releases/releases), open it, drag to Applications. The DMG is notarized and stapled — double-click to open, no right-click needed.

On first launch, Draft will:
1. Ask for microphone and screen capture permissions
2. Download the Parakeet speech model (~600MB, one-time)
3. Optionally import your iMessage history to bootstrap your style profile (requires Full Disk Access)

## Build from source

```bash
git clone https://github.com/r3dbars/Draft.git
cd Draft
bash build-deps.sh   # Build FluidAudio + MLX (~2 min, one-time)
bash build.sh        # Compile + sign + launch (~5s)
bash run-tests.sh    # 147 pure-function tests (~2s)
```

No Xcode project. No CocoaPods. No SPM. Just `swiftc` and Apple frameworks.

## Architecture

```
Sources/
├── Speech/        ← On-device STT (Parakeet CoreML + audio pipeline)
├── Capture/       ← Screenshot, context extraction, hotkey registration
├── Draft/         ← Drafting engine + platform formatting
├── Style/         ← Style learning + refinement scheduling
├── API/           ← Anthropic HTTP client (streaming, vision, auth)
├── Local/         ← MLX local LLM inference (Qwen 3.5-4B)
├── Prompts/       ← Externalized prompt templates
├── Feedback/      ← Training pair logging + usage stats
├── Analysis/      ← Feedback pattern analysis + prompt improvement
├── Accessibility/ ← AXUIElement queries for text field positioning
├── Observability/ ← Structured event logging
├── Messages/      ← iMessage database reader (onboarding import)
└── UI/            ← Floating overlay, menubar panel, onboarding
```

50 files. ~9,600 lines of Swift. Zero third-party dependencies.

Each subfolder has its own `CLAUDE.md` with component-specific documentation — architecture decisions, gotchas, and modification guides.

## Key decisions

- **Single binary, no Xcode** — compiled with `swiftc` via `build.sh`
- **Zero dependencies** — only Apple frameworks + FluidAudio/MLX built from source
- **Credentials in Keychain** — not UserDefaults, not env vars, not hardcoded
- **Carbon hotkeys** — OS-level interception, works in any app, survives background state
- **Non-activating NSPanel** — overlay doesn't steal focus, paste-back just works
- **Token-by-token streaming** — `AsyncThrowingStream<String, Error>`, first token ~200ms
- **NSLock for audio thread** — deterministic ~1μs overhead vs. unpredictable actor scheduling
- **Pure-function test suite** — no XCTest dependency, 2-second compile+run cycle

## Hotkeys

| Shortcut | Action |
|----------|--------|
| **⌥D** | Start draft session (screenshot + record), press again to draft |
| **⌥Space** | Quick dictation (speak → paste transcription, no drafting) |
| **Enter** | Accept draft and paste to source app |
| **Escape** | Cancel at any point |
| **Shift+Enter** | Newline in review mode |

## Diagnosing issues

```bash
# Recent errors
tail -50 ~/Library/Application\ Support/Draft/events.jsonl | grep '"level":"error"'

# Specific engine
grep '"engine":"parakeet"' ~/Library/Application\ Support/Draft/events.jsonl | tail -20

# Full narrative log
tail -200 ~/draft-debug.log
```

## License

[MIT](LICENSE)

---

*Draft is built by [r3dbars](https://github.com/r3dbars). Currently in beta.*
