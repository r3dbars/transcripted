# TranscriptedCaptureKit

Shared, dependency-free library behind `Tools/TranscriptedCLI` and `Tools/TranscriptedMCP` (both depend on it via `.package(path: "../TranscriptedCaptureKit")`). It is the single source of truth for:

- capture-library directory resolution (env overrides, app manifest, `transcriptSaveLocation`, legacy Draft / `~/Documents/Transcripted` fallback) for meetings, dictations, writing
- capture-Markdown detection, frontmatter title extraction, and parsing (meeting transcripts, dictation day files, writing day files)
- structured meeting-summary parsing (Decisions / Action Items / Open Questions)

That logic used to be duplicated in both tools and drifted. Do not re-inline it.

## Files

All under `Sources/TranscriptedCaptureKit/`:

- `CaptureLibraryPathSafety.swift` - is a directory safe as a capture-library root (absolute, no `..`, not `/`, no forbidden system prefix). Byte-identical copy of `Sources/Support/CaptureLibraryPathSafety.swift` and `Sources/TranscriptedCore/Services/CaptureLibraryPathSafety.swift`. Edit all three together.
- `CaptureLibraryResolver.swift` - `resolve(...)` returns `ResolvedCaptureDirectories` (meeting/dictation/writing dirs, optional shared data root, winning rule, legacy-fallback flag). Writing follows `TRANSCRIPTED_WRITING_DIR`, the manifest's optional `writingDirectory`, then `<library>/writing`. A meetings or dictations override without a writing override reads no writing folder. Also owns `legacyCaptureDirectories`, which `TranscriptedQA` reuses.
- `CaptureMarkdown.swift` - `captureKind(of:)` (`Writing_` / `capture_type: writing_day` first, then `Dictations_`, then any frontmatter file as a meeting candidate) and `title:` extraction.
- `CaptureDayFileModels.swift` - `ParsedDictationDayCapture` / `ParsedWritingDayCapture`. A dictation entry's optional `audioRelativePath` is its `Audio:` line, relative to the dictations folder. The file may have aged out (dictation audio retention defaults to 30 days and can be Off, 7 days, 30 days, or Forever), so never assume it exists.
- `CaptureMarkdownParser.swift` - frontmatter, meeting, dictation-day, writing-day parsing. Dictation and writing share one day-file section parser; each flavor recognizes only its own keys (only dictation reads `Audio:`).
- `CapturePathSecurity.swift` - guards caller-supplied filenames against traversal, symlink escape, and out-of-root paths. Canonical logic behind the CLI's `CLIPathSecurity` and MCP's `PathSecurity` wrappers.
- `CaptureSummaryParser.swift` - `ParsedMeetingSummary` from inline transcript summaries and generated `meeting_summary` sidecars.

Tests are in `Tests/TranscriptedCaptureKitTests/`, one file per area: resolver and writing-resolver precedence, parser, summary parser, `WritingDayParserTests` (format-contract example, byte-exact text), `TranscriptTimestampCompatibilityTests` (`MM:SS` and `H:MM:SS` clocks, raw and styled), and `FrontmatterCorpusParityTests` (pins the parser to `Tests/Fixtures/frontmatter-corpus`, shared with `TranscriptFrontmatter` and MCP's `frontmatterBlock`).

## Build and test

```bash
swift test --package-path Tools/TranscriptedCaptureKit
swift test --package-path Tools/TranscriptedCLI
swift test --package-path Tools/TranscriptedMCP
bash run-e2e-smoke.sh
```

The e2e smoke matters: `scripts/entrypoints/run-e2e-smoke.sh` compiles `Sources/TranscriptedCaptureKit/*.swift` with raw `swiftc` (`-emit-module`) and links it into the smoke binary. See `.agents/test-matrix.yml`.

## Rules

- Parsers take Markdown content (plus the source URL for filename-derived fallbacks) and never write. No filesystem-layout opinions beyond resolution.
- `ParsedMeetingCapture` and the day-capture types carry the superset of fields both tools need; each tool maps them to its own output models. Add fields here rather than re-parsing in a tool.
- Stay dependency-free so the raw-`swiftc` compile stays simple. Do not link this into the app target.

## Gotchas

- Legacy candidate directories are included only when they contain capture Markdown, and the root is symlink-resolved before enumeration (a former CLI/MCP drift point; this behavior is canonical).
- Frontmatter speaker metadata is channel-scoped: `channel: mic` maps to `mic_<rawId>`, `channel: system` to `system_<rawId>`, channelless legacy metadata counts as system.
- Dictation and writing entries come back sorted ascending by `createdAt`.
- The writing day-file format lives in `docs/capture-format.md` ("Writing day files"). Keep the parser, `WritingDayParserTests`, and that doc in step.
