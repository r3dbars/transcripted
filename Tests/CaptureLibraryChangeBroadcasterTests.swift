import Foundation

@MainActor
func testCaptureLibraryChangeBroadcaster() async {
    await runSuite("CaptureLibraryChangeBroadcaster coalesces a burst into one debounced notification") {
        let center = NotificationCenter()
        var capturedIDs: [[String]] = []
        let token = center.addObserver(
            forName: .meetingCaptureArtifactsDidChange,
            object: nil,
            queue: nil
        ) { note in
            let ids = note.userInfo?[CaptureLibraryChange.affectedTranscriptIDsKey] as? [String] ?? []
            capturedIDs.append(ids)
        }
        defer { center.removeObserver(token) }

        // Capture the scheduled flush instead of running it so we can assert the
        // burst coalesced into a single pending flush.
        var pendingFlush: (@MainActor () -> Void)?
        var scheduleCount = 0
        let broadcaster = CaptureLibraryChangeBroadcaster(
            notificationCenter: center,
            debounceInterval: 0,
            scheduleFlush: { work in
                scheduleCount += 1
                pendingFlush = work
            }
        )

        let a = URL(fileURLWithPath: "/tmp/meetings/2026-06-13 Alpha.md")
        let b = URL(fileURLWithPath: "/tmp/meetings/2026-06-13 Beta.md")

        broadcaster.noteArtifactsChanged(transcriptURLs: [a])
        broadcaster.noteArtifactsChanged(transcriptURLs: [b])
        broadcaster.noteArtifactsChanged(transcriptURLs: [a]) // duplicate id

        assertEqual(scheduleCount, 1, "a burst within the debounce window should schedule exactly one flush")
        assertTrue(capturedIDs.isEmpty, "nothing should post until the debounced flush runs")

        pendingFlush?()

        assertEqual(capturedIDs.count, 1, "the coalesced burst should post exactly one notification")
        assertEqual(
            capturedIDs.first,
            [a.standardizedFileURL.path, b.standardizedFileURL.path].sorted(),
            "the notification should carry the de-duplicated union of affected transcript ids"
        )
    }

    await runSuite("CaptureLibraryChangeBroadcaster reports a library-wide change as empty ids") {
        let center = NotificationCenter()
        var capturedIDs: [[String]] = []
        let token = center.addObserver(
            forName: .meetingCaptureArtifactsDidChange,
            object: nil,
            queue: nil
        ) { note in
            let ids = note.userInfo?[CaptureLibraryChange.affectedTranscriptIDsKey] as? [String] ?? []
            capturedIDs.append(ids)
        }
        defer { center.removeObserver(token) }

        var pendingFlush: (@MainActor () -> Void)?
        let broadcaster = CaptureLibraryChangeBroadcaster(
            notificationCenter: center,
            debounceInterval: 0,
            scheduleFlush: { work in pendingFlush = work }
        )

        // A specific transcript change followed by a library-wide backfill in the
        // same window should escalate to the library-wide (empty) signal.
        broadcaster.noteArtifactsChanged(transcriptURLs: [URL(fileURLWithPath: "/tmp/meetings/One.md")])
        broadcaster.noteLibraryWideChange()
        pendingFlush?()

        assertEqual(capturedIDs.count, 1, "library-wide change should still post a single notification")
        assertEqual(capturedIDs.first, [], "a library-wide change should carry an empty id list")
    }

    await runSuite("CaptureLibraryChangeBroadcaster is idempotent with nothing pending") {
        let center = NotificationCenter()
        var postCount = 0
        let token = center.addObserver(
            forName: .meetingCaptureArtifactsDidChange,
            object: nil,
            queue: nil
        ) { _ in postCount += 1 }
        defer { center.removeObserver(token) }

        let broadcaster = CaptureLibraryChangeBroadcaster(
            notificationCenter: center,
            debounceInterval: 0,
            scheduleFlush: { work in work() }
        )

        // Flushing with nothing pending must not post; a second note after a flush
        // schedules a fresh notification.
        broadcaster.flush()
        assertEqual(postCount, 0, "flushing with nothing pending should post nothing")

        broadcaster.noteArtifactsChanged(transcriptURLs: [URL(fileURLWithPath: "/tmp/meetings/Two.md")])
        assertEqual(postCount, 1, "a note after an empty flush should still deliver")

        broadcaster.flush()
        assertEqual(postCount, 1, "re-flushing after delivery should not double-post")
    }
}
