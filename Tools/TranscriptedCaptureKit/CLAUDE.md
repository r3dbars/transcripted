# TranscriptedCaptureKit

`Tools/TranscriptedCaptureKit/` is the shared library behind the standalone tools. It is the single source of truth for:

- capture-library directory resolution (env overrides, app manifest, `transcriptSaveLocation` preference, legacy Draft / `~/Documents/Transcripted` fallback)
- capture-Markdown detection (`looksLikeCaptureMarkdown`, directory probing, frontmatter title extraction)
- capture-Markdown parsing (meeting transcripts and dictation day files)

Both `Tools/TranscriptedCLI` and `Tools/TranscriptedMCP` depend on it via a relative `.package(path: "../TranscriptedCaptureKit")` dependency. Before this package existed, that logic was duplicated nearly verbatim in both tools and had already drifted; do not re-inline it.

## Files

| File | Purpose |
|------|---------|
| `Package.swift` | Library-only Swift package manifest (no external dependencies) |
| `Sources/TranscriptedCaptureKit/CaptureLibraryResolver.swift` | `CaptureLibraryResolver.resolve(...)` → `ResolvedCaptureDirectories` (meeting dirs, dictation dirs, optional shared data root) |
| `Sources/TranscriptedCaptureKit/CaptureMarkdown.swift` | Capture-Markdown detection and frontmatter `title:` extraction |
| `Sources/TranscriptedCaptureKit/CaptureMarkdownParser.swift` | Frontmatter, meeting transcript, and dictation day parsing into `ParsedMeetingCapture` / `ParsedDictationDayCapture` |

## Test Files

| File | Purpose |
|------|---------|
| `Tests/TranscriptedCaptureKitTests/CaptureLibraryResolverTests.swift` | Resolution precedence: shared data dir, per-kind overrides, manifest, preference, legacy fallback, symlinked legacy roots |
| `Tests/TranscriptedCaptureKitTests/CaptureMarkdownParserTests.swift` | Legacy + styled transcript parsing, speaker metadata, durations, dictation entries, detection helpers |

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
- The app target has its own scanner (`Sources/TranscriptedCore/Storage/TranscriptScanner.swift`); this package intentionally does not link into the app.

## Gotchas

- Legacy candidate directories are only included when they actually contain capture Markdown; the directory root is symlink-resolved before enumeration (this was a CLI/MCP drift point — the resolved behavior is canonical now).
- Speaker metadata from frontmatter is matched by `system_<rawId>` or unique normalized display name for all speakers, including mic speakers.
- Dictation day entries are returned sorted ascending by `createdAt`.
