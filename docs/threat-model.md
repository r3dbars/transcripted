# Transcripted threat model

Read by Codex security reviews (set as the threat-model path in Codex's code review settings) and by anyone reviewing a change for security. `SECURITY.md` is the public policy; this file is the reviewer's map. Keep it short and true to the code.

## What we protect

In order of harm if it leaks or breaks:

1. **What the user said and typed.** Meeting audio, dictation audio, transcripts, Writing captures, speaker names and voiceprints (`speakers.sqlite`), meeting titles. All of it stays on the Mac unless the user sends it somewhere.
2. **Secrets the user typed.** Passwords, one-time codes, card numbers and API keys that pass through Writing capture. `WritingSecretScrubber` removes them before a day file is written.
3. **The user's other apps.** Transcripted holds Microphone, System Audio Recording, Accessibility and Calendar permissions, and paste-back types into other apps. Code that gets into the app inherits all of that.
4. **The update channel.** Sparkle EdDSA signing key, the appcast, Developer ID signing and notarization. Whoever controls these ships code to every user.
5. **The repo and CI.** The `main` branch, the self-hosted Mac runner, repo secrets, and the auto-merge gate. The repo is public.

## Trust boundaries

| Boundary | What crosses it | Control |
|---|---|---|
| Mac → Sentry, PostHog | crash and usage events | Allowlisted events and keys, sanitizers in `Sources/Observability/`, key-name drop list (`check-telemetry-keys.py`), separate user switches. Contract: `docs/privacy-first-observability.md` |
| Mac → Hugging Face | model downloads | huggingface.co only, no mirror fallback, SHA-256 check on LFS weights. Non-LFS files are not hash-pinned (known gap) |
| Mac ← GitHub (Sparkle) | app updates | EdDSA signature against the key embedded in the app |
| Other local apps → MCP server | read access to saved captures | `Tools/TranscriptedMCP` is read-only stdio with no per-caller auth: launching it grants read access to every capture |
| ChatGPT companion → app | context, meeting controls, live text | Unix socket in a `0700` directory, socket and connection file `0600`, rotating token never logged or returned by a tool. Off until enabled; controls and live sharing are separate permissions; live text needs a per-meeting switch |
| App → other apps | paste-back keystrokes, Auto Enter | Accessibility permission; pastes only the user's own dictation |
| GitHub issues and PR comments → agents | task text | Issue runner reads only `allowed_authors` and filtered operator feedback (`WORKFLOW.md`), never raw comments |
| Fork PRs → CI | untrusted code | Fork PRs never run on the owner's Mac (`pick-ci-runner.py`, `mac-runner.sh` job hook); Mac jobs run in throwaway VMs |
| Agent PRs → `main` | code without the owner's review | Auto-merge gate lanes and `deny_always` (`.agents/auto-merge-lanes.json`), required checks, Codex review, red-main stop |

## Known weak spots (by design, for now)

- The app is not sandboxed and has library validation off, because the ML stack ships dylibs with mixed signing. User-level malware that writes into the app bundle inherits its permissions. Don't widen this.
- The MCP server has no caller authentication. Don't add write tools to it without adding auth.
- Non-LFS model files aren't hash-pinned.

## What a reviewer should flag as high severity

- Any path where transcript text, audio or audio file paths, meeting titles, speaker names, emails, tokens, absolute paths, raw URLs or raw device names can reach Sentry, PostHog, logs shipped off the device, or the network. That includes new analytics properties, new Sentry context or breadcrumbs, and error messages that embed user content.
- New network destinations, or any non-HTTPS endpoint.
- Changes that weaken the companion socket: file modes, token handling, a token in a log or tool result, or capabilities on by default.
- New MCP tools that write, delete or run commands, or that read outside the capture library.
- Writing capture changes that let secrets through: scrubber rules removed or loosened, secure-input or password-manager checks bypassed.
- New entitlements, or loosening `config/entitlements/*` or `config/security/nightly-security-manifest.json`.
- Model downloads from a new host, or skipping digest checks.
- Updater changes: appcast URL, signature checks, the embedded public key.
- CI changes that let fork code, `pull_request_target`, or untrusted input reach the self-hosted Mac or repo secrets. Secrets echoed into logs.
- Changes to `.agents/auto-merge-lanes.json` or `scripts/ops/auto-merge-gate.py` that widen what merges without the owner.
- Deleting or writing files outside the root the code owns (path traversal, symlinks in the capture library).
- Agent instructions (`AGENTS.md`, `WORKFLOW.md`, skills) that tell an agent to act on raw issue or PR comment text.

## Out of scope

- An attacker who already runs code as the user. They already have what Transcripted has.
- Physical access to an unlocked Mac.
- Local models giving wrong or offensive transcripts. That's a quality bug, not a security one.
