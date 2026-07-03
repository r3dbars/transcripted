import Foundation

func testTimelineCaptureJoiner() {
    runSuite("TimelineCaptureJoiner projects meeting frontmatter into timeline cards") {
        let fixture = TimelineJoinerFixture()
        defer { fixture.cleanup() }

        let meetingID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let meetingURL = fixture.meetings.appendingPathComponent("standup.md")
        try? fixture.writeMeeting(
            url: meetingURL,
            id: meetingID,
            title: "Standup",
            date: "2026-07-02",
            time: "10:00:00",
            duration: "00:30:00",
            summary: "We picked the launch checklist.",
            body: "**00:00** [Speaker 1]\nHello"
        )

        let cards = TimelineCaptureJoiner.loadCards(
            meetingDirectory: fixture.meetings,
            dictationDirectory: fixture.dictations,
            calendar: fixture.calendar
        )

        assertEqual(cards.count, 1, "one meeting card")
        assertEqual(cards.first?.kind, .meeting, "meeting kind")
        assertEqual(cards.first?.captureID, meetingID.uuidString, "capture id join key")
        assertEqual(cards.first?.day, "2026-07-02", "timeline day")
        assertEqual(cards.first?.title, "Standup", "meeting title")
        assertEqual(cards.first?.summary, "We picked the launch checklist.", "meeting summary")
        assertEqual(cards.first?.needsSpeakerReview, true, "speaker review surfaced")
    }

    runSuite("TimelineCaptureJoiner updates moved meeting artifacts by capture_id") {
        let fixture = TimelineJoinerFixture()
        defer { fixture.cleanup() }

        let meetingID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let store = InMemoryTimelineCaptureProjectionStore()
        let originalURL = fixture.meetings.appendingPathComponent("original.md")
        try? fixture.writeMeeting(
            url: originalURL,
            id: meetingID,
            title: "Original",
            date: "2026-07-02",
            time: "11:00:00",
            duration: "00:10:00",
            summary: "Original summary."
        )
        _ = TimelineCaptureJoiner.refresh(
            store: store,
            meetingDirectory: fixture.meetings,
            dictationDirectory: fixture.dictations,
            calendar: fixture.calendar
        )

        let renamedURL = fixture.meetings.appendingPathComponent("renamed.md")
        try? FileManager.default.moveItem(at: originalURL, to: renamedURL)
        let result = TimelineCaptureJoiner.refresh(
            store: store,
            meetingDirectory: fixture.meetings,
            dictationDirectory: fixture.dictations,
            calendar: fixture.calendar
        )

        assertEqual(result.removed, 0, "same capture id should update, not delete")
        assertEqual(store.cards[meetingID.uuidString]?.sourceURL.lastPathComponent, "renamed.md", "renamed source path")
    }

    runSuite("TimelineCaptureJoiner assigns pre-4AM captures to previous logical day") {
        let fixture = TimelineJoinerFixture()
        defer { fixture.cleanup() }

        let meetingID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        try? fixture.writeMeeting(
            url: fixture.meetings.appendingPathComponent("late.md"),
            id: meetingID,
            title: "Late Work",
            date: "2026-07-03",
            time: "03:30:00",
            duration: "00:20:00",
            summary: "Late notes."
        )

        let card = TimelineCaptureJoiner.loadCards(
            meetingDirectory: fixture.meetings,
            dictationDirectory: fixture.dictations,
            calendar: fixture.calendar
        ).first

        assertEqual(card?.day, "2026-07-02", "3:30 AM belongs to prior logical day")
    }

    runSuite("TimelineCaptureJoiner clusters dictation bursts and splits after 15 minutes") {
        let fixture = TimelineJoinerFixture()
        defer { fixture.cleanup() }

        _ = try? DictationTranscriptStore.save(
            text: "first launch note",
            sourceApp: nil,
            delivery: .copied,
            createdAt: fixture.date("2026-07-02T10:00:00Z"),
            directory: fixture.dictations
        )
        _ = try? DictationTranscriptStore.save(
            text: "second launch note",
            sourceApp: nil,
            delivery: .copied,
            createdAt: fixture.date("2026-07-02T10:10:00Z"),
            directory: fixture.dictations
        )
        _ = try? DictationTranscriptStore.save(
            text: "later planning note",
            sourceApp: nil,
            delivery: .copied,
            createdAt: fixture.date("2026-07-02T10:31:00Z"),
            directory: fixture.dictations
        )

        let dictationCards = TimelineCaptureJoiner.loadCards(
            meetingDirectory: fixture.meetings,
            dictationDirectory: fixture.dictations,
            calendar: fixture.calendar
        ).filter { $0.kind == .dictation }

        assertEqual(dictationCards.count, 2, "gap > 15 minutes splits bursts")
        assertEqual(dictationCards.first?.title, "2 dictations", "first burst title")
        assertTrue(dictationCards.first?.summary.contains("first launch note") == true, "first burst includes first text")
        assertTrue(dictationCards.first?.summary.contains("second launch note") == true, "first burst includes second text")
    }

    runSuite("TimelineCaptureJoiner removes missing artifacts and ignores malformed files") {
        let fixture = TimelineJoinerFixture()
        defer { fixture.cleanup() }

        let meetingID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let store = InMemoryTimelineCaptureProjectionStore()
        let meetingURL = fixture.meetings.appendingPathComponent("valid.md")
        try? fixture.writeMeeting(
            url: meetingURL,
            id: meetingID,
            title: "Valid",
            date: "2026-07-02",
            time: "12:00:00",
            duration: "00:20:00",
            summary: "Valid summary."
        )
        try? "not frontmatter".write(
            to: fixture.meetings.appendingPathComponent("broken.md"),
            atomically: true,
            encoding: .utf8
        )

        _ = TimelineCaptureJoiner.refresh(
            store: store,
            meetingDirectory: fixture.meetings,
            dictationDirectory: fixture.dictations,
            calendar: fixture.calendar
        )
        try? FileManager.default.removeItem(at: meetingURL)
        let result = TimelineCaptureJoiner.refresh(
            store: store,
            meetingDirectory: fixture.meetings,
            dictationDirectory: fixture.dictations,
            calendar: fixture.calendar
        )

        assertEqual(result.removed, 1, "missing source removes stale projection")
        assertEqual(store.cards.count, 0, "malformed file is tolerated and skipped")
    }

    runSuite("TimelineCaptureJoiner observer refreshes for meeting and dictation changes") {
        let fixture = TimelineJoinerFixture()
        defer { fixture.cleanup() }

        let center = NotificationCenter()
        let store = InMemoryTimelineCaptureProjectionStore()
        let observer = TimelineCaptureJoiner.observeCaptureLibraryChanges(
            store: store,
            meetingDirectory: fixture.meetings,
            dictationDirectory: fixture.dictations,
            notificationCenter: center
        )
        _ = observer

        let meetingID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        try? fixture.writeMeeting(
            url: fixture.meetings.appendingPathComponent("meeting.md"),
            id: meetingID,
            title: "Observed Meeting",
            date: "2026-07-02",
            time: "13:00:00",
            duration: "00:20:00",
            summary: "Observed meeting summary."
        )
        center.post(name: .meetingCaptureArtifactsDidChange, object: nil)
        assertNotNil(store.cards[meetingID.uuidString], "meeting notification refreshes projections")

        _ = try? DictationTranscriptStore.save(
            text: "observer dictation",
            sourceApp: nil,
            delivery: .copied,
            createdAt: fixture.date("2026-07-02T14:00:00Z"),
            directory: fixture.dictations
        )
        center.post(name: .dictationTranscriptDidSave, object: nil)
        assertTrue(
            store.cards.values.contains { $0.kind == .dictation && $0.summary == "observer dictation" },
            "dictation save notification refreshes projections"
        )
    }
}

