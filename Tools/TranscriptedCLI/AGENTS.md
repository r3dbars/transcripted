# TranscriptedCLI

Standalone Swift package (`transcripted-cli`) for command-line access to saved Transcripted context, offline transcription, offline diarization, and headless meeting import. It does not build or run the app target. Flags and recipes live in [README.md](README.md).

Two audiences share one binary. Do not describe it as diarization-only or as retrieval-only.

## Build modes

Chosen at manifest time by env vars in `Package.swift`:

| Mode | Env | Commands | macOS |
|------|-----|----------|-------|
| Retrieval (default) | none | context commands, `build-info` | 14 |
| Basic audio | `TRANSCRIPTEDCLI_ENABLE_TRANSCRIPTION=1` or `TRANSCRIPTEDCLI_ENABLE_DIARIZATION=1` (either links the same bundle and enables both) | adds `transcribe`, `diarize`, `batch` | 14 |
| Meeting import | `TRANSCRIPTEDCLI_ENABLE_MEETING_IMPORT=1` | adds `import-audio`; links the shared `TranscriptedCore` pipeline | 26 |

- Audio modes need repo-level artifacts: run `bash build-deps.sh` from the repo root first. Without them the audio commands exit with that instruction.
- Never enable the Core import in the other modes or quietly raise their OS requirement.
- An explicit audio build request fails manifest evaluation if the module files or archive are missing. Never fall back silently to retrieval.
- The audio archive already contains `ArgumentParser` and `ArgumentParserToolInfo`. Audio targets must not also link SwiftPM's source-built parser product; explicit module-file mappings pick the prebuilt interfaces even when a retrieval build left older modules in the same build dir. Keep the remote package declaration and resolution pin for retrieval builds.
- After touching `Package.swift`, verify retrieval -> basic audio -> meeting import -> retrieval in one build directory (native SwiftPM and Swift Build layouts both).
- `BuildModeTests` checks expected/requested mode against compiled capabilities. CI sets `TRANSCRIPTEDCLI_EXPECT_BUILD_MODE` independently.

## Local context commands

`context-recent`, `context-search <query>`, `read-meeting <filename>`, `list-dictations`, `read-dictation <filename>`, `list-writing`, `read-writing <filename>`.

Directory resolution (shared with `Tools/TranscriptedMCP`, implemented in `Tools/TranscriptedCaptureKit`; change it there, never re-inline it in `ContextStore.swift`):

1. App-selected capture library: `~/Library/Application Support/Transcripted/mcp-directories.json` or the saved `transcriptSaveLocation` preference. Follow it before any default.
2. `~/Library/Application Support/Transcripted/captures/{meetings,dictations,writing}`
3. Legacy Draft exports with capture Markdown: `~/Library/Application Support/Draft/{meetings,dictations}/transcripts`
4. Older `~/Documents/Transcripted`

Overrides: `--data-dir`, `--meetings-dir`, `--dictations-dir`, `--writing-dir`, and `TRANSCRIPTED_DATA_DIR`, `TRANSCRIPTED_MEETINGS_DIR`, `TRANSCRIPTED_DICTATIONS_DIR`, `TRANSCRIPTED_WRITING_DIR`. With a meetings or dictations override and no writing override, no writing folder is read.

Output rules:

- `context-recent`, `context-search`, `list-dictations`, `list-writing` print a bare JSON array with `--json` when there are results. Zero results emit `{"results": [], "searched_directories": [...], "hint": "..."}`; text mode prints `No results. Searched: <dirs>` to stderr.
- `context-search --speaker` with `--kind all|dictation|writing` skips dictations and writing by design. Text mode notes it on stderr; `--json` wraps as `{"results": [...], "notes": [...]}`.
- `--count` is clamped to 1-50.
- `read-meeting --json` adds `recording`, `speakers`, `utterances` next to raw `markdown`. `read-dictation --json` adds `date` and `entries`. `read-writing --json` matches it, with `accepted_word_count` per entry and no `delivery`.
- Writing day files never read as meetings, even in a flat folder (`--data-dir` at one folder).
- Diagnostics go to stderr so piped stdout stays parseable. Keep it that way.
- `context-recent` is a mixed feed. For the latest meeting use `--kind meeting`.
- Direct file reads go through `CLIPathSecurity` so filenames cannot escape the resolved data roots.

## Offline audio commands

- `transcribe <media...>`: plain text (default), `--json`, or `--srt` with the local Parakeet model. Exists so coding agents can use the on-device model on arbitrary files. Audio decodes via `AVAudioFile`; MP4/MOV/M4V fall back to `AVAssetReader` and mix all tracks to mono. WebM/MKV are not decodable; the error suggests `ffmpeg`.
- `diarize <audio>`: RTTM or JSON. `batch <directory>`: diarize matching files. Default engine is Nemotron (`--diarization-engine app`), same as the app and `import-audio`. pyannote is `--diarization-engine pyannote` only. Both paths share `CLIDiarization.windowing` / `FluidAudioCompatibility.tunedOfflineDiarizerConfig()` so they cannot drift to different window counts.
- Model lookup order: `--models-dir`, the containing app's bundled models, standard installed `Transcripted.app` locations, shared FluidAudio cache (`~/Library/Application Support/FluidAudio/Models/`), then a one-time ~600MB download there (`--no-download` fails instead).
- Output formatting lives in dependency-free `TranscribeOutput.swift` so plain `swift test` covers it. Put new formatting there, not in the gated command.
- `transcribe` decodes whole files to 16kHz mono Float32 in memory, about 230MB per hour of audio.

