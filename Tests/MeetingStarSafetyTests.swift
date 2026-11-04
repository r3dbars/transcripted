import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

func testMeetingStarSafety() {
    runSuite("A completed star after an earlier retention scan preserves the current capture audio") {
        withStarSafetyFixture { fixture in
            do {
                let other = fixture.directory.appendingPathComponent("Other.md")
                try starSafetyMarkdown(id: UUID()).write(to: other, atomically: true, encoding: .utf8)
                let otherAudio = fixture.directory.appendingPathComponent("audio/Other_audio", isDirectory: true)
                try FileManager.default.createDirectory(at: otherAudio, withIntermediateDirectories: true)
                let fm = StarSafetyScanFileManager(first: fixture.audio.deletingLastPathComponent(), second: otherAudio,
                    secondTranscript: other) {
                    try applyStarSafety(true, at: fixture.transcript, id: fixture.id, directory: fixture.directory)
                }
                MeetingAudioStorageManager.pruneRetainedAudio(in: fixture.directory, retentionWindow: .sevenDays,
                    now: Date(timeIntervalSince1970: 1_800_000_000), fileManager: fm)
                assertTrue(fm.didInterleave, "the star happened after the first transcript was scanned")
                assertTrue(FileManager.default.fileExists(atPath: fixture.audio.path), "a completed star protects its audio")
            } catch { assertTrue(false, "synthetic interleaving failed: \(error)") }
        }
    }

    runSuite("A stale star action follows its capture identity after rename and filename reuse") {
        withStarSafetyFixture { fixture in
            do {
                let renamed = fixture.directory.appendingPathComponent("Renamed.md")
                try FileManager.default.moveItem(at: fixture.transcript, to: renamed)
                try starSafetyMarkdown(id: UUID()).write(to: fixture.transcript, atomically: true, encoding: .utf8)
                try applyStarSafety(true, at: fixture.transcript, id: fixture.id, directory: fixture.directory)
                assertTrue(starSafetyIsStarred(renamed), "the selected capture receives the star")
                assertFalse(starSafetyIsStarred(fixture.transcript), "a different capture at the old name stays unchanged")
            } catch { assertTrue(false, "renamed synthetic capture should resolve: \(error)") }
        }
    }

    runSuite("Star actions reject ambiguous identities and unavailable current libraries") {
        withStarSafetyFixture { fixture in
            let duplicate = fixture.directory.appendingPathComponent("Duplicate.md")
            try? starSafetyMarkdown(id: fixture.id).write(to: duplicate, atomically: true, encoding: .utf8)
            assertStarSafetyRefused(fixture, directory: fixture.directory, "duplicate capture IDs")
            assertFalse(starSafetyIsStarred(duplicate))
            try? FileManager.default.removeItem(at: duplicate)
            assertStarSafetyRefused(fixture, directory: nil, "unavailable current library")
        }
    }

    runSuite("Star actions reject an out-of-library target and read-only transcript") {
        withStarSafetyFixture { fixture in
            let empty = fixture.directory.appendingPathComponent("Empty", isDirectory: true)
            try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
            assertStarSafetyRefused(fixture, directory: empty, "the old library is not authorized")
            try? FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: fixture.transcript.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.transcript.path) }
            assertStarSafetyRefused(fixture, directory: fixture.directory, "read-only capture")
        }
    }

    runSuite("Star actions reject a symlinked current library") {
        withStarSafetyFixture { fixture in
            let link = fixture.directory.appendingPathComponent("Linked", isDirectory: true)
            try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.directory)
            assertStarSafetyRefused(fixture, directory: link, "a symlink cannot authorize mutation")
        }
    }
    runSuite("Star actions resolve only the current library after a move") {
        withStarSafetyFixture { fixture in
            do {
                let current = fixture.directory.appendingPathComponent("Current", isDirectory: true)
                try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
                let moved = current.appendingPathComponent("Moved.md")
                try FileManager.default.moveItem(at: fixture.transcript, to: moved)
                try applyStarSafety(true, at: fixture.transcript, id: fixture.id, directory: current)
                assertTrue(starSafetyIsStarred(moved), "the stable ID is found in the current authorized folder")
                assertFalse(FileManager.default.fileExists(atPath: fixture.transcript.path), "the old path is never recreated")
            } catch { assertTrue(false, "moved synthetic capture should resolve: \(error)") }
        }
    }

    runSuite("Unreadable transcripts and transcript symlinks never authorize pruning or a star") {
        withStarSafetyFixture { fixture in
            let fm = FileManager.default
            let original = try? Data(contentsOf: fixture.transcript)
            try? fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: fixture.transcript.path)
            let removed = MeetingAudioStorageManager.pruneRetainedAudio(in: fixture.directory,
                retentionWindow: .sevenDays, now: Date(timeIntervalSince1970: 1_800_000_000))
            assertEqual(removed, 0)
            assertTrue(fm.fileExists(atPath: fixture.audio.path), "unreadable protection metadata preserves audio")
            var refused = false
            do { try applyStarSafety(true, at: fixture.transcript, id: fixture.id, directory: fixture.directory) }
            catch { refused = true }
            assertTrue(refused)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixture.transcript.path)
            assertEqual(try? Data(contentsOf: fixture.transcript), original)
            let target = fixture.directory.appendingPathComponent("Target.data")
            do {
                try fm.moveItem(at: fixture.transcript, to: target)
                try fm.createSymbolicLink(at: fixture.transcript, withDestinationURL: target)
                assertStarSafetyRefused(fixture, directory: fixture.directory, "a transcript symlink is not a capture")
                assertEqual(MeetingAudioStorageManager.pruneRetainedAudio(in: fixture.directory,
                    retentionWindow: .sevenDays, now: Date(timeIntervalSince1970: 1_800_000_000)), 0)
                assertTrue(fm.fileExists(atPath: fixture.audio.path))
            } catch { assertTrue(false, "synthetic symlink setup failed: \(error)") }
        }
    }

}

