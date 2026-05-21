import Foundation

func testSpeakerReviewQueueScanner() {
    runSuite("SpeakerReviewQueueScanner extracts deferred speakers with call context") {
        let speakerId = UUID()
        let clipURL = URL(fileURLWithPath: "/tmp/\(speakerId.uuidString).wav")
        let transcriptURL = URL(fileURLWithPath: "/tmp/Customer_Sync.md")

        let markdown = deferredMarkdown(
            speakerId: speakerId,
            title: "Customer Sync",
            date: "2026-05-20",
            time: "09:30:00",
            speakerName: "Speaker 1",
            sampleText: "We should finish the pricing memo."
        )

        let items = SpeakerReviewQueueScanner.pendingItems(
            in: markdown,
            transcriptURL: transcriptURL,
            profilesById: [
                speakerId: makeReviewQueueProfile(id: speakerId, name: nil, calls: 3)
            ],
            clipURLsByProfileID: [speakerId: clipURL]
        )

        assertEqual(items.count, 1, "one db_pending speaker should become one review queue item")
        assertEqual(items.first?.meetingTitle, "Customer Sync", "queue item should keep the meeting title")
        assertEqual(items.first?.sampleText, "We should finish the pricing memo.", "queue item should include a useful sample line")
        assertEqual(items.first?.clipURL, clipURL, "queue item should carry the persisted speaker clip")
        assertEqual(items.first?.callCount, 3, "queue item should keep the profile's call count")
        assertEqual(items.first?.speakerLabel, "System/Speaker 1", "queue item should identify the original speaker label")
        assertTrue(items.first?.recordedAt != nil, "queue item should parse the meeting date and time")
    }

    runSuite("SpeakerReviewQueueScanner hides pending metadata once the profile is named") {
        let speakerId = UUID()
        let markdown = deferredMarkdown(
            speakerId: speakerId,
            title: "Already Named",
            speakerName: "Speaker 2",
            sampleText: "This should no longer appear."
        )

        let items = SpeakerReviewQueueScanner.pendingItems(
            in: markdown,
            transcriptURL: URL(fileURLWithPath: "/tmp/Already_Named.md"),
            profilesById: [
                speakerId: makeReviewQueueProfile(id: speakerId, name: "Maya")
            ],
            clipURLsByProfileID: [:]
        )

        assertEqual(items.count, 0, "named profiles should not keep stale db_pending rows in the queue")
    }

    runSuite("SpeakerReviewQueueScanner sorts newest calls first") {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("SpeakerReviewQueueScannerTests-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }

        let olderId = UUID()
        let newerId = UUID()
        let olderURL = directory.appendingPathComponent("Older.md")
        let newerURL = directory.appendingPathComponent("Newer.md")
        try? deferredMarkdown(
            speakerId: olderId,
            title: "Older Call",
            date: "2026-05-19",
            time: "16:00:00",
            speakerName: "Speaker 1",
            sampleText: "Older sample."
        ).write(to: olderURL, atomically: true, encoding: .utf8)
        try? deferredMarkdown(
            speakerId: newerId,
            title: "Newer Call",
            date: "2026-05-20",
            time: "08:00:00",
            speakerName: "Speaker 2",
            sampleText: "Newer sample."
        ).write(to: newerURL, atomically: true, encoding: .utf8)

        let items = SpeakerReviewQueueScanner.loadPendingItems(
            transcriptsDirectory: directory,
            profiles: [
                makeReviewQueueProfile(id: olderId, name: nil),
                makeReviewQueueProfile(id: newerId, name: nil)
            ],
            clipURLsByProfileID: [:]
        )

        assertEqual(items.map(\.meetingTitle), ["Newer Call", "Older Call"], "newer deferred speaker work should appear first")
    }

    runSuite("SpeakerReviewQueueScanner tolerates UTF-8 split at preview limit") {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory
            .appendingPathComponent("SpeakerReviewQueueScannerTests-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }

        let speakerId = UUID()
        let transcriptURL = directory.appendingPathComponent("SplitPreview.md")
        let prefix = deferredMarkdown(
            speakerId: speakerId,
            title: "Split Preview",
            speakerName: "Speaker 3",
            sampleText: "This should survive a split preview."
        )
        let previewLimit = 256 * 1024
        let fillerByteCount = previewLimit - prefix.utf8.count - 1
        assertTrue(fillerByteCount > 0, "fixture should leave room to split a multi-byte character")
        let content = prefix + String(repeating: "a", count: max(0, fillerByteCount)) + "💬"
        try? content.write(to: transcriptURL, atomically: true, encoding: .utf8)

        let items = SpeakerReviewQueueScanner.loadPendingItems(
            transcriptsDirectory: directory,
            profiles: [
                makeReviewQueueProfile(id: speakerId, name: nil)
            ],
            clipURLsByProfileID: [:]
        )

        assertEqual(items.count, 1, "split UTF-8 at the preview limit should not make the scanner skip the transcript")
        assertEqual(items.first?.meetingTitle, "Split Preview", "scanner should still parse frontmatter from the preview")
    }
}

private func deferredMarkdown(
    speakerId: UUID,
    title: String,
    date: String = "2026-05-20",
    time: String = "09:30:00",
    speakerName: String,
    sampleText: String
) -> String {
    """
    ---
    title: "\(title)"
    date: \(date)
    time: \(time)
    speakers:
      - id: "\(speakerName.replacingOccurrences(of: "Speaker ", with: ""))"
        channel: system
        db_id: "\(speakerId.uuidString)"
        name: "\(speakerName)"
        confidence: unknown
        source: db_pending
    ---

    # \(title)

    ## Transcript

    **00:01** [System/\(speakerName)]
    \(sampleText)
    """
}

private func makeReviewQueueProfile(
    id: UUID,
    name: String?,
    calls: Int = 1
) -> SpeakerProfile {
    SpeakerProfile(
        id: id,
        displayName: name,
        nameSource: name == nil ? nil : NameSource.userManual,
        embedding: [0.1, 0.2, 0.3],
        firstSeen: Date(timeIntervalSinceReferenceDate: 0),
        lastSeen: Date(timeIntervalSinceReferenceDate: 10),
        callCount: calls,
        confidence: 0.8,
        disputeCount: 0
    )
}
