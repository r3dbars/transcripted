# TranscriptedCaptureKit

`Tools/TranscriptedCaptureKit/` is the shared library behind the standalone tools. It is the single source of truth for:

- capture-library directory resolution (env overrides, app manifest, `transcriptSaveLocation` preference, legacy Draft / `~/Documents/Transcripted` fallback) for meetings, dictations, and writing
- capture-Markdown detection (`looksLikeCaptureMarkdown`, `captureKind(of:)`, directory probing, frontmatter title extraction)
- capture-Markdown parsing (meeting transcripts, dictation day files, and writing day files)
- structured meeting-summary parsing (Decisions / Action Items / Open Questions)

Both `Tools/TranscriptedCLI` and `Tools/TranscriptedMCP` depend on it via a relative `.package(path: "../TranscriptedCaptureKit")` dependency. Before this package existed, that logic was duplicated nearly verbatim in both tools and had already drifted; do not re-inline it.

## Files

| File | Purpose |
|------|---------|
| `Package.swift` | Library-only Swift package manifest (no external dependencies) |
| `Sources/TranscriptedCaptureKit/CaptureLibraryPathSafety.swift` | Pure-Foundation check for whether a directory is safe to use as a capture-library / save-path root (rejects non-absolute paths, `..` traversal, `/`, forbidden system prefixes). Byte-identical synced copy of `Sources/Support/CaptureLibraryPathSafety.swift` and `Sources/TranscriptedCore/Services/CaptureLibraryPathSafety.swift` — edit all three together |
| `Sources/TranscriptedCaptureKit/CaptureLibraryResolver.swift` | `CaptureLibraryResolver.resolve(...)` → `ResolvedCaptureDirectories` (meeting dirs, dictation dirs, writing dirs, optional shared data root, winning resolution rule + legacy-fallback flag). Writing follows `TRANSCRIPTED_WRITING_DIR`, the manifest's optional `writingDirectory`, then `<library>/writing`; a meetings/dictations override without a writing override reads no writing folder |
| `Sources/TranscriptedCaptureKit/CaptureMarkdown.swift` | Capture-Markdown detection (`captureKind(of:)`: `Writing_` / `capture_type: writing_day` first, then `Dictations_`, then any frontmatter file as a meeting candidate) and frontmatter `title:` extraction |
| `Sources/TranscriptedCaptureKit/CaptureMarkdownParser.swift` | Frontmatter, meeting transcript, dictation day, and writing day parsing into `ParsedMeetingCapture` / `ParsedDictationDayCapture` / `ParsedWritingDayCapture`. Dictation and writing entries share one day-file section parser; each flavor recognizes only its own metadata keys |
| `Sources/TranscriptedCaptureKit/CapturePathSecurity.swift` | Guards direct file reads against path traversal, symlink escapes, and out-of-root paths when resolving a caller-supplied filename against a trusted base directory. Canonical logic behind `TranscriptedCLI`'s `CLIPathSecurity` and `TranscriptedMCP`'s `PathSecurity` local wrappers |
| `Sources/TranscriptedCaptureKit/CaptureSummaryParser.swift` | Structured summary parsing into `ParsedMeetingSummary` (Decisions / Action Items with owner / Open Questions); understands inline transcript summaries and generated `meeting_summary` sidecars. Originally ported from the app's `RecentMeetingSummaryPreviewParser` section logic (that app type no longer exists in `Sources/`) |

## Test Files

| File | Purpose |
|------|---------|
| `Tests/TranscriptedCaptureKitTests/CaptureLibraryResolverTests.swift` | Resolution precedence: shared data dir, per-kind overrides, manifest, preference, legacy fallback, symlinked legacy roots |
| `Tests/TranscriptedCaptureKitTests/CaptureMarkdownParserTests.swift` | Legacy + styled transcript parsing, speaker metadata, durations, dictation entries, detection helpers |
| `Tests/TranscriptedCaptureKitTests/CaptureSummaryParserTests.swift` | Inline + sidecar summary parsing, action-item owner extraction, placeholder/None-found handling, frontmatter fallback |
| `Tests/TranscriptedCaptureKitTests/WritingDayParserTests.swift` | Writing day parsing against the format contract example (field for field, byte-exact text), missing `Bundle ID`, unknown keys, `captureKind(of:)` |
| `Tests/TranscriptedCaptureKitTests/CaptureLibraryWritingResolverTests.swift` | Writing-folder resolution: default, env/arg override, shared data dir, manifest with and without `writingDirectory`, preference, per-kind isolation |
| `Tests/TranscriptedCaptureKitTests/FrontmatterCorpusParityTests.swift` | Pins `CaptureMarkdownParser`'s frontmatter parsing against the shared `Tests/Fixtures/frontmatter-corpus` fixtures so it stays in equivalence with `TranscriptFrontmatter` and `TranscriptedMCP`'s `frontmatterBlock` parsers |

## Build and test

```bash
swift test --package-path Tools/TranscriptedCaptureKit
```

Changes here must also keep the consumers green (see `.agents/test-matrix.yml`):

```bash
swift test --package-path Tools/TranscriptedCLI
swift test --package-path Tools/TranscriptedMCP
bash run-e2e-smoke.sh
```

The e2e smoke matters because `scripts/entrypoints/run-e2e-smoke.sh` compiles this package with raw `swiftc` into a standalone module (`-emit-module` + static library) and links it into the smoke binary alongside MCP sources.

## Design rules

- No filesystem-layout opinions beyond resolution: parsers take Markdown content (plus the source URL for filename-derived fallbacks) and never write.
- `ParsedMeetingCapture` / `ParsedDictationDayCapture` carry the superset of fields both tools need; each tool maps them into its own output models (`CLIAgentTranscript`, `AgentTranscript`, ...). Add fields here rather than re-parsing in a tool.
- Keep this package dependency-free so the raw-`swiftc` smoke compile stays a two-liner.
- This package intentionally does not link into the app target.

## Gotchas

- Legacy candidate directories are only included when they actually contain capture Markdown; the directory root is symlink-resolved before enumeration (this was a CLI/MCP drift point — the resolved behavior is canonical now).
- Speaker metadata from frontmatter is channel-scoped: `channel: mic` maps to `mic_<rawId>`, `channel: system` maps to `system_<rawId>`, and older channelless metadata is treated as system metadata.
- Dictation and writing day entries are returned sorted ascending by `createdAt`.
- The writing day-file format is specified in `docs/capture-format.md` ("Writing day files"); keep this parser, `WritingDayParserTests`, and that doc in step.