private struct StarSafetyFixture {
    let directory: URL
    let transcript: URL
    let audio: URL
    let id: UUID
}

private func withStarSafetyFixture(_ body: (StarSafetyFixture) -> Void) {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("MeetingStarSafety-\(UUID().uuidString)", isDirectory: true)
    let transcript = root.appendingPathComponent("Synthetic.md")
    let audio = root.appendingPathComponent("audio/Synthetic_audio/recording.m4a")
    let id = UUID()
    do {
        try fm.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try starSafetyMarkdown(id: id).write(to: transcript, atomically: true, encoding: .utf8)
        try Data("synthetic".utf8).write(to: audio)
        defer { try? fm.removeItem(at: root) }
        body(StarSafetyFixture(directory: root, transcript: transcript, audio: audio, id: id))
    } catch { assertTrue(false, "synthetic fixture creation failed: \(error)") }
}

private func starSafetyMarkdown(id: UUID) -> String {
    "---\ncapture_type: meeting\ntranscript_id: \"\(id.uuidString)\"\ndate: \"2025-01-01\"\ntime: \"09:00:00\"\n---\n\n## Full Transcript\n\nSynthetic words.\n"
}

private func starSafetyIsStarred(_ url: URL) -> Bool {
    MeetingStarFrontmatter.isStarred(values: (try? TranscriptFrontmatter.readValues(from: url)) ?? [:])
}

private func applyStarSafety(_ starred: Bool, at url: URL, id: UUID, directory: URL?) throws {
    try MeetingStarFrontmatter.setStarred(starred, transcriptAt: url, expectedCaptureID: id,
        authorizedDirectory: { directory })
}

private func assertStarSafetyRefused(_ fixture: StarSafetyFixture, directory: URL?, _ reason: String) {
    let before = try? Data(contentsOf: fixture.transcript)
    var refused = false
    do { try applyStarSafety(true, at: fixture.transcript, id: fixture.id, directory: directory) }
    catch { refused = true }
    assertTrue(refused, "\(reason) must refuse the mutation")
    assertEqual(try? Data(contentsOf: fixture.transcript), before, "\(reason) leaves the capture unchanged")
}

/// Orders two actual transcript scans; the second file-existence read applies
/// the user's star after the first scan but before any destructive decision.
private final class StarSafetyScanFileManager: FileManager {
    let first: URL
    let second: URL
    let secondTranscript: URL
    var onSecondScan: (() throws -> Void)?
    var didInterleave = false

    init(first: URL, second: URL, secondTranscript: URL, onSecondScan: @escaping () throws -> Void) {
        self.first = first; self.second = second; self.secondTranscript = secondTranscript
        self.onSecondScan = onSecondScan
        super.init()
    }

    override func contentsOfDirectory(at url: URL, includingPropertiesForKeys keys: [URLResourceKey]?,
        options mask: FileManager.DirectoryEnumerationOptions = []) throws -> [URL] {
        if url.standardizedFileURL == first.deletingLastPathComponent().standardizedFileURL {
            return [first, second]
        }
        return try super.contentsOfDirectory(at: url, includingPropertiesForKeys: keys, options: mask)
    }

    override func fileExists(atPath path: String) -> Bool {
        if path == secondTranscript.path, let action = onSecondScan {
            onSecondScan = nil
            do { try action(); didInterleave = true } catch { didInterleave = false }
        }
        return super.fileExists(atPath: path)
    }
}
