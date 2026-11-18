import Foundation

@MainActor
func testMeetingTitlesQueue() async {
    await runSuite("A saved meeting gets its title, line and summary from the engine") {
        let directory = MeetingTitlesFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = MeetingTitlesFixtures.writeMeeting(MeetingTitlesFixtures.meetingMarkdown(), named: "a.md", in: directory)
        let host = FakeTitlesHost()
        let queue = MeetingTitlesQueue(host: host, environment: .init(isEnabled: { true }, isBusy: { false }))
        var results: [MeetingTitlesJobResult] = []
        queue.onJobFinished = { _, result in results.append(result) }
        queue.enqueue(MeetingTitlesJob(transcriptURL: url, titleRule: .appMade("Meeting with Priya")))
        await queue.waitUntilIdle()

        assertEqual(results, [.written])
        let values = TranscriptFrontmatter.values(in: (try? String(contentsOf: url, encoding: .utf8)) ?? "") ?? [:]
        assertEqual(values["ai_title"], "Vendor contract renewal")
        assertEqual(host.events, ["start", "stop"], "the engine starts for the job and stops when the queue empties")
        let sent = host.engine.sentTranscripts.first ?? ""
        assertTrue(sent.contains("You: Thanks for joining."), "the recorder is You")
        assertTrue(sent.contains("Priya: Sure."), "named speakers keep their names")
    }

    await runSuite("With the feature off nothing runs") {
        let directory = MeetingTitlesFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = MeetingTitlesFixtures.writeMeeting(MeetingTitlesFixtures.meetingMarkdown(), named: "a.md", in: directory)
        let host = FakeTitlesHost()
        let queue = MeetingTitlesQueue(host: host, environment: .init(isEnabled: { false }, isBusy: { false }))
        queue.enqueue(MeetingTitlesJob(transcriptURL: url, titleRule: .appMade("Meeting with Priya")))
        queue.enqueueBackfill([MeetingTitlesJob(transcriptURL: url, titleRule: .fromFile)])
        await queue.waitUntilIdle()
        assertEqual(host.events, [])
        assertNil(TranscriptFrontmatter.values(in: (try? String(contentsOf: url, encoding: .utf8)) ?? "")?["ai_summary_version"])
    }

    await runSuite("Done and too-short meetings are skipped without starting the engine") {
        let directory = MeetingTitlesFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let done = MeetingTitlesFixtures.writeMeeting(
            MeetingTitlesFixtures.meetingMarkdown(extraFrontmatter: ["ai_summary_version: \"1\""]), named: "done.md", in: directory
        )
        let short = MeetingTitlesFixtures.writeMeeting(
            MeetingTitlesFixtures.meetingMarkdown(turns: [("00:01", "Mic/You", "Testing one two.")]), named: "short.md", in: directory
        )
        let shortBefore = try? String(contentsOf: short, encoding: .utf8)
        let host = FakeTitlesHost()
        let queue = MeetingTitlesQueue(host: host, environment: .init(isEnabled: { true }, isBusy: { false }))
        var results: [MeetingTitlesJobResult] = []
        queue.onJobFinished = { _, result in results.append(result) }
        queue.enqueueBackfill([
            MeetingTitlesJob(transcriptURL: done, titleRule: .fromFile),
            MeetingTitlesJob(transcriptURL: short, titleRule: .fromFile),
        ])
        await queue.waitUntilIdle()
        assertEqual(results, [.alreadyCurrent, .tooShort])
        assertEqual(host.startCount, 0)
        let shortAfter = (try? String(contentsOf: short, encoding: .utf8)) ?? ""
        assertEqual(TranscriptFrontmatter.body(in: shortAfter), TranscriptFrontmatter.body(in: shortBefore ?? ""), "a too-short meeting's body is untouched")
        let shortValues = TranscriptFrontmatter.values(in: shortAfter) ?? [:]
        assertEqual(shortValues["ai_summary_status"], "too_short", "the outcome is recorded")
        assertEqual(shortValues["ai_summary_version"], "1", "so it is skipped until the version changes")
        assertNil(shortValues["ai_summary"])
        assertFalse(MeetingTitlesController.backfillJobs(in: directory).contains { $0.transcriptURL.lastPathComponent == "short.md" })
    }

    await runSuite("No job starts during a recording or dictation; it waits and resumes") {
        let directory = MeetingTitlesFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = MeetingTitlesFixtures.writeMeeting(MeetingTitlesFixtures.meetingMarkdown(), named: "a.md", in: directory)
        let host = FakeTitlesHost()
        let state = BusyState()
        let queue = MeetingTitlesQueue(host: host, environment: .init(
            isEnabled: { true },
            isBusy: { state.isBusy },
            sleep: { interval in
                // Only the between-jobs busy wait counts; a running job's
                // watcher sleeps on a shorter interval.
                if interval == .seconds(5) {
                    host.note("poll")
                    state.poll()
                } else {
                    try? await Task.sleep(for: .milliseconds(2))
                }
            }
        ))
        queue.enqueue(MeetingTitlesJob(transcriptURL: url, titleRule: .appMade("Meeting with Priya")))
        await queue.waitUntilIdle()
        assertEqual(host.events, ["stop", "poll", "poll", "poll", "start", "stop"])
        assertEqual(TranscriptFrontmatter.values(in: (try? String(contentsOf: url, encoding: .utf8)) ?? "")?["ai_summary_version"], "1")
    }

    await runSuite("Backfill runs newest first, behind a just-saved meeting") {
        let directory = MeetingTitlesFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let old = MeetingTitlesFixtures.writeMeeting(MeetingTitlesFixtures.meetingMarkdown(date: "2026-01-02"), named: "old.md", in: directory)
        let middle = MeetingTitlesFixtures.writeMeeting(MeetingTitlesFixtures.meetingMarkdown(date: "2026-02-02"), named: "middle.md", in: directory)
        let newest = MeetingTitlesFixtures.writeMeeting(MeetingTitlesFixtures.meetingMarkdown(date: "2026-03-02"), named: "newest.md", in: directory)
        MeetingTitlesFixtures.writeMeeting(
            MeetingTitlesFixtures.meetingMarkdown(date: "2026-03-03", extraFrontmatter: ["ai_summary_version: \"1\""]),
            named: "done.md", in: directory
        )
        MeetingTitlesFixtures.writeMeeting("---\ncapture_type: dictation_day\n---\nhi\n", named: "dictation.md", in: directory)

        let jobs = MeetingTitlesController.backfillJobs(in: directory)
        assertEqual(jobs.map { $0.transcriptURL.lastPathComponent }, ["newest.md", "middle.md", "old.md"])

        let saved = MeetingTitlesFixtures.writeMeeting(MeetingTitlesFixtures.meetingMarkdown(date: "2026-03-05"), named: "saved.md", in: directory)
        let host = FakeTitlesHost()
        let queue = MeetingTitlesQueue(host: host, environment: .init(isEnabled: { true }, isBusy: { false }))
        var order: [String] = []
        queue.onJobFinished = { job, _ in order.append(job.transcriptURL.lastPathComponent) }
        queue.enqueueBackfill(jobs)
        queue.enqueue(MeetingTitlesJob(transcriptURL: saved, titleRule: .appMade("Meeting with Priya")))
        await queue.waitUntilIdle()
        assertEqual(order, ["saved.md", "newest.md", "middle.md", "old.md"])
        _ = (old, middle, newest)
    }

    await runSuite("Backfill only stands in for the app's own rule title") {
        let directory = MeetingTitlesFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ruleTitled = MeetingTitlesFixtures.writeMeeting(
            MeetingTitlesFixtures.meetingMarkdown(title: "Meeting with Priya and Marcus"), named: "rule.md", in: directory
        )
        let named = MeetingTitlesFixtures.writeMeeting(MeetingTitlesFixtures.meetingMarkdown(title: "Board prep"), named: "named.md", in: directory)
        let host = FakeTitlesHost()
        let queue = MeetingTitlesQueue(host: host, environment: .init(isEnabled: { true }, isBusy: { false }))
        queue.enqueueBackfill([
            MeetingTitlesJob(transcriptURL: ruleTitled, titleRule: .fromFile),
            MeetingTitlesJob(transcriptURL: named, titleRule: .fromFile),
        ])
        await queue.waitUntilIdle()
        let ruleValues = TranscriptFrontmatter.values(in: (try? String(contentsOf: ruleTitled, encoding: .utf8)) ?? "") ?? [:]
        let namedValues = TranscriptFrontmatter.values(in: (try? String(contentsOf: named, encoding: .utf8)) ?? "") ?? [:]
        assertEqual(ruleValues["ai_title"], "Vendor contract renewal")
        assertNil(namedValues["ai_title"], "a title that isn't the rule title may be the person's")
        assertNil(namedValues["title_set_by_user"], "the rescan never infers the rename mark")
        assertNil(ruleValues["title_set_by_user"])
        assertNotNil(namedValues["ai_summary"])
    }

    await runSuite("An unusable reply writes nothing; a missing engine keeps the job for later") {
        let directory = MeetingTitlesFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = MeetingTitlesFixtures.writeMeeting(MeetingTitlesFixtures.meetingMarkdown(), named: "a.md", in: directory)
        let before = try? String(contentsOf: url, encoding: .utf8)
        let host = FakeTitlesHost(engine: FakeTitlesEngine(reply: "not json"))
        let queue = MeetingTitlesQueue(host: host, environment: .init(isEnabled: { true }, isBusy: { false }))
        var results: [MeetingTitlesJobResult] = []
        queue.onJobFinished = { _, result in results.append(result) }
        queue.enqueue(MeetingTitlesJob(transcriptURL: url, titleRule: .appMade("Meeting with Priya")))
        await queue.waitUntilIdle()
        assertEqual(results, [.unusableReply])
        let after = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        assertEqual(TranscriptFrontmatter.body(in: after), TranscriptFrontmatter.body(in: before ?? ""))
        let afterValues = TranscriptFrontmatter.values(in: after) ?? [:]
        assertEqual(afterValues["ai_summary_status"], "no_usable_reply", "recorded, so it isn't sent to the model on every launch")
        assertNil(afterValues["ai_title"])
        assertNil(afterValues["ai_summary"])

        let fresh = MeetingTitlesFixtures.writeMeeting(MeetingTitlesFixtures.meetingMarkdown(), named: "b.md", in: directory)
        let broken = FakeTitlesHost()
        broken.startFails = true
        let retryQueue = MeetingTitlesQueue(host: broken, environment: .init(isEnabled: { true }, isBusy: { false }))
        retryQueue.enqueue(MeetingTitlesJob(transcriptURL: fresh, titleRule: .appMade("Meeting with Priya")))
        await retryQueue.waitUntilIdle()
        assertEqual(retryQueue.activity, .engineUnavailable)
        assertEqual(retryQueue.pending.count, 1, "the job waits for the next try")
        assertNil(TranscriptFrontmatter.values(in: (try? String(contentsOf: fresh, encoding: .utf8)) ?? "")?["ai_summary_version"], "a transient failure records nothing")
    }

    runSuite("Only positive evidence makes a title replaceable; everything else is kept and never marked") {
        typealias Ownership = MeetingTitlesTitleOwnership
        // The app's rule titles, matched by shape so time-zone, 12/24-hour and
        // speaker-naming drift don't matter.
        for title in ["Meeting at 3:05 PM", "Meeting at 15:05", "Meeting at 6:05\u{202F}PM", "Meeting at 3.05 p.m.",
                      "Meeting with Priya", "Meeting with Speaker 1 and Dana", "Quick notes"] {
            assertEqual(Ownership.decide(values: ["title": title], rule: .fromFile), .replaceable(MeetingTitlesKeys.normalizedTitle(title)), title)
        }
        // A pre-feature rename, a calendar title, a renamed import: kept, no mark.
        assertEqual(Ownership.decide(values: ["title": "Board prep"], rule: .fromFile), .keep(carryMark: false))
        assertEqual(Ownership.decide(values: ["title": "Q3 planning"], rule: .fromFile), .keep(carryMark: false), "calendar")
        assertEqual(
            Ownership.decide(values: ["title": "Board prep", "imported_at": "2026-03-04T10:00:00Z"], rule: .fromFile),
            .keep(carryMark: false), "an import renamed on an older build"
        )
        // Positive evidence.
        assertEqual(Ownership.decide(values: ["title": "Voice memo 42"], rule: .appMade("Voice memo 42")), .replaceable("Voice memo 42"))
        assertEqual(
            Ownership.decide(values: ["title": "Pricing", "ai_title_replaces": "Pricing"], rule: .fromFile), .replaceable("Pricing")
        )
        // The title changed between enqueue and run.
        assertEqual(Ownership.decide(values: ["title": "Board prep"], rule: .appMade("Meeting at 9:00 AM")), .keep(carryMark: false))
        // Marks: only carried over, never inferred.
        assertEqual(Ownership.decide(values: ["title": "Board prep"], rule: .userSet), .keep(carryMark: true))
        assertEqual(Ownership.decide(values: ["title": "Meeting with Priya", "title_set_by_user": "true"], rule: .fromFile), .keep(carryMark: false))
        assertEqual(Ownership.decide(values: ["title": "Meeting at 9:00 AM"], rule: .unknown), .keep(carryMark: false))
        assertEqual(Ownership.decide(values: [:], rule: .fromFile), .noTitle)
    }

    runSuite("Before Transcribe again, the old file's evidence is remembered: mark, app-made, or unknown") {
        let directory = MeetingTitlesFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let rule = MeetingTitlesFixtures.writeMeeting(
            MeetingTitlesFixtures.meetingMarkdown(title: "Meeting with Priya and Marcus"), named: "rule.md", in: directory
        )
        let marked = MeetingTitlesFixtures.writeMeeting(
            MeetingTitlesFixtures.meetingMarkdown(title: "Meeting with Priya", extraFrontmatter: ["title_set_by_user: true"]),
            named: "marked.md", in: directory
        )
        let other = MeetingTitlesFixtures.writeMeeting(MeetingTitlesFixtures.meetingMarkdown(title: "Board prep"), named: "other.md", in: directory)
        let aiBase = MeetingTitlesFixtures.writeMeeting(
            MeetingTitlesFixtures.meetingMarkdown(title: "Pricing", extraFrontmatter: ["ai_title_replaces: \"Pricing\""]),
            named: "ai.md", in: directory
        )
        assertEqual(MeetingTitlesController.retranscriptionRule(at: rule), .appMade("Meeting with Priya and Marcus"))
        assertEqual(MeetingTitlesController.retranscriptionRule(at: marked), .userSet)
        assertEqual(MeetingTitlesController.retranscriptionRule(at: other), .unknown)
        assertEqual(MeetingTitlesController.retranscriptionRule(at: aiBase), .appMade("Pricing"))
    }

    await runSuite("After Transcribe again the rename mark comes back, and a later save never hides the name") {
        let directory = MeetingTitlesFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("board.md")
        MeetingTitlesFixtures.writeMeeting(
            MeetingTitlesFixtures.meetingMarkdown(title: "Meeting with Legal", extraFrontmatter: ["title_set_by_user: true"]),
            named: "board.md", in: directory
        )
        let rule = MeetingTitlesController.retranscriptionRule(at: url)
        // Transcribe again: a fresh file keeps the title but drops the mark.
        // (The name even has a rule title's shape; only the mark protects it.)
        MeetingTitlesFixtures.writeMeeting(MeetingTitlesFixtures.meetingMarkdown(title: "Meeting with Legal"), named: "board.md", in: directory)

        // The first job after it fails (an unusable reply) yet still carries the mark over.
        let failing = FakeTitlesHost(engine: FakeTitlesEngine(reply: "not json"))
        let firstQueue = MeetingTitlesQueue(host: failing, environment: .init(isEnabled: { true }, isBusy: { false }))
        firstQueue.enqueue(MeetingTitlesJob(transcriptURL: url, titleRule: rule))
        await firstQueue.waitUntilIdle()
        var values = TranscriptFrontmatter.values(in: (try? String(contentsOf: url, encoding: .utf8)) ?? "") ?? [:]
        assertEqual(values["title_set_by_user"], "true", "the mark survives Transcribe again")

        // A second save event (speaker naming finishing), after a newer
        // version would run again, decides from the file.
        let text = ((try? String(contentsOf: url, encoding: .utf8)) ?? "")
            .replacingOccurrences(of: "ai_summary_version: \"1\"", with: "ai_summary_version: \"0\"")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        let host = FakeTitlesHost()
        let secondQueue = MeetingTitlesQueue(host: host, environment: .init(isEnabled: { true }, isBusy: { false }))
        secondQueue.enqueue(MeetingTitlesJob(transcriptURL: url, titleRule: .fromFile))
        await secondQueue.waitUntilIdle()
        values = TranscriptFrontmatter.values(in: (try? String(contentsOf: url, encoding: .utf8)) ?? "") ?? [:]
        assertNil(values["ai_title"], "ai_title never stands in for the name")
        assertEqual(values["title"], "Meeting with Legal")
        assertNotNil(values["ai_summary"], "the meeting still gets its summary")
    }

    await runSuite("The rescan replaces drifted rule titles, keeps everything else, and never writes the mark") {
        let directory = MeetingTitlesFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let titles = [
            ("tz.md", "Meeting at 6:05 PM", [String]()),             // saved in another time zone
            ("24h.md", "Meeting at 18:05", []),                       // saved with a 24-hour clock
            ("renamed-speakers.md", "Meeting with Speaker 1", []),    // speakers named after the save
            ("old-rename.md", "Board prep", []),                      // renamed before Rename wrote marks
            ("calendar.md", "Q3 planning", []),                       // a calendar title
            ("renamed-import.md", "Partner brief", ["imported_at: 2026-03-04T10:00:00Z"]),
        ]
        for (name, title, extra) in titles {
            MeetingTitlesFixtures.writeMeeting(MeetingTitlesFixtures.meetingMarkdown(title: title, extraFrontmatter: extra), named: name, in: directory)
        }
        let host = FakeTitlesHost()
        let queue = MeetingTitlesQueue(host: host, environment: .init(isEnabled: { true }, isBusy: { false }))
        queue.enqueueBackfill(MeetingTitlesController.backfillJobs(in: directory))
        await queue.waitUntilIdle()
        func values(_ name: String) -> [String: String] {
            TranscriptFrontmatter.values(in: (try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)) ?? "") ?? [:]
        }
        for name in ["tz.md", "24h.md", "renamed-speakers.md"] {
            assertEqual(values(name)["ai_title"], "Vendor contract renewal", "\(name): the app's title is replaceable")
        }
        for name in ["old-rename.md", "calendar.md", "renamed-import.md"] {
            assertNil(values(name)["ai_title"], "\(name): kept")
            assertNotNil(values(name)["ai_summary"], "\(name): still gets the summary")
        }
        for (name, _, _) in titles {
            assertNil(values(name)["title_set_by_user"], "\(name): the rescan never writes the mark")
        }
    }

    await runSuite("A job already running stops when the app gets busy, then runs again once it's free") {
        let directory = MeetingTitlesFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = MeetingTitlesFixtures.writeMeeting(
            MeetingTitlesFixtures.meetingMarkdown(title: "Meeting with Priya and Marcus"), named: "a.md", in: directory
        )
        let controls = RunningJobControls()
        let engine = FakeTitlesEngine()
        engine.blockChat = true
        engine.onChatStarted = { controls.chatStarted(engine: engine) }
        let host = FakeTitlesHost(engine: engine)
        let queue = MeetingTitlesQueue(host: host, environment: .init(
            isEnabled: { true },
            isBusy: { controls.isBusy },
            sleep: { interval in
                if interval == .seconds(5) { controls.busyPoll(engine: engine) }
                try? await Task.sleep(for: .milliseconds(2))
            }
        ))
        var results: [MeetingTitlesJobResult] = []
        queue.onJobFinished = { _, result in results.append(result) }
        queue.enqueue(MeetingTitlesJob(transcriptURL: url, titleRule: .fromFile))
        await queue.waitUntilIdle()
        assertEqual(results, [.cancelled, .written])
        assertEqual(host.events, ["start", "stop", "stop", "start", "stop"], "the helper stops while busy and starts again after")
        assertEqual(TranscriptFrontmatter.values(in: (try? String(contentsOf: url, encoding: .utf8)) ?? "")?["ai_summary_version"], "1")
    }

    await runSuite("Turning the feature off mid-job cancels it and writes nothing") {
        let directory = MeetingTitlesFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = MeetingTitlesFixtures.writeMeeting(
            MeetingTitlesFixtures.meetingMarkdown(title: "Meeting with Priya and Marcus"), named: "a.md", in: directory
        )
        let before = try? String(contentsOf: url, encoding: .utf8)
        let controls = RunningJobControls()
        let engine = FakeTitlesEngine()
        engine.blockChat = true
        engine.onChatStarted = { controls.turnOff() }
        let host = FakeTitlesHost(engine: engine)
        let queue = MeetingTitlesQueue(host: host, environment: .init(
            isEnabled: { controls.isEnabled },
            isBusy: { false },
            sleep: { _ in try? await Task.sleep(for: .milliseconds(2)) }
        ))
        var results: [MeetingTitlesJobResult] = []
        queue.onJobFinished = { _, result in results.append(result) }
        queue.enqueue(MeetingTitlesJob(transcriptURL: url, titleRule: .fromFile))
        await queue.waitUntilIdle()
        assertEqual(results, [.cancelled])
        assertEqual(queue.pending.count, 0, "off: the meeting is not queued again")
        assertEqual(try? String(contentsOf: url, encoding: .utf8), before, "nothing written after the switch went off")
        assertEqual(host.events.last, "stop")
    }

    await runSuite("Every enable and every launch rescans, so meetings saved while off get labeled") {
        let directory = MeetingTitlesFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "meeting-titles-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let models = directory.appendingPathComponent("models", isDirectory: true)
        let store = MeetingTitlesModelStore(asset: tinyInstalledAsset, rootDirectory: models, fetcher: NeverFetcher())
        try? FileManager.default.createDirectory(at: store.modelDirectory, withIntermediateDirectories: true)
        try? Data("GGUF1234".utf8).write(to: store.modelURL)
        let meetings = directory.appendingPathComponent("meetings", isDirectory: true)
        try? FileManager.default.createDirectory(at: meetings, withIntermediateDirectories: true)
        func meeting(_ name: String) -> URL {
            MeetingTitlesFixtures.writeMeeting(
                MeetingTitlesFixtures.meetingMarkdown(title: "Meeting with Priya and Marcus"), named: name, in: meetings
            )
        }
        func isLabeled(_ url: URL) -> Bool {
            TranscriptFrontmatter.values(in: (try? String(contentsOf: url, encoding: .utf8)) ?? "")?["ai_summary_version"] == "1"
        }
        let changed = ChangedFiles()
        let host = FakeTitlesHost()
        let controller = MeetingTitlesController(
            store: store, host: host, defaults: defaults, meetingsDirectory: { meetings },
            onMeetingChanged: { changed.names.append($0.lastPathComponent) }
        )
        assertEqual(controller.modelStatus, .ready)
        let first = meeting("first.md")
        controller.setEnabled(true)
        await controller.waitUntilIdle()
        assertTrue(isLabeled(first))
        assertEqual(changed.names, ["first.md"], "Home is told the meeting changed")

        controller.setEnabled(false)
        let whileOff = meeting("while-off.md")
        controller.noteSavedMeeting(at: whileOff, title: "Meeting with Priya and Marcus")
        await controller.waitUntilIdle()
        assertFalse(isLabeled(whileOff), "off: nothing runs")
        controller.setEnabled(true)
        await controller.waitUntilIdle()
        assertTrue(isLabeled(whileOff), "turning it back on picks it up")

        let beforeRelaunch = meeting("before-relaunch.md")
        let relaunched = MeetingTitlesController(store: store, host: host, defaults: defaults, meetingsDirectory: { meetings })
        assertTrue(relaunched.isEnabled)
        relaunched.launch()
        await relaunched.waitUntilIdle()
        assertTrue(isLabeled(beforeRelaunch), "a launch rescans too")

        // An untouched import is the app's title; only the import's own name counts.
        func titled(_ name: String, _ title: String) -> URL {
            MeetingTitlesFixtures.writeMeeting(
                MeetingTitlesFixtures.meetingMarkdown(title: title, extraFrontmatter: ["imported_at: 2026-03-04T10:00:00Z"]),
                named: name, in: meetings
            )
        }
        let imported = titled("import.md", "Voice memo 42")
        relaunched.noteImportQueued(title: "Voice memo 42")
        relaunched.noteSavedMeeting(at: imported, title: "Voice memo 42")
        await relaunched.waitUntilIdle()
        let importValues = TranscriptFrontmatter.values(in: (try? String(contentsOf: imported, encoding: .utf8)) ?? "") ?? [:]
        assertEqual(importValues["ai_title"], "Vendor contract renewal", "an untouched import is replaceable")
        assertNil(importValues["title_set_by_user"])

        // A title the restyle just generated is the app's; one it kept isn't.
        let generated = titled("generated.md", "Weekly thing")
        relaunched.noteSavedMeeting(at: generated, title: "Weekly thing", titleWasGenerated: true)
        let kept = titled("kept.md", "Weekly thing two")
        relaunched.noteSavedMeeting(at: kept, title: "Weekly thing two", titleWasGenerated: false)
        await relaunched.waitUntilIdle()
        assertNotNil(TranscriptFrontmatter.values(in: (try? String(contentsOf: generated, encoding: .utf8)) ?? "")?["ai_title"])
        let keptValues = TranscriptFrontmatter.values(in: (try? String(contentsOf: kept, encoding: .utf8)) ?? "") ?? [:]
        assertNil(keptValues["ai_title"], "no evidence: the title stays")
        assertNil(keptValues["title_set_by_user"], "and no mark is inferred")
    }

    await runSuite("Turning the feature off clears the queue and stops nothing new from starting") {
        let directory = MeetingTitlesFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "meeting-titles-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let host = FakeTitlesHost()
        let store = MeetingTitlesModelStore(rootDirectory: directory.appendingPathComponent("models"), fetcher: NeverFetcher())
        let controller = MeetingTitlesController(store: store, host: host, defaults: defaults, meetingsDirectory: { directory })
        assertFalse(controller.isEnabled, "off by default")
        let url = MeetingTitlesFixtures.writeMeeting(MeetingTitlesFixtures.meetingMarkdown(), named: "a.md", in: directory)
        controller.noteSavedMeeting(at: url, title: "Meeting with Priya")
        await controller.queue.waitUntilIdle()
        assertEqual(host.events, [], "off: a save never reaches the engine")
        assertEqual(controller.modelStatus, .notDownloaded)
    }
}

