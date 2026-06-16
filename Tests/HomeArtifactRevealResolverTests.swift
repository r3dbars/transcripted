import Foundation

func testHomeArtifactRevealResolver() {
    runSuite("HomeArtifactRevealResolver reveals an existing file directly") {
        withTemporaryRevealLibrary { root in
            let url = root.appendingPathComponent("2026-06-13 Quick notes.md")
            try Data("x".utf8).write(to: url)

            assertEqual(
                HomeArtifactRevealResolver.resolve(candidateURLs: [url]),
                .reveal([url]),
                "an existing transcript should be revealed at its own path"
            )
        }
    }

    runSuite("HomeArtifactRevealResolver keeps only the candidates that still exist") {
        withTemporaryRevealLibrary { root in
            let present = root.appendingPathComponent("microphone.m4a")
            let missing = root.appendingPathComponent("system_audio.m4a")
            try Data("mic".utf8).write(to: present)

            assertEqual(
                HomeArtifactRevealResolver.resolve(candidateURLs: [missing, present]),
                .reveal([present]),
                "missing candidates should drop out, existing ones should reveal"
            )
        }
    }

    runSuite("HomeArtifactRevealResolver rematches retained audio recompressed from WAV to M4A") {
        withTemporaryRevealLibrary { root in
            // The row was scanned while audio was still WAV; background
            // compression then rewrote it to M4A under the same stem.
            let staleWav = root.appendingPathComponent("system_audio.wav")
            let liveM4a = root.appendingPathComponent("system_audio.m4a")
            try Data("compressed".utf8).write(to: liveM4a)

            assertEqual(
                HomeArtifactRevealResolver.resolve(candidateURLs: [staleWav]),
                .reveal([liveM4a]),
                "a stale .wav path should rematch the recompressed .m4a sibling by stem"
            )
        }
    }

    runSuite("HomeArtifactRevealResolver falls back to the enclosing directory for a renamed transcript") {
        withTemporaryRevealLibrary { root in
            // A post-save restyle renamed the transcript, so the row's recorded
            // stem no longer exists, but the meetings folder still does.
            let renamedAway = root.appendingPathComponent("Untitled meeting.md")

            assertEqual(
                HomeArtifactRevealResolver.resolve(candidateURLs: [renamedAway]),
                .reveal([root]),
                "a vanished transcript should fall back to revealing its meetings folder"
            )
        }
    }

    runSuite("HomeArtifactRevealResolver reports unavailable when nothing on disk matches") {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("build/home-artifact-reveal-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        // Deliberately never created on disk.
        let ghost = root.appendingPathComponent("gone.md")

        assertEqual(
            HomeArtifactRevealResolver.resolve(candidateURLs: [ghost]),
            .unavailable,
            "a path whose enclosing directory is also gone should report unavailable"
        )
    }

    runSuite("HomeArtifactRevealResolver reports unavailable for an empty candidate list") {
        assertEqual(
            HomeArtifactRevealResolver.resolve(candidateURLs: []),
            .unavailable,
            "no candidates means nothing to reveal"
        )
    }
}

private func withTemporaryRevealLibrary(_ body: (URL) throws -> Void) {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent("build/home-artifact-reveal-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)

    do {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try body(root)
    } catch {
        assertionFailure("temporary reveal fixture failed: \(error)")
    }
    try? fm.removeItem(at: root)
}