## import-audio

Full meeting Markdown from local transcription and diarization, read-only recognition of eligible saved speakers, and optional retained audio.

- Writes to `CaptureLibraryResolver`'s first meeting directory, or `--output-dir`.
- Formats with `TranscriptSaver` but publishes through `MeetingImportPublisher`: exclusive, descriptor-relative writes, Markdown last as the commit marker. Do not call `TranscriptSaver.saveTranscript`: it can update app stats and has no cross-process no-clobber guarantee.
- `SpeakerDatabase` is only opened on a private job snapshot, never the live database. `SpeakerDatabaseSnapshot` uses SQLite read-only backup including WAL. `MeetingImportSpeakerMapping` applies the app's conservative naming policy with the active model's thresholds, omits temporary new profile IDs, and gives a stderr reason for every numbered speaker (from Core's `SpeakerNamingPolicy.silentNamingBlockers`).
- Voiceprint model and speaker database come from Core's `SpeakerVoiceprintSelection`, the rule the app's `SpeakerEmbedderFactory` uses too (`MeetingImportVoiceprint.swift`). Never hard-code a database filename or an allowed-model list here; the shared table `Tests/Fixtures/speaker-voiceprint-resolution.json` is asserted by Core, the app, and this package. The note date comes from Core's `ImportedRecordingDate`, shared with the app's "Transcribe a file".
- Deliberately absent: speaker learning/review, AI styling, app stats, failed-job UI.
- Library prints are routed to stderr (`ImportAudioProcess.swift`) so they cannot corrupt the receipt. SIGINT/SIGTERM cancel cooperatively.
- Keep diagnostics on stderr, input audio read-only, and test libraries/databases outside real app data.

## Files

All under `Sources/TranscriptedCLI/`:

| File | Owns |
|------|------|
| `TranscriptedCLI.swift` | `@main` root, subcommand registration |
| `ContextCommands.swift`, `ContextStore.swift`, `ContextModels.swift` | Context commands, loading/filtering, Codable models |
| `CLIPathSecurity.swift` | Path validation for direct reads |
| `TranscribeCommand.swift`, `TranscribeMediaLoader.swift`, `TranscribeOutput.swift` | Transcribe command, AVFoundation decode, formatting |
| `CLIModelPaths.swift` | Containing-app-first model lookup, relocated apps, symlinked helper invocation |
| `DiarizeCommand.swift`, `BatchCommand.swift`, `ConfigLoader.swift`, `RTTMWriter.swift`, `CLIDiarization.swift`, `CLIDiarizationService.swift` | Diarization commands, shared engine/windowing, JSON-to-`OfflineDiarizerConfig`, RTTM output. Default engine is the app's (Nemotron); pyannote is `--diarization-engine pyannote`. |
| `BuildInfoCommand.swift` | Read-only compiled-capability JSON for packaging validation |
| `ImportAudioCommand.swift`, `ImportAudioProcess.swift` | `import-audio` options, validation, stdout routing, signals |
| `MeetingImportWorkflow.swift` | Input validation, private scratch job, WAV decode, model resolution, Core run |
| `MeetingImportPublisher.swift` | No-clobber publish, returns `MeetingImportReceipt` |
| `MeetingImportVoiceprint.swift` | Voiceprint model + speaker DB choice (via Core's `SpeakerVoiceprintSelection`), model loading and fallback |
| `MeetingImportSpeakerMapping.swift`, `SpeakerDatabaseSnapshot.swift` | Silent-recognition policy, numbered-speaker reasons, `--name-likely-speakers`, read-only DB snapshot |

## Test

```bash
cd Tools/TranscriptedCLI
swift build && swift test
TRANSCRIPTEDCLI_ENABLE_MEETING_IMPORT=1 swift test    # full mode
./.build/debug/transcripted-cli context-recent --kind meeting --count 3
```

- Plain `swift test` covers the context resolver, `ContextStore`, writing context, transcribe output, build mode, model paths, and the import command/publisher/snapshot seams (`Tests/TranscriptedCLITests/`).
- `MeetingImportWorkflowTests`, `MeetingImportSpeakerMappingTests`, and `ImportAudioExecutableE2ETests` compile only with `TRANSCRIPTEDCLI_ENABLE_MEETING_IMPORT=1`; `ConfigLoaderTests` is partly behind the diarization flag.
- Opt-in real-executable/model tests and synthetic audio generation are in README.md.
- Verify changes here independently of the app build.

## Packaging

App builds ship a release, meeting-import-mode binary at `Transcripted.app/Contents/Helpers/transcripted-cli`, signed by the nested-helper signing loop. No PATH shim is installed; use the absolute path.

- Packaging runs `build-info` to reject stale or incomplete capabilities before signing. It never loads models, reads recordings, or touches the network.
- `transcribe` and `import-audio` search their containing app's Resources before installed apps or caches, so a relocated bundle works.
- Verify with `bash Tests/BuildDependencies/CLIPackagingTests.sh`, the resolver tests, and a real offline import from the relocated packaged executable.
