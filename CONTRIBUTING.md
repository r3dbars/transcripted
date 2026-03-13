# Contributing to Transcripted

Thanks for your interest in contributing to Transcripted! This guide will help you get set up and contributing quickly.

## Development Setup

### Prerequisites

- macOS 14.2+ (Sonoma)
- Xcode 15+
- Swift 5.9+

### Getting Started

1. Fork the repo and clone your fork:
   ```bash
   git clone https://github.com/YOUR_USERNAME/transcripted.git
   cd transcripted
   ```

2. Open the project in Xcode:
   ```bash
   open Transcripted.xcodeproj
   ```

3. Set your **Development Team** in the Signing & Capabilities tab — the project has a placeholder team ID that you'll need to replace with your own.

4. Build and run (Cmd+R).

5. On first launch, models will download from HuggingFace (~600MB for Parakeet, plus Sortformer). This requires an internet connection.

### FluidAudio

The FluidAudio static library (`fluidaudio-libs/libFluidAudioAll.a`) is pre-built and included in the repo. If you need to rebuild it:

```bash
./build-fluidaudio.sh
```

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
- Keep `@MainActor` annotations correct — see `CLAUDE.md` for which classes require it
- Never do I/O, locks, or allocations inside CoreAudio real-time callbacks

### Architecture

The codebase is organized into layers:

| Layer | Directory | Responsibility |
|-------|-----------|---------------|
| Core | `Transcripted/Core/` | Audio capture, transcription pipeline, data persistence |
| Services | `Transcripted/Services/` | ML models (Parakeet, Sortformer, Qwen), speaker database |
| UI | `Transcripted/UI/` | Floating panel, settings window |
| Design | `Transcripted/Design/` | Design tokens, shared components |
| Onboarding | `Transcripted/Onboarding/` | First-run experience |

Each directory has a `CLAUDE.md` file documenting its internals, key types, and modification guidelines. Read the relevant one before making changes in that area.

### Testing

Run tests via Xcode (Cmd+U) or from the command line:

```bash
xcodebuild -project Transcripted.xcodeproj -scheme Transcripted test
```

If you're adding new functionality, please add tests where practical. Test files mirror the source structure under `TranscriptedTests/`.

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
- Relevant logs from `~/Library/Logs/Transcripted/app.jsonl`

## Questions?

Open a GitHub issue for questions or discussion. We're happy to help you get oriented in the codebase.
