mcp-directories.json manifest contract corpus
==============================================

`golden.json` pins the exact JSON shape Transcripted's app-side writer
(`FileManager.writeTranscriptedMCPDirectoriesManifestIfNeeded`, which encodes
`TranscriptedMCPDirectoriesManifest` in Sources/Support/TranscriptedStoragePaths.swift)
produces, and that TranscriptedCaptureKit's reader
(`CaptureDirectoryManifest` in
Tools/TranscriptedCaptureKit/Sources/TranscriptedCaptureKit/CaptureLibraryResolver.swift)
must be able to decode.

These two Codable structs are declared independently — one in the app target,
one in a standalone SPM package the app cannot depend on — so there is no
compiler-enforced guarantee that a field rename/add/remove on one side stays
in sync with the other. `golden.json` is the round-trip contract instead:

  - Tests/TranscriptedStoragePathsTests.swift writes a manifest with the app's
    real writer (fixed capture-library path and `updatedAt` so the output is
    deterministic) and asserts its JSON key set and decoded field values match
    this fixture.
  - Tools/TranscriptedCaptureKit/Tests/TranscriptedCaptureKitTests/CaptureLibraryResolverTests.swift
    stages this fixture as a temp home's `mcp-directories.json` and asserts
    `CaptureLibraryResolver.resolve()` reads it correctly end-to-end.

If either side's manifest shape changes, update `golden.json` (regenerate it
from the app's real writer, the same way it was first generated — see
`eebbcd7b`-style fixture corpora for the equivalent frontmatter pattern) and
both tests together, so drift between the two Codable declarations shows up
as a test failure instead of shipping silently. This mirrors the approach
already used for the three independent frontmatter parsers — see
Tests/Fixtures/frontmatter-corpus/README.txt.
