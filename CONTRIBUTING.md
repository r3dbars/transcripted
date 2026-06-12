# Contributing to Transcripted

Transcripted is a local Mac app that turns meetings and dictation into
structured voice artifacts people and agents can both use.

Quick repo orientation before you jump in:

- `main` is the current Transcripted product built from the Draft codebase
- the old standalone Transcripted app is preserved on `legacy/transcripted-standalone`
  and `pre-draft-takeover-2026-04-06`
- persisted app paths now default to Transcripted-named storage, though some helper names and standalone-tool fallbacks still reflect the Draft transition
- coding agents should start with `AGENT_START.md`, then follow `AGENTS.md`

In public docs and user-facing copy, prefer concrete present-tense claims about
what the product does today. The broader "audio as a context layer" thesis is
real, but it should be earned through proof rather than stated as if the future
state already exists.

## Development Setup

### Prerequisites

- macOS 26+
- Xcode command line tools
- Apple Silicon

### Getting Started

1. Fork the repo and clone your fork:

   ```bash
   git clone https://github.com/YOUR_USERNAME/transcripted.git
   cd transcripted
   ```

2. Build dependencies and the app:

   ```bash
   bash build-deps.sh
   bash build.sh --no-open
   ```

3. Run the test suite:

   ```bash
   bash run-tests.sh
   ```

If you touch meeting integration or `TranscriptedCore`, also run:

```bash
bash run-integration-smoke.sh
```

On first launch, models may download from HuggingFace if they are not already
cached locally.

Build note: `build.sh` is the authoritative app build and uses raw `swiftc`.
`Package.swift` exists for `TranscriptedCore` compilation and testing, but it
is not the main app build.

For the current script surface and legacy helpers, see `scripts/README.md`.
For the active repo map and directory responsibilities, see `docs/repo-layout.md`.
For the path-to-verification map used by agents, see `.agents/test-matrix.yml`
or run:

```bash
scripts/dev/agent-preflight.sh
```

## Product Framing

When you change README copy, onboarding text, or public docs, keep these rules
in mind:

- lead with the concrete product: local dictation and local meeting capture
- treat "agent-ready artifacts" as a present-tense capability
- treat "ambient context layer" as vision language, not current product language
- be precise about what stays local and what may still contact external services
- explain legacy `Draft` paths as compatibility behavior, not as a second product

## Making Changes

### Branch Naming

Create a branch from `main` with a descriptive name:

```text
feat/description
fix/description
docs/description
refactor/description
```

### Code Style

- Follow existing Swift conventions in the codebase
- Use `// MARK:` comments to organize sections within files
- Never do I/O, locks, or allocations inside CoreAudio real-time callbacks
- Keep `@MainActor` annotations correct

### Architecture

The codebase is organized around the current Transcripted app:

| Area | Directory | Responsibility |
|------|-----------|----------------|
| App entry + state | `Sources/` | app lifecycle, hotkeys, paths, shared state |
| Dictation capture and storage | `Sources/Speech/`, `Sources/Dictation/`, `Sources/Capture/` | speech capture, trigger routing, saved dictation transcripts |
| Meeting pipeline | `Sources/Meeting/` | meeting recording, model warmup, transcript flow |
| UI | `Sources/UI/` | grouped app surfaces: `Overlay/`, `MenuBar/`, `Settings/`, `Shared/` |
| Shared meeting core | `Sources/TranscriptedCore/` | extracted meeting/transcription library and agent artifacts |

Some internal folders still use `Draft` naming while the repo and product are
being aligned publicly around Transcripted. Treat those as implementation
details unless a change specifically affects compatibility paths.

For the canonical root and directory map, see `docs/repo-layout.md`.

### Artifact-First Principle

Transcripted prefers durable local outputs over opaque app-only state.

That means changes should preserve or improve:

- readable Markdown outputs
- structured JSON sidecars and indexes
- stable storage paths
- the ability for external agents to consume saved artifacts directly

### Threading

Transcripted has strict threading rules due to CoreAudio's real-time
requirements:

| Component | Thread | Notes |
|-----------|--------|-------|
| Session controllers + UI state | `@MainActor` | UI-bound state |
| Audio capture internals | `DispatchQueue` + `NSLock` | Real-time audio I/O |
| CoreAudio I/O callbacks | real-time thread | **No I/O, locks, allocations, or ObjC calls** |

CoreAudio I/O callbacks run on real-time threads. Buffers are deep-copied
before async dispatch, never processed in-place.

### Testing

Run the default test suite from the command line:

```bash
bash run-tests.sh
```

If you're changing meeting integration or `TranscriptedCore`, also run:

```bash
bash run-integration-smoke.sh
```

`run-tests.sh` is curated rather than discovery-based. If you add a new root
fast-test file, register it in `Tests/FastTests.manifest`. Update
`run-tests.sh` only when the compiled source list or runner behavior changes.

## Submitting a Pull Request

1. Make sure your code builds without warnings
2. Run the relevant test suite
3. Keep PRs focused, one feature or fix per PR
4. Explain both what changed and why it matters
5. Call out privacy, storage-path, or migration implications when relevant
6. Link any related issues

## Reporting Bugs

Open a GitHub issue with:

- macOS version
- steps to reproduce
- expected vs actual behavior
- whether the issue affects dictation, meetings, or agent artifacts
- relevant logs from `~/Library/Application Support/Transcripted/logs/events.jsonl` or `~/Library/Application Support/Transcripted/logs/debug.log`

If your machine uses a custom capture library or you are reproducing against
legacy Draft-era artifacts, mention that in the report.

## Questions?

Open a GitHub issue for questions or discussion.
