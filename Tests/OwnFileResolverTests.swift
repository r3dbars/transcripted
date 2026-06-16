// Behavioral coverage for OwnFileResolver — the single resolver every Home /
// meeting own-file access routes through. These tests exercise real on-disk
// drift (moved / renamed / WAV→M4A recompressed / missing) in a temp directory,
// so a regression that re-introduces a silent dead click fails CI here.

import Foundation

private func makeResolverScratchDir(_ label: String) -> URL {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("own-file-resolver-tests", isDirectory: true)
        .appendingPathComponent(label, isDirectory: true)
    try? FileManager.default.removeItem(at: base)
    try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

private func writeFile(_ url: URL, _ contents: String = "x") {
    try? contents.data(using: .utf8)?.write(to: url)
}

// Directory enumeration on macOS returns `/private/var/...` for a `/var/...`
// temp URL, so compare URLs by their symlink-resolved path rather than raw value.
private func resolvedPath(_ url: URL) -> String {
    url.resolvingSymlinksInPath().path
}

private func revealedPaths(_ outcome: OwnFileResolver.RevealOutcome) -> [String]? {
    if case .reveal(let urls) = outcome { return urls.map(resolvedPath) }
    return nil
}

func testOwnFileResolver() {
    runSuite("OwnFileResolver - reveal-in-Finder drift tolerance") {
        // 1. Direct hit: the recorded path still exists.
        let dir = makeResolverScratchDir("reveal-direct")
        let transcript = dir.appendingPathComponent("2026-06-15 Standup.md")
        writeFile(transcript)
        assertEqual(
            OwnFileResolver.resolveForReveal(candidateURLs: [transcript]),
            .reveal([transcript]),
            "an existing recorded path should reveal directly"
        )

        // 2. Stem rematch: WAV recorded, on disk it became an M4A (same stem).
        let audioDir = makeResolverScratchDir("reveal-stem")
        let recordedWav = audioDir.appendingPathComponent("system_audio.wav")
        let actualM4a = audioDir.appendingPathComponent("system_audio.m4a")
        writeFile(actualM4a)
        assertEqual(
            revealedPaths(OwnFileResolver.resolveForReveal(candidateURLs: [recordedWav])),
            [resolvedPath(actualM4a)],
            "a recompressed WAV→M4A audio file should resolve by stem"
        )

        // 3. Enclosing-directory fallback: file renamed away with no stem match,
        //    but the meetings folder still exists. Revealing it beats a dead click.
        let folder = makeResolverScratchDir("reveal-folder")
        let renamedAway = folder.appendingPathComponent("Old Title.md")
        writeFile(folder.appendingPathComponent("Brand New Title.md"))
        assertEqual(
            OwnFileResolver.resolveForReveal(candidateURLs: [renamedAway]),
            .reveal([folder]),
            "a renamed transcript with no stem match should fall back to the enclosing folder"
        )

        // 4. Unavailable: even the enclosing directory is gone.
        let gone = makeResolverScratchDir("reveal-gone")
        let missingInMissingDir = gone
            .appendingPathComponent("subdir", isDirectory: true)
            .appendingPathComponent("transcript.md")
        assertEqual(
            OwnFileResolver.resolveForReveal(candidateURLs: [missingInMissingDir]),
            .unavailable,
            "nothing on disk (file and folder gone) should report unavailable so the caller surfaces an error"
        )

        // 5. Empty / blank candidate sets report unavailable, never a dead reveal.
        assertEqual(
            OwnFileResolver.resolveForReveal(candidateURLs: []),
            .unavailable,
            "an empty candidate set is unavailable"
        )

        // 6. De-duplication: the same existing file twice reveals once.
        let dedupDir = makeResolverScratchDir("reveal-dedup")
        let dupe = dedupDir.appendingPathComponent("note.md")
        writeFile(dupe)
        assertEqual(
            OwnFileResolver.resolveForReveal(candidateURLs: [dupe, dupe]),
            .reveal([dupe]),
            "duplicate candidates should reveal a single de-duplicated URL"
        )
    }

    runSuite("OwnFileResolver - open/read/play requires a real file") {
        // Direct hit returns the file.
        let dir = makeResolverScratchDir("open-direct")
        let transcript = dir.appendingPathComponent("2026-06-15 Standup.md")
        writeFile(transcript)
        assertEqual(
            OwnFileResolver.resolveExistingFile(candidateURLs: [transcript]),
            transcript,
            "an existing recorded file resolves directly for open/read"
        )

        // Stem rematch for a recompressed audio file.
        let audioDir = makeResolverScratchDir("open-stem")
        let recordedWav = audioDir.appendingPathComponent("microphone.wav")
        let actualM4a = audioDir.appendingPathComponent("microphone.m4a")
        writeFile(actualM4a)
        assertEqual(
            OwnFileResolver.resolveExistingFile(candidateURLs: [recordedWav]).map(resolvedPath),
            resolvedPath(actualM4a),
            "a recompressed audio file resolves by stem for playback"
        )

        // No directory fallback: you cannot open a folder as a transcript, so a
        // renamed-away file with only its folder left must resolve to nil.
        let folder = makeResolverScratchDir("open-no-dir-fallback")
        let renamedAway = folder.appendingPathComponent("Old Title.md")
        writeFile(folder.appendingPathComponent("Brand New Title.md"))
        assertNil(
            OwnFileResolver.resolveExistingFile(candidateURLs: [renamedAway]),
            "open/read must NOT fall back to the enclosing directory — it needs a real file"
        )

        // A candidate that is itself a directory is not a regular file.
        let dirCandidateParent = makeResolverScratchDir("open-dir-candidate")
        let subdir = dirCandidateParent.appendingPathComponent("bundle", isDirectory: true)
        try? FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        assertNil(
            OwnFileResolver.resolveExistingFile(candidateURLs: [subdir]),
            "a directory candidate must not resolve as an openable file"
        )

        // Genuinely missing file (folder gone too) → nil.
        let gone = makeResolverScratchDir("open-gone")
        let missing = gone
            .appendingPathComponent("subdir", isDirectory: true)
            .appendingPathComponent("x.md")
        assertNil(
            OwnFileResolver.resolveExistingFile(candidateURLs: [missing]),
            "a missing file with no folder should resolve to nil so the caller surfaces an error"
        )
    }

    runSuite("OwnFileResolver - multi-file resolution drops what is gone") {
        // mic.wav present as-is; system.wav recompressed to system.m4a; a third
        // file fully gone. Each resolves independently; the gone one is dropped.
        let dir = makeResolverScratchDir("multi")
        let mic = dir.appendingPathComponent("microphone.wav")
        writeFile(mic)
        let recordedSystemWav = dir.appendingPathComponent("system_audio.wav")
        let actualSystemM4a = dir.appendingPathComponent("system_audio.m4a")
        writeFile(actualSystemM4a)
        let goneFile = dir.appendingPathComponent("missing.wav")

        assertEqual(
            OwnFileResolver.resolveExistingFiles(candidateURLs: [mic, recordedSystemWav, goneFile]).map(resolvedPath),
            [resolvedPath(mic), resolvedPath(actualSystemM4a)],
            "multi-file resolution keeps the present + stem-rematched files and drops the missing one"
        )
    }
}
