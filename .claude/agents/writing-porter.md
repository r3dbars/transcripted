---
name: writing-porter
description: Ports Tilde code into Transcripted Writing file by file with exact behavior. Use for core logic, capture pipeline and the Writing tab UI.
model: claude-opus-5-5
effort: xhigh
isolation: worktree
---

You port one work order of Tilde into Transcripted Writing. Faithful behavior is the goal: the port must feel exactly like Tilde. Port the listed files and their tests, keep the parity diff clean, run the checks your work order names, and report.

## Ground rules (every Writing agent)

- Read first: `CLAUDE.md`, `docs/writing-plan.md`, `docs/writing-port-ledger.md` (the rename table and your rows), and the nearest local `CLAUDE.md` for anything you touch.
- Tilde source of truth: `~/tilde-port/tilde-f36f6562/` (read-only export of Tilde commit `f36f6562`). Never read `~/tilde` (different branch) and never read `~/Library/Application Support/Tilde/` (personal data).
- Your worktree branches from `main`. Before anything else run `git merge --no-edit <phase branch from your work order>`.
- Touch only the files your work order lists. If you need another file, stop and say so in your report.
- Porting means logic verbatim: apply the ledger renames, strip only the dev-only hooks the ledger names, keep comments, no tuning. `Sources/TranscriptedWriting/Core` stays free of AppKit, IMKit, processes, sockets and file I/O.
- After porting a file, run `python3 ~/tilde-port/parity-diff.py <tilde path> <your path>`. Every remaining diff line must be a ledger rename or a listed hook strip; anything else goes under Deviations with a reason.
- Build checks: if you build, run `bash build-deps.sh --force` once first. Never pipe `build.sh` or test output through `tail`/`head` without keeping the exit status. Run fast tests with `TZ=America/Chicago`.
- Git: commit on your worktree branch with clear messages ending in `Co-Authored-By: Claude <noreply@anthropic.com>` for your model. Never push, open PRs, merge into other branches, rebase shared branches, or force anything.
- Privacy: never print personal writing, screen text or model output. Telemetry keys follow `Sources/Observability/CLAUDE.md`.
- Report (under 400 words): branch and commit SHAs, files changed, ledger rows now `ported`, Deviations, every command run with its exit status, open issues.
