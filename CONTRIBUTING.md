# Contributing to Transcripted

Thanks for helping out.

Quick repo orientation before you jump in:

- `main` is the new Transcripted direction built from the Draft codebase
- the old standalone Transcripted app is preserved on `legacy/transcripted-standalone`
  and `pre-draft-takeover-2026-04-06`
- some folders and local storage paths still use `Draft` names while the
  transition settles

The short version of the product story is simple: this repo is building a local
Mac app that captures spoken context and saves it in files your own tools and
agents can use.

## Development Setup

### Prerequisites

- macOS 14+
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
   bash build.sh
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

## Making Changes

### Branch Naming

Create a branch from `main` with a descriptive name:

```
feat/description     # New feature
fix/description      # Bug fix
docs/description     # Documentation only
refactor/description # Code refactoring
```

### Code Style

- Follow existing Swift conventions in the codebase
- Use `// MARK:` comments to organize sections within files
- Never do I/O, locks, or allocations inside CoreAudio real-time callbacks
- Keep `@MainActor` annotations correct (see Threading below)

### Architecture

The codebase is organized around the current app direction. Some folders still
carry `Draft` names, but they are part of the same product:

| Area | Directory | Responsibility |
|------|-----------|----------------|
| App shell + shared state | `Sources/` | app lifecycle, hotkeys, paths, shared state |
| Dictation flow | `Sources/Draft/` | dictation cleanup, formatting, Draft-named utilities still in use |
| Meeting capture | `Sources/Meeting/` | meeting recording, model warmup, transcript flow |
| UI | `Sources/UI/` | overlay, menubar, onboarding |
| Local inference | `Sources/Local/` | on-device MLX model integration |
| Shared transcription core | `Sources/TranscriptedCore/` | extracted meeting/transcription library |

`Sources/TranscriptedCore/` should stay a library boundary. Keep Draft app UI
types and app-specific behavior out of that module.

### Threading

Transcripted has strict threading rules due to CoreAudio's real-time requirements:

| Component | Thread | Notes |
|-----------|--------|-------|
| Session controllers + UI state | `@MainActor` | UI-bound state |
| Audio capture internals | `DispatchQueue` + `NSLock` | Real-time audio I/O |
| Local model access | actor / managed async tasks | serialized model use |
| CoreAudio I/O callbacks | real-time thread | **No I/O, locks, allocations, or ObjC calls** |

CoreAudio I/O callbacks run on real-time threads. Buffers are deep-copied before async dispatch — never processed in-place.

### Testing

Run the default test suite from the command line:

```bash
bash run-tests.sh
```

If you're changing meeting integration or `TranscriptedCore`, also run:

```bash
bash run-integration-smoke.sh
```

## Submitting a Pull Request

1. Make sure your code builds without warnings
2. Run the test suite
3. Keep PRs focused — one feature or fix per PR
4. Write a clear PR description explaining **what** changed and **why**
5. Link any related issues

## Reporting Bugs

Open a GitHub issue with:

- macOS version
- Steps to reproduce
- Expected vs actual behavior
- Relevant logs from `~/Library/Application Support/Draft/events.jsonl`

If the report is about the old standalone Transcripted app, please say that
explicitly so it can be triaged against the legacy ref instead of `main`.

## Questions?

Open a GitHub issue for questions or discussion. We're happy to help you get
oriented.