private final class InMemoryTimelineCaptureProjectionStore: TimelineCaptureProjectionStore, @unchecked Sendable {
    var cards: [String: TimelineCaptureCard] = [:]

    func existingCaptureIDs(for kind: TimelineCaptureKind) -> Set<String> {
        Set(cards.values.filter { $0.kind == kind }.map(\.captureID))
    }

    func upsert(_ cards: [TimelineCaptureCard]) {
        for card in cards {
            self.cards[card.captureID] = card
        }
    }

    func removeCaptureIDs(_ captureIDs: Set<String>, kind: TimelineCaptureKind) {
        for captureID in captureIDs where cards[captureID]?.kind == kind {
            cards.removeValue(forKey: captureID)
        }
    }
}

private final class TimelineJoinerFixture {
    let root: URL
    let meetings: URL
    let dictations: URL
    let calendar: Calendar

    init() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "TimelineCaptureJoinerTests-\(UUID().uuidString)",
            isDirectory: true
        )
        meetings = root.appendingPathComponent("meetings", isDirectory: true)
        dictations = root.appendingPathComponent("dictations", isDirectory: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        self.calendar = calendar
        try? FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: dictations, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    func writeMeeting(
        url: URL,
        id: UUID,
        title: String,
        date: String,
        time: String,
        duration: String,
        summary: String,
        body: String = "**00:00** [You]\nHello"
    ) throws {
        let markdown = """
        ---
        title: "\(title)"
        date: \(date)
        time: \(time)
        duration: \(duration)
        capture_type: meeting
        transcript_id: "\(id.uuidString)"
        local_summary_version: 1
        local_summary_title: "\(title)"
        local_summary: "\(summary)"
        ---

        # \(title)

        ## Local Summary

        ### Summary
        \(summary)

        ## Transcript

        \(body)
        """
        try markdown.write(to: url, atomically: true, encoding: .utf8)
    }

    func date(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string) ?? Date(timeIntervalSince1970: 0)
    }
}
