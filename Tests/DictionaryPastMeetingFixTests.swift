import Foundation

func testDictionaryPastMeetingFix() {
    let cloud = CustomDictionaryEntry(spoken: "cloud", replacement: "Claude")

    runSuite("DictionaryPastMeetingFix only rewrites spoken transcript text") {
        let markdown = pastMeetingFixMarkdown()
        let result = DictionaryPastMeetingFix.replacing(cloud, in: markdown)

        assertEqual(result.count, 4, "every spoken cloud should be fixed, any case, like live transcription")
        assertTrue(result.markdown.contains("I asked Claude about it. Claude said yes."), "both matches on one line should change")
        assertTrue(result.markdown.contains("Cloudy weather, Claude storage."), "whole words only, matched without case like the live dictionary")
        assertTrue(result.markdown.contains("Then Claude's answer came back."), "a possessive still counts as the whole word")
        assertTrue(result.markdown.contains("title: \"Cloud sync review\""), "frontmatter must not change")
        assertTrue(result.markdown.contains("name: \"Cloud\""), "frontmatter speaker names must not change")
        assertTrue(result.markdown.contains("# Cloud sync review"), "the title heading must not change")
        assertTrue(result.markdown.contains("**00:12**  [System/Cloud]"), "speaker labels belong to the speaker editor")
        assertTrue(result.markdown.contains("## Notes\n\n- Move cloud storage to https://cloud.google.com/storage"), "sections after the transcript are the user's and must not change")
        assertTrue(result.markdown.contains("- Ask Cloud about pricing"), "the walk must stop at the next section heading")
        assertEqual(
            result.markdown.components(separatedBy: "\n").count,
            markdown.components(separatedBy: "\n").count,
            "a fix must never add or remove lines"
        )
        assertEqual(DictionaryPastMeetingFix.fixCount(of: cloud, in: markdown), 4, "the count should match what a fix changes")
    }

    runSuite("DictionaryPastMeetingFix stops at any heading after the transcript") {
        let markdown = pastMeeting("""
        **00:01**  [Mic/You]
        The cloud is up.

        ### Action items
        - Ask cloud support
        """)
        let result = DictionaryPastMeetingFix.replacing(cloud, in: markdown)
        assertEqual(result.count, 1, "only the spoken line is fixed")
        assertTrue(result.markdown.contains("- Ask cloud support"), "a pasted section under any heading is the user's")
    }

    runSuite("DictionaryPastMeetingFix leaves links, addresses, paths and code alone") {
        let markdown = pastMeeting("""
        **00:01**  [Mic/You]
        See cloud.google.com and https://example.com/cloud, mail me@cloud.io, run `cloud deploy`, then ask the cloud.
        """)
        let result = DictionaryPastMeetingFix.replacing(cloud, in: markdown)
        assertEqual(result.count, 1, "only the plain spoken word is a fix")
        assertTrue(
            result.markdown.contains("See cloud.google.com and https://example.com/cloud, mail me@cloud.io, run `cloud deploy`, then ask the Claude."),
            "links, emails and code spans stay as written; sentence punctuation doesn't block a fix"
        )
    }

    runSuite("DictionaryPastMeetingFix skips text that already reads right") {
        let casing = CustomDictionaryEntry(spoken: "posthog", replacement: "PostHog")
        let markdown = pastMeeting("[00:01] [Mic/You] We moved posthog to PostHog now.")
        let result = DictionaryPastMeetingFix.replacing(casing, in: markdown)
        assertEqual(result.count, 1, "the already-cased PostHog is not a fix")
        assertTrue(result.markdown.contains("We moved PostHog to PostHog now."), "the lowercase spot is re-cased")
        assertEqual(DictionaryPastMeetingFix.fixCount(of: casing, in: result.markdown), 0, "a fixed meeting has nothing left to fix")

        let longer = CustomDictionaryEntry(spoken: "claude", replacement: "Claude Code")
        let mixed = pastMeeting("[00:01] [Mic/You] Claude Code, claude code and claude all ran.")
        let once = DictionaryPastMeetingFix.replacing(longer, in: mixed)
        assertEqual(once.count, 1, "text already reading Claude Code, in any case, is left alone")
        assertTrue(once.markdown.contains("Claude Code, claude code and Claude Code all ran."), "a fix must not stack into Claude Code Code")
        assertEqual(DictionaryPastMeetingFix.replacing(longer, in: once.markdown).count, 0, "a second run changes nothing")
    }

    runSuite("DictionaryPastMeetingFix matches like the live dictionary") {
        let phrase = CustomDictionaryEntry(spoken: "okay ours", replacement: "OKRs")
        let markdown = pastMeeting("[00:01] [Mic/You] Our okay   ours for Q3. Okay ourselves.")
        let result = DictionaryPastMeetingFix.replacing(phrase, in: markdown)
        assertEqual(result.count, 1, "extra spaces between words still match; a longer word does not")
        assertTrue(result.markdown.contains("Our OKRs for Q3. Okay ourselves."), "the phrase is replaced literally")

        let literal = CustomDictionaryEntry(spoken: "see plus plus", replacement: "C++ $1")
        let literalResult = DictionaryPastMeetingFix.replacing(literal, in: pastMeeting("[00:01] [Mic/You] We use see plus plus."))
        assertTrue(literalResult.markdown.contains("We use C++ $1."), "$1 in the fix is literal text")

        // Live transcription applies the longest phrase first, so "okay ours"
        // wins over "okay" and never turns into "OK ours".
        let okay = CustomDictionaryEntry(spoken: "okay", replacement: "OK")
        let overlap = pastMeeting("[00:01] [Mic/You] Our okay ours are okay.")
        let shortRule = DictionaryPastMeetingFix.replacing(okay, allEntries: [phrase, okay], in: overlap)
        assertEqual(shortRule.count, 1, "the longer rule's phrase isn't counted for the shorter rule")
        assertTrue(shortRule.markdown.contains("Our okay ours are OK."), "the longer phrase is left for its own rule")
    }

    runSuite("DictionaryPastMeetingFix only offers rules that add a real fix") {
        assertTrue(DictionaryPastMeetingFix.offersPastFix(for: cloud), "a different word is offered")
        assertTrue(DictionaryPastMeetingFix.offersPastFix(for: CustomDictionaryEntry(spoken: "posthog", replacement: "PostHog")), "adding capitals is offered")
        assertFalse(DictionaryPastMeetingFix.offersPastFix(for: CustomDictionaryEntry(spoken: "Okay", replacement: "okay")), "a rule that only lowercases is never offered")
        assertFalse(DictionaryPastMeetingFix.offersPastFix(for: CustomDictionaryEntry(spoken: "PostHog", replacement: "PostHog")), "a rule that changes nothing is never offered")
    }

    runSuite("DictionaryPastMeetingFix handles legacy inline turns and skips files that aren't meetings") {
        let legacy = """
        ---
        capture_type: meeting
        ---

        # Meeting Recording

        ## Full Transcript

        [00:01] [Mic/You] Hello cloud.

        [00:05] [System/[[Cloud]]] Cloud here.

        *Generated by Transcripted with Parakeet*
        """
        let result = DictionaryPastMeetingFix.replacing(cloud, in: legacy)
        assertEqual(result.count, 2, "text after the inline label should be fixed")
        assertTrue(result.markdown.contains("[00:05] [System/[[Cloud]]] Claude here."), "nested speaker links stay untouched")

        let noFrontmatter = "## Transcript\n\n[00:01] [Mic/You] cloud\n"
        assertEqual(DictionaryPastMeetingFix.replacing(cloud, in: noFrontmatter).count, 0, "a file without frontmatter is not a saved meeting")
        let notes = "---\ntitle: cloud notes\n---\n\n## Transcript\n\ncloud\n"
        assertEqual(DictionaryPastMeetingFix.replacing(cloud, in: notes).count, 0, "frontmatter must say it's a meeting")
        let noHeading = "---\ncapture_type: meeting\n---\n\nSome cloud notes.\n"
        assertEqual(DictionaryPastMeetingFix.replacing(cloud, in: noHeading).count, 0, "files without a transcript heading are never touched")
        let unterminated = "---\ncapture_type: meeting\n\n## Transcript\n\ncloud\n"
        assertEqual(DictionaryPastMeetingFix.replacing(cloud, in: unterminated).count, 0, "unterminated frontmatter is never touched")
    }

    runSuite("DictionaryPastMeetingFix scans, backs up, fixes, and undoes across meetings") {
        withTemporaryPastMeetingDirectory { root in
            let meetings = root.appendingPathComponent("meetings", isDirectory: true)
            try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
            let backups = DictionaryPastMeetingBackupStore(root: root.appendingPathComponent("backups", isDirectory: true))

            let first = meetings.appendingPathComponent("2026-09-20 Cloud sync review.md")
            let second = meetings.appendingPathComponent("2026-09-21 Standup.md")
            let clean = meetings.appendingPathComponent("2026-09-22 Clean.md")
            let summary = meetings.appendingPathComponent("2026-09-20 Cloud sync review.summary.md")
            let agentFile = meetings.appendingPathComponent("CLAUDE.md")
            let firstOriginal = pastMeetingFixMarkdown()
            let secondOriginal = pastMeeting("**00:01**  [Mic/You]\nThe cloud build is green.")
            try firstOriginal.write(to: first, atomically: true, encoding: .utf8)
            try secondOriginal.write(to: second, atomically: true, encoding: .utf8)
            try pastMeeting("**00:01**  [Mic/You]\nNothing to fix.").write(to: clean, atomically: true, encoding: .utf8)
            try pastMeeting("cloud").write(to: summary, atomically: true, encoding: .utf8)
            try pastMeeting("cloud").write(to: agentFile, atomically: true, encoding: .utf8)
            try FileManager.default.createDirectory(at: meetings.appendingPathComponent("audio"), withIntermediateDirectories: true)

            let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
            try FileManager.default.setAttributes([.creationDate: createdAt], ofItemAtPath: second.path)

            let okrs = CustomDictionaryEntry(spoken: "okay ours", replacement: "OKRs")
            let cache = DictionaryPastMeetingTextCache()
            let scans = DictionaryPastMeetingFix.scan(entries: [cloud, okrs], in: meetings, cache: cache)
            assertEqual(scans[cloud]?.meetingCount, 2, "both meetings that say cloud should be found")
            assertEqual(scans[cloud]?.spotCount, 5, "the confirm step counts every spot")
            assertEqual(
                Set(scans[cloud]?.meetingURLs.map(\.lastPathComponent) ?? []),
                [first.lastPathComponent, second.lastPathComponent],
                "summary sidecars and agent files are not meetings"
            )
            assertNil(scans[okrs], "a correction with no past matches is left out")
            assertEqual(DictionaryPastMeetingFix.scan(entries: [cloud], in: meetings, cache: cache)[cloud]?.meetingCount, 2, "a cached count matches")
            assertTrue(DictionaryPastMeetingFix.scan(entries: [cloud], in: meetings, isCancelled: { true }).isEmpty, "a cancelled scan reports nothing")

            let receipt = DictionaryPastMeetingFix.fix(
                cloud,
                allEntries: [cloud, okrs],
                meetingsAt: scans[cloud]?.meetingURLs ?? [],
                backups: backups
            )
            assertEqual(receipt.fixedCount, 2, "both meetings should be fixed")
            assertEqual(receipt.skippedCount, 0, "nothing was busy")
            assertTrue(try String(contentsOf: second, encoding: .utf8).contains("The Claude build is green."), "the fix is saved")
            let savedCreation = try FileManager.default.attributesOfItem(atPath: second.path)[.creationDate] as? Date
            assertEqual(savedCreation, createdAt, "a fix keeps the meeting's creation date so Home's order doesn't change")
            assertNil(DictionaryPastMeetingFix.scan(entries: [cloud], in: meetings, cache: cache)[cloud], "a fixed library has nothing left to offer, even with a warm cache")

            // Undo must survive a relaunch: load the receipt back from disk.
            let reloaded = backups.recentReceipts(meetingsDirectory: meetings)
            assertEqual(reloaded.map(\.id), [receipt.id], "the fix is saved with its backups")

            // A later edit to one meeting must survive undo.
            let newer = try String(contentsOf: first, encoding: .utf8).replacingOccurrences(of: "[Mic/Linus]", with: "[Mic/Lionel]")
            try newer.write(to: first, atomically: true, encoding: .utf8)

            let undo = DictionaryPastMeetingFix.undo(reloaded[0], meetingsDirectory: meetings, backups: backups)
            assertEqual(undo.restoredURLs.map(\.lastPathComponent), [second.lastPathComponent], "only the untouched meeting is put back")
            assertEqual(undo.keptCount, 1, "the meeting edited since is kept")
            assertEqual(undo.busyCount, 0, "nothing was busy")
            assertNil(undo.remaining, "nothing is left to undo")
            assertEqual(try String(contentsOf: second, encoding: .utf8), secondOriginal, "undo restores the file byte for byte")
            assertEqual(try String(contentsOf: first, encoding: .utf8), newer, "the newer edit must survive")
            assertTrue(backups.recentReceipts(meetingsDirectory: meetings).isEmpty, "an undone fix is never offered again")
            assertFalse(FileManager.default.fileExists(atPath: backups.folder(for: receipt.id).path), "an undone fix leaves no backups behind")

            let missing = DictionaryPastMeetingFix.fix(cloud, allEntries: [cloud], meetingsAt: [meetings.appendingPathComponent("gone.md")], backups: backups)
            assertEqual(missing.fixedCount, 0, "a missing meeting is not fixed")
            assertEqual(missing.skippedCount, 1, "a missing meeting is counted as skipped")
            assertFalse(FileManager.default.fileExists(atPath: backups.folder(for: missing.id).path), "a fix that changed nothing leaves no backup")
        }
    }

    runSuite("DictionaryPastMeetingBackupStore never keeps a deleted meeting") {
        withTemporaryPastMeetingDirectory { root in
            let meetings = root.appendingPathComponent("meetings", isDirectory: true)
            try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
            let backups = DictionaryPastMeetingBackupStore(root: root.appendingPathComponent("backups", isDirectory: true))
            let kept = meetings.appendingPathComponent("kept.md")
            let deleted = meetings.appendingPathComponent("deleted.md")
            let renamed = meetings.appendingPathComponent("renamed.md")
            for url in [kept, deleted, renamed] {
                try pastMeeting("[00:01] [Mic/You] The cloud is up.").write(to: url, atomically: true, encoding: .utf8)
            }

            let receipt = DictionaryPastMeetingFix.fix(cloud, allEntries: [cloud], meetingsAt: [kept, deleted, renamed], backups: backups)
            assertEqual(receipt.fixedCount, 3, "all three meetings are fixed")

            // Deleting from Home drops that meeting's backup right away.
            try FileManager.default.removeItem(at: deleted)
            backups.removeBackups(forMeetingsAt: [deleted])
            assertEqual(backups.recentReceipts(meetingsDirectory: meetings).first?.changes.map(\.path), [kept.path, renamed.path], "the deleted meeting's backup is gone")

            // A meeting that disappeared some other way is dropped on the next sweep.
            try FileManager.default.moveItem(at: renamed, to: meetings.appendingPathComponent("moved.md"))
            assertEqual(backups.recentReceipts(meetingsDirectory: meetings).first?.changes.map(\.path), [kept.path], "a missing meeting isn't offered")
            assertTrue(
                FileManager.default.fileExists(atPath: backups.folder(for: receipt.id).appendingPathComponent(receipt.changes[2].backupFilename).path),
                "only the launch sweep deletes backups, so a meeting in Home's delete-Undo window can still come back"
            )
            backups.prune(meetingsDirectory: meetings)
            let remaining = backups.recentReceipts(meetingsDirectory: meetings)
            assertEqual(remaining.first?.changes.map(\.path), [kept.path], "a missing meeting's backup is dropped")
            let backupFiles = try FileManager.default.contentsOfDirectory(atPath: backups.folder(for: receipt.id).path)
                .filter { $0.hasSuffix(".md") }
            assertEqual(backupFiles.count, 1, "only the surviving meeting's backup file is left on disk")

            // Once no meeting is left, the whole fix goes.
            backups.removeBackups(forMeetingsAt: [kept])
            assertTrue(backups.recentReceipts(meetingsDirectory: meetings).isEmpty, "a fix with no meetings left is not offered")
            assertFalse(FileManager.default.fileExists(atPath: backups.folder(for: receipt.id).path), "its folder is deleted")
        }
    }

    runSuite("DictionaryPastMeetingFix undo reports a missing backup honestly") {
        withTemporaryPastMeetingDirectory { root in
            let backups = DictionaryPastMeetingBackupStore(root: root.appendingPathComponent("backups", isDirectory: true))
            let url = root.appendingPathComponent("meeting.md")
            try pastMeeting("[00:01] [Mic/You] The cloud is up.").write(to: url, atomically: true, encoding: .utf8)
            let receipt = DictionaryPastMeetingFix.fix(cloud, allEntries: [cloud], meetingsAt: [url], backups: backups)
            try FileManager.default.removeItem(at: backups.folder(for: receipt.id).appendingPathComponent(receipt.changes[0].backupFilename))

            let undo = DictionaryPastMeetingFix.undo(receipt, meetingsDirectory: root, backups: backups)
            assertEqual(undo.missingBackupCount, 1, "a missing backup is counted as missing")
            assertEqual(undo.keptCount, 0, "not as a meeting that changed")
            assertTrue(try String(contentsOf: url, encoding: .utf8).contains("The Claude is up."), "the meeting stays fixed")
            assertEqual(DictionaryPastMeetingFixCopy.undone(undo), "1 meeting\u{2019}s backup is gone, so it stays fixed.")
        }
    }

    runSuite("DictionaryPastMeetingBackupStore drops old backups") {
        withTemporaryPastMeetingDirectory { root in
            let backups = DictionaryPastMeetingBackupStore(root: root)
            let old = DictionaryPastMeetingFixReceipt(
                id: UUID().uuidString,
                createdAt: Date(timeIntervalSinceNow: -DictionaryPastMeetingBackupStore.retention - 60),
                spoken: "cloud",
                replacement: "Claude",
                changes: [],
                skippedCount: 0
            )
            _ = try backups.writeBackup("original", id: old.id, index: 0)
            try backups.save(old)
            assertTrue(backups.recentReceipts(meetingsDirectory: root).isEmpty, "an expired fix is not offered")
            backups.prune(meetingsDirectory: root)
            assertFalse(FileManager.default.fileExists(atPath: backups.folder(for: old.id).path), "an expired backup is deleted")
        }
    }

    runSuite("DictionaryPastMeetingBackupStore is careful about what it deletes") {
        withTemporaryPastMeetingDirectory { root in
            let meetings = root.appendingPathComponent("meetings", isDirectory: true)
            try FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
            let backups = DictionaryPastMeetingBackupStore(root: root.appendingPathComponent("backups", isDirectory: true))
            let url = meetings.appendingPathComponent("meeting.md")
            try pastMeeting("[00:01] [Mic/You] The cloud is up.").write(to: url, atomically: true, encoding: .utf8)
            let receipt = DictionaryPastMeetingFix.fix(cloud, allEntries: [cloud], meetingsAt: [url], backups: backups)

            let unmounted = root.appendingPathComponent("unmounted", isDirectory: true)
            backups.prune(meetingsDirectory: unmounted)
            assertTrue(FileManager.default.fileExists(atPath: backups.folder(for: receipt.id).path), "a missing meetings folder never wipes the backups")

            // A receipt that names another folder is never trusted.
            var tampered = receipt
            tampered.changes = [DictionaryPastMeetingFileChange(path: url.path, backupFilename: "../../meetings/meeting.md", updatedSHA256: "")]
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            try encoder.encode(tampered).write(to: backups.folder(for: receipt.id).appendingPathComponent("receipt.json"))
            assertTrue(backups.recentReceipts(meetingsDirectory: meetings).isEmpty, "a malformed receipt isn't offered")
            backups.removeBackups(forMeetingsAt: [url])
            assertTrue(FileManager.default.fileExists(atPath: url.path), "cleanup never follows a path out of the backup folder")
        }
    }

    runSuite("DictionaryPastMeetingFix undo follows a moved library") {
        withTemporaryPastMeetingDirectory { root in
            let oldLibrary = root.appendingPathComponent("old", isDirectory: true)
            let newLibrary = root.appendingPathComponent("new", isDirectory: true)
            try FileManager.default.createDirectory(at: oldLibrary, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: newLibrary, withIntermediateDirectories: true)
            let backups = DictionaryPastMeetingBackupStore(root: root.appendingPathComponent("backups", isDirectory: true))
            let original = pastMeeting("[00:01] [Mic/You] The cloud is up.")
            let oldURL = oldLibrary.appendingPathComponent("2026-09-20 Sync.md")
            try original.write(to: oldURL, atomically: true, encoding: .utf8)

            let receipt = DictionaryPastMeetingFix.fix(cloud, allEntries: [cloud], meetingsAt: [oldURL], backups: backups)
            let newURL = newLibrary.appendingPathComponent(oldURL.lastPathComponent)
            try FileManager.default.moveItem(at: oldURL, to: newURL)

            assertEqual(backups.recentReceipts(meetingsDirectory: newLibrary).map(\.id), [receipt.id], "the fix is still offered after the library moves")
            let undo = DictionaryPastMeetingFix.undo(receipt, meetingsDirectory: newLibrary, backups: backups)
            assertEqual(undo.restoredURLs.map(\.path), [newURL.path], "undo finds the meeting in the new library")
            assertEqual(try String(contentsOf: newURL, encoding: .utf8), original, "and restores it")
        }
    }

    runSuite("DictionaryPastMeetingBackupStore keeps only what's left to undo") {
        withTemporaryPastMeetingDirectory { root in
            let backups = DictionaryPastMeetingBackupStore(root: root.appendingPathComponent("backups", isDirectory: true))
            let first = root.appendingPathComponent("first.md")
            let second = root.appendingPathComponent("second.md")
            for url in [first, second] {
                try pastMeeting("[00:01] [Mic/You] The cloud is up.").write(to: url, atomically: true, encoding: .utf8)
            }
            let receipt = DictionaryPastMeetingFix.fix(cloud, allEntries: [cloud], meetingsAt: [first, second], backups: backups)
            assertEqual(receipt.fixedCount, 2, "both meetings are fixed")

            let left = backups.keepOnly([receipt.changes[1]], of: receipt)
            assertEqual(left?.changes, [receipt.changes[1]], "a busy meeting stays undoable")
            assertEqual(backups.recentReceipts(meetingsDirectory: root).first?.changes, [receipt.changes[1]], "and is saved that way")
            assertFalse(
                FileManager.default.fileExists(atPath: backups.folder(for: receipt.id).appendingPathComponent(receipt.changes[0].backupFilename).path),
                "a finished meeting's backup is removed"
            )
            assertNil(backups.keepOnly([], of: left ?? receipt), "nothing left means no fix")
            assertFalse(FileManager.default.fileExists(atPath: backups.folder(for: receipt.id).path), "and no folder")
        }
    }

    runSuite("DictionaryPastMeetingFixCopy") {
        assertEqual(DictionaryPastMeetingFixCopy.found(1), "Also in 1 past meeting.")
        assertEqual(DictionaryPastMeetingFixCopy.found(6), "Also in 6 past meetings.")
        assertEqual(DictionaryPastMeetingFixCopy.fixAction(1), "Fix it")
        assertEqual(DictionaryPastMeetingFixCopy.fixAction(6), "Fix them")
        assertEqual(DictionaryPastMeetingFixCopy.fixed(count: 1, remaining: 0), "Fixed 1 meeting.")
        assertEqual(DictionaryPastMeetingFixCopy.fixed(count: 4, remaining: 2), "Fixed 4 meetings. 2 more couldn\u{2019}t be changed yet.")

        let scan = DictionaryPastMeetingScan(meetingURLs: [URL(fileURLWithPath: "/tmp/a.md"), URL(fileURLWithPath: "/tmp/b.md")], spotCount: 14)
        assertEqual(DictionaryPastMeetingFixCopy.confirmTitle(scan), "Fix 2 past meetings?")
        assertEqual(DictionaryPastMeetingFixCopy.confirmAction(scan), "Fix 2 meetings")
        assertEqual(
            DictionaryPastMeetingFixCopy.confirmMessage(cloud, scan: scan),
            "\u{201C}cloud\u{201D} becomes \u{201C}Claude\u{201D} in 14 spots, in any capitalization. Only what was said changes, not titles, names or notes. You can undo this for 3 days."
        )

        func receipt(fixed: Int, skipped: Int) -> DictionaryPastMeetingFixReceipt {
            let change = DictionaryPastMeetingFileChange(path: "/tmp/a.md", backupFilename: "0.md", updatedSHA256: "")
            return DictionaryPastMeetingFixReceipt(
                id: "x",
                createdAt: Date(),
                spoken: "cloud",
                replacement: "Claude",
                changes: Array(repeating: change, count: fixed),
                skippedCount: skipped
            )
        }
        assertNil(DictionaryPastMeetingFixCopy.fixOutcomeNote(receipt(fixed: 1, skipped: 1)), "a fix that changed something shows the fixed line")
        assertEqual(DictionaryPastMeetingFixCopy.fixOutcomeNote(receipt(fixed: 0, skipped: 2)), "Couldn\u{2019}t change those meetings. They may be busy or gone.")
        assertEqual(DictionaryPastMeetingFixCopy.fixOutcomeNote(receipt(fixed: 0, skipped: 0)), "Those meetings are already fixed.")

        assertEqual(DictionaryPastMeetingFixCopy.earlierFix(cloud, meetings: 6), "Changed \u{201C}cloud\u{201D} to \u{201C}Claude\u{201D} in 6 meetings.")
        assertEqual(DictionaryPastMeetingFixCopy.earlierFix(cloud, meetings: 1), "Changed \u{201C}cloud\u{201D} to \u{201C}Claude\u{201D} in 1 meeting.")

        let url = URL(fileURLWithPath: "/tmp/meeting.md")
        assertNil(DictionaryPastMeetingFixCopy.undone(DictionaryPastMeetingUndoResult(restoredURLs: [url], keptCount: 0)), "a clean undo needs no note")
        assertEqual(
            DictionaryPastMeetingFixCopy.undone(DictionaryPastMeetingUndoResult(restoredURLs: [], keptCount: 2)),
            "2 meetings were edited since the fix, so they weren\u{2019}t undone."
        )
        assertEqual(
            DictionaryPastMeetingFixCopy.undone(DictionaryPastMeetingUndoResult(restoredURLs: [], keptCount: 1)),
            "1 meeting was edited since the fix, so it wasn\u{2019}t undone."
        )
        assertEqual(
            DictionaryPastMeetingFixCopy.undone(DictionaryPastMeetingUndoResult(restoredURLs: [], keptCount: 0, busyCount: 2)),
            "2 meetings were busy, so they weren\u{2019}t undone yet."
        )
    }
}

