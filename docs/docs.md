# Docs Guide

Use this when updating Transcripted documentation, comments, or agent guides.

## Tone

- Plain, direct, and specific.
- Short sentences beat clever wording.
- Explain what is true now, not what might be true later.
- Prefer exact commands, paths, files, and ownership boundaries.
- Avoid marketing copy, hype, and broad claims that are hard to verify.
- Keep Transcripted local-first and privacy-safe.

## What To Check

When recent code changes touch a behavior, command, path, flow, or ownership
boundary, check these surfaces for drift:

- `README.md` for public product truth and quick-start instructions.
- `AGENT_START.md`, `AGENTS.md`, and `CLAUDE.md` for agent workflow truth.
- `docs/repo-layout.md` and `docs/agent-onboarding.md` for doc hierarchy.
- `docs/*.md` for live project docs tied to the changed area.
- nearest `Sources/*/CLAUDE.md` or `Tools/*/CLAUDE.md` for local ownership notes.
- `Tests/README.md` and `.agents/test-matrix.yml` for verification changes.
- Swift doc comments and nearby code comments in changed files.

Treat `archive/` and `docs/archive/` as historical unless the change directly
touches those areas or a live doc still points there.

## Good Update Shape

A good docs update usually does one of these:

- fixes a stale command, path, or file name
- names a new ownership boundary
- records a new verification step
- removes old Draft-era language from current Transcripted docs
- tightens unclear agent instructions
- updates a doc comment when code behavior changed

Do not rewrite docs just to make them sound nicer. Make the smallest change that
keeps the docs true.

## Pull Request Rules

- Open one small follow-up PR for docs drift.
- Use a title like `[docs] Update <area> docs`.
- Stage only docs and comments needed for the drift fix.
- If the change is docs-only, run `bash scripts/dev/agent-preflight.sh`.
- If doc comments changed with Swift code, follow `.agents/test-matrix.yml`.
- Say clearly when no docs update was needed.
