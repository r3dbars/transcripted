# Transcripted threat model

Read by Codex security reviews (set as the threat-model path in Codex's code review settings) and by anyone reviewing a change for security. `SECURITY.md` is the public policy; this file is the reviewer's map. Keep it short and true to the code.

## What we protect

In order of harm if it leaks or breaks:

1. **What the user said and typed.** Meeting audio, dictation audio, transcripts, Writing captures, speaker names and voiceprints (`speakers.sqlite`), meeting titles. All of it stays on the Mac unless the user sends it somewhere.
2. **Secrets the user typed.** Passwords, one-time codes, card numbers and API keys that pass through Writing capture. Secure-input fields and password-manager apps are never captured. For the rest, `WritingSecretScrubber` removes what its patterns recognize before a day file is written. That is best effort: a passphrase typed outside a terminal or a short mixed token can still land in the day file.
3. **The user's other apps.** Transcripted holds Microphone, System Audio Recording, Accessibility and Calendar permissions, and paste-back types into other apps. Code that gets into the app inherits all of that.
4. **The update channel.** Sparkle EdDSA signing key, the appcast, Developer ID signing and notarization. Whoever controls these ships code to every user.
5. **The repo and CI.** The `main` branch, the self-hosted Mac runner, repo secrets, and the auto-merge gate. The repo is public.

## Trust boundaries

| Boundary | What crosses it | Control |
|---|---|---|
| Mac → Sentry, PostHog | crash and usage events | Explicit diagnostics and PostHog events are allowlisted (`SentryEventPolicy`, key-name drop list in `check-telemetry-keys.py`). Sentry also auto-captures crashes, uncaught exceptions and hangs (`CrashReporter.swift`); those are not allowlisted, only gated by the user switch and sanitized in `beforeSend`, so an unknown payload shape is forwarded after sanitizing, not dropped. Contract: `docs/privacy-first-observability.md` |
| Mac → Hugging Face | model downloads | huggingface.co over TLS. Parakeet (`AsrModels.download`), Whisper (`WhisperKit.download`) and the diarizers download through their SDKs with no digest check (`ParakeetModelLifecycle.swift` says so). `ModelDownloadService`'s SHA-256 helpers exist but no production path calls them (known gap) |
| Mac ← GitHub (Sparkle) | app updates | EdDSA signature against the key embedded in the app |
| Other local apps → MCP server | saved captures, meeting controls | `Tools/TranscriptedMCP` is stdio with no per-caller auth: launching it grants read access to every capture. Its companion tools (`CompanionTools.swift`) can also `start_meeting`, `stop_meeting` and `set_live_context_sharing` through the app, but only when the user has turned on companion meeting control or live sharing in Transcripted |
| ChatGPT companion → app | context, meeting controls, live text | Unix socket in a `0700` directory, socket and connection file `0600`, rotating token never logged or returned by a tool. Off until enabled; controls and live sharing are separate permissions; live text needs a per-meeting switch |
| App → other apps | paste-back keystrokes, Auto Enter | Accessibility permission; pastes only the user's own dictation |
| GitHub issues and PR comments → agents | task text | Issue runner reads only `allowed_authors` and filtered operator feedback (`WORKFLOW.md`), never raw comments |
| Fork PRs → CI | untrusted code | Fork PRs never run on the owner's Mac (`pick-ci-runner.py`, `mac-runner.sh` job hook); Mac jobs run in throwaway VMs |
| Agent PRs → `main` | code without the owner's review | Auto-merge gate lanes and `deny_always` (`.agents/auto-merge-lanes.json`), required checks, Codex review, red-main stop |

## Known weak spots (by design, for now)

- The app is not sandboxed and has library validation off, because the ML stack ships dylibs with mixed signing. User-level malware that writes into the app bundle inherits its permissions. Don't widen this.
- The MCP server has no caller authentication. Its only write tools are the companion meeting controls, gated by the app's companion permissions. Don't add others without adding auth.
- Speech and diarization model downloads aren't hash-pinned. Trust rests on TLS to huggingface.co. Writing verifies downloaded weights against the SHA-256 digest in its bundled model descriptor (`ModelManager.swift`).

## What a reviewer should flag as high severity

- Any path where transcript text, audio or audio file paths, meeting titles, speaker names, emails, tokens, absolute paths, raw URLs or raw device names can reach Sentry, PostHog, logs shipped off the device, or the network. That includes new analytics properties, new Sentry context or breadcrumbs, and error messages that embed user content.
- New network destinations, or a cleartext endpoint off the machine. Loopback HTTP to the local Writing helper (`LlamaServerProcessHost`, bound to `127.0.0.1`, access key on every request) is intended; flag it only if it binds wider or drops the key.
- Changes that weaken the companion socket: file modes, token handling, a token in a log or tool result, or capabilities on by default.
- New MCP tools that write, delete or run commands, or that read outside the capture library. Companion controls that work without their app permission.
- Writing capture changes that let secrets through: scrubber rules removed or loosened, secure-input or password-manager checks bypassed.
- New entitlements, or loosening `config/entitlements/*` or `config/security/nightly-security-manifest.json`.
- Model downloads from a new host or over a non-TLS path.
- Updater changes: appcast URL, signature checks, the embedded public key.
- CI changes that let fork code, `pull_request_target`, or untrusted input reach the self-hosted Mac or repo secrets. Secrets echoed into logs.
- Changes to `.agents/auto-merge-lanes.json` or `scripts/ops/auto-merge-gate.py` that widen what merges without the owner.
- Deleting or writing files outside the root the code owns (path traversal, symlinks in the capture library).
- Agent instructions (`AGENTS.md`, `WORKFLOW.md`, skills) that tell an agent to act on raw issue or PR comment text.

## Out of scope

- An attacker already running inside Transcripted, or already holding the same TCC grants. Other same-user code is in scope: it lacks Transcripted's Microphone, System Audio, Accessibility and Calendar grants, and injecting into or replacing the app would hand them over.
- Physical access to an unlocked Mac.
- Local models giving wrong or offensive transcripts. That's a quality bug, not a security one.
