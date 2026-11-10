import Foundation

func testCaptureLibrarySize() {
    runSuite("CaptureLibrarySize sums regular files and skips symlinked folders") {
        withCaptureSizeFixture { fixture in
            let fileManager = FileManager.default
            let root = fixture.appendingPathComponent("library", isDirectory: true)

            let audioDir = root.appendingPathComponent("audio/meeting_audio", isDirectory: true)
            try fileManager.createDirectory(at: audioDir, withIntermediateDirectories: true)
            try Data(count: 1_000).write(to: root.appendingPathComponent("meeting.md"))
            try Data(count: 4_000).write(to: audioDir.appendingPathComponent("microphone.m4a"))

            // A symlinked folder must not be traversed (it may point outside the
            // library) and must not count toward the total.
            let outside = fixture.appendingPathComponent("outside-library", isDirectory: true)
            try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
            try Data(count: 50_000).write(to: outside.appendingPathComponent("big.wav"))
            try fileManager.createSymbolicLink(
                at: root.appendingPathComponent("linked"),
                withDestinationURL: outside
            )

            let measured = CaptureLibrarySize.measureBytes(at: root)
            assertEqual(measured ?? -1, 5_000, "size should sum only real files inside the library")
        }
    }

    runSuite("CaptureLibrarySize returns nil for a missing directory") {
        withCaptureSizeFixture { fixture in
            let missing = fixture.appendingPathComponent("missing", isDirectory: true)
            assertTrue(
                CaptureLibrarySize.measureBytes(at: missing) == nil,
                "missing directory should measure as nil, not zero"
            )
        }
    }

    runSuite("Capture totals include meetings, retained dictation audio and writing only") {
        withCaptureSizeFixture { fixture in
            let root = fixture.appendingPathComponent("library", isDirectory: true)
            let files = [
                "meetings/meeting.md": 1_000,
                "meetings/audio/meeting_audio/microphone.m4a": 4_000,
                "dictations/Dictations_2026-11-10.md": 200,
                "dictations/audio/synthetic.m4a": 3_000,
                "writing/Writing_2026-11-10.md": 300,
                "unrelated/private.bin": 30_000,
                "loose.bin": 20_000,
            ]
            for (path, bytes) in files { try writeSizeFixture(bytes, to: root.appendingPathComponent(path)) }
            assertEqual(CaptureLibrarySize.measureCaptureBytes(at: root), 8_500,
                        "only the three capture folders contribute to the total")
        }
    }

    runSuite("A dictation-only library includes its retained audio without a meetings folder") {
        withCaptureSizeFixture { fixture in
            let root = fixture.appendingPathComponent("library", isDirectory: true)
            try writeSizeFixture(5, to: root.appendingPathComponent("dictations/Dictations_2026-11-10.md"))
            try writeSizeFixture(6_000, to: root.appendingPathComponent("dictations/audio/synthetic.wav"))
            assertEqual(CaptureLibrarySize.measureCaptureBytes(at: root), 6_005)
        }
    }

    runSuite("Capture totals skip linked capture folders and refuse a linked library root") {
        withCaptureSizeFixture { fixture in
            let root = fixture.appendingPathComponent("library", isDirectory: true)
            let outside = fixture.appendingPathComponent("outside-library", isDirectory: true)
            try writeSizeFixture(1_000, to: root.appendingPathComponent("meetings/meeting.md"))
            try writeSizeFixture(50_000, to: outside.appendingPathComponent("unrelated.bin"))
            try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("dictations"),
                                                     withDestinationURL: outside)
            assertEqual(CaptureLibrarySize.measureCaptureBytes(at: root), 1_000)
            let linkedRoot = fixture.appendingPathComponent("linked-library")
            try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: root)
            assertNil(CaptureLibrarySize.measureCaptureBytes(at: linkedRoot))
        }
    }

    runSuite("An empty capture library is zero while a missing library is unknown") {
        withCaptureSizeFixture { fixture in
            assertEqual(CaptureLibrarySize.measureCaptureBytes(at: fixture), 0)
            assertNil(CaptureLibrarySize.measureCaptureBytes(at: fixture.appendingPathComponent("missing")))
        }
    }

    runSuite("CaptureLibrarySize buckets are coarse and ordered") {
        let gigabyte: Int64 = 1024 * 1024 * 1024
        assertEqual(CaptureLibrarySize.bucketLabel(forBytes: 0), "under_1gb")
        assertEqual(CaptureLibrarySize.bucketLabel(forBytes: gigabyte - 1), "under_1gb")
        assertEqual(CaptureLibrarySize.bucketLabel(forBytes: gigabyte), "1_5gb")
        assertEqual(CaptureLibrarySize.bucketLabel(forBytes: 7 * gigabyte), "5_20gb")
        assertEqual(CaptureLibrarySize.bucketLabel(forBytes: 30 * gigabyte), "20_50gb")
        assertEqual(CaptureLibrarySize.bucketLabel(forBytes: 80 * gigabyte), "over_50gb")
    }
}

private func writeSizeFixture(_ bytes: Int, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(count: bytes).write(to: url)
}

private func withCaptureSizeFixture(_ body: (URL) throws -> Void) {
    let manager = FileManager.default
    let parent = manager.temporaryDirectory.resolvingSymlinksInPath()
    let leaf = "CaptureLibrarySizeTests-" + UUID().uuidString
    let root = parent.appendingPathComponent(leaf, isDirectory: true)
    do {
        try manager.createDirectory(at: root, withIntermediateDirectories: false)
        defer {
            let resolved = root.resolvingSymlinksInPath()
            if resolved.deletingLastPathComponent() == parent, resolved.lastPathComponent == leaf {
                do { try manager.removeItem(at: root) }
                catch { assertTrue(false, "Could not remove the owned size fixture") }
            } else { assertTrue(false, "Size fixture escaped its owned root") }
        }
        try body(root)
    } catch { assertTrue(false, "Could not prepare the owned size fixture") }
}