@MainActor
private final class ChangedFiles {
    var names: [String] = []
}

/// A model "installed" as 8 bytes so the controller sees it as ready.
private let tinyInstalledAsset = MeetingTitlesModelAsset(
    identifier: "tiny", repository: "example/tiny", revision: "abc", fileName: "tiny.gguf",
    expectedBytes: 8, sha256: String(repeating: "0", count: 64)
)

/// Drives the running-job tests: the first chat makes the app busy; the
/// busy wait frees it again and lets the next chat answer.
private final class RunningJobControls: @unchecked Sendable {
    private let lock = NSLock()
    private var busy = false
    private var enabled = true
    private var started = 0
    private var polls = 0

    var isBusy: Bool { lock.withLock { busy } }
    var isEnabled: Bool { lock.withLock { enabled } }

    func chatStarted(engine: FakeTitlesEngine) {
        lock.withLock {
            started += 1
            if started == 1 { busy = true }
        }
    }

    func busyPoll(engine: FakeTitlesEngine) {
        let free: Bool = lock.withLock {
            polls += 1
            if polls >= 2 { busy = false }
            return !busy
        }
        if free { engine.blockChat = false }
    }

    func turnOff() { lock.withLock { enabled = false } }
}

/// Busy for the first three polls, then free.
private final class BusyState: @unchecked Sendable {
    private let lock = NSLock()
    private var polls = 0

    var isBusy: Bool { lock.withLock { polls < 3 } }

    func poll() { lock.withLock { polls += 1 } }
}

/// A fetcher that must never be called.
private struct NeverFetcher: MeetingTitlesModelFetching {
    func fetch(
        _ request: URLRequest,
        onResponse: @escaping @Sendable (Int, [String: String]) throws -> Void,
        onData: @escaping @Sendable (Data) throws -> Void
    ) async throws {
        throw MeetingTitlesModelFailure.offline
    }
}
