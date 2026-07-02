import Foundation

func testCaptureLibrarySize() {
    runSuite("CaptureLibrarySize sums regular files and skips symlinked folders") {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("CaptureLibrarySizeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }

        let audioDir = root.appendingPathComponent("audio/meeting_audio", isDirectory: true)
        try! fileManager.createDirectory(at: audioDir, withIntermediateDirectories: true)
        try! Data(count: 1_000).write(to: root.appendingPathComponent("meeting.md"))
        try! Data(count: 4_000).write(to: audioDir.appendingPathComponent("microphone.m4a"))

        // A symlinked folder must not be traversed (it may point outside the
        // library) and must not count toward the total.
        let outside = fileManager.temporaryDirectory
            .appendingPathComponent("CaptureLibrarySizeTests-outside-\(UUID().uuidString)", isDirectory: true)
        try! fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: outside) }
        try! Data(count: 50_000).write(to: outside.appendingPathComponent("big.wav"))
        try! fileManager.createSymbolicLink(
            at: root.appendingPathComponent("linked"),
            withDestinationURL: outside
        )

        let measured = CaptureLibrarySize.measureBytes(at: root)
        assertEqual(measured ?? -1, 5_000, "size should sum only real files inside the library")
    }

    runSuite("CaptureLibrarySize returns nil for a missing directory") {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("CaptureLibrarySizeTests-missing-\(UUID().uuidString)", isDirectory: true)
        assertTrue(
            CaptureLibrarySize.measureBytes(at: missing) == nil,
            "missing directory should measure as nil, not zero"
        )
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