private func pastMeeting(_ transcript: String) -> String {
    "---\ncapture_type: meeting\n---\n\n## Transcript\n\n\(transcript)\n"
}

private func pastMeetingFixMarkdown() -> String {
    """
    ---
    title: "Cloud sync review"
    capture_id: "297F08B7-62AE-4291-9EA3-41EB0B17A64A"
    capture_type: meeting
    speakers:
      - id: "1"
        channel: system
        name: "Cloud"
        source: user_manual
    ---

    # Cloud sync review

    Recorded Apr 25, 2026 at 12:18 PM  •  31 sec  •  20 words  •  3 turns

    ## Transcript

    **00:00**  [Mic/Linus]
    I asked Cloud about it. Cloud said yes.

    **00:12**  [System/Cloud]
    Cloudy weather, cloud storage.

    **00:26**  [Mic/Linus]
    Then Cloud's answer came back.

    ## Notes

    - Move cloud storage to https://cloud.google.com/storage
    - Ask Cloud about pricing
    """
}

private func withTemporaryPastMeetingDirectory(_ body: (URL) throws -> Void) {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent("build/dictionary-past-meeting-fix-tests", isDirectory: true)
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    do {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try body(root)
    } catch {
        assertTrue(false, "past meeting fix fixture failed: \(error)")
    }
    try? fm.removeItem(at: root)
}
