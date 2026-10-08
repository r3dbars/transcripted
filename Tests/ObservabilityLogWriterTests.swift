// EventFileWritePolicy, EventFileWriter, ObservabilityEventCapturePlan, AppLogSink,
// LockedFileAppender, ReliabilityPacketRecorder, ObservabilityLogFilePreparation, and
// ObservabilityTextRedactor are compiled into run-tests.sh's source lists, so most suites call
// them for real, against temp files.
//
// EventReporter drags in CrashReporter/Sentry, so this runner doesn't compile it; its shutdown
// flush order lives in LocalEventShutdownFlush, which is tested here.
//
// One suite still reads source as text (grandfathered):
// - "avoid legacy FileHandle APIs" is an absence-of-API sweep across both the app and the
//   TranscriptedCore package (FileLogger, RetroactiveSpeakerUpdater), which has no runtime signal.

import Foundation

@MainActor
func testObservabilityLogWriter() async {
    runSuite("EventFileWritePolicy buffers only info events") {
        assertTrue(
            EventFileWritePolicy.shouldBuffer(level: "info"),
            "info events should batch to reduce low-priority JSONL write churn"
        )
        assertFalse(
            EventFileWritePolicy.shouldBuffer(level: "warning"),
            "warning events should flush immediately"
        )
        assertFalse(
            EventFileWritePolicy.shouldBuffer(level: "error"),
            "error events should flush immediately"
        )
    }

    runSuite("EventFileWritePolicy flushes info batches at a bounded size") {
        assertFalse(
            EventFileWritePolicy.shouldFlushBufferedInfoEvents(
                count: EventFileWritePolicy.maxBufferedInfoEvents - 1
            ),
            "info events below the batch limit can wait for the short flush timer"
        )
        assertTrue(
            EventFileWritePolicy.shouldFlushBufferedInfoEvents(
                count: EventFileWritePolicy.maxBufferedInfoEvents
            ),
            "info events at the batch limit should flush immediately"
        )
    }

    await runSuite("EventFileWriter writes buffered info events when flushed for shutdown") {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("EventFileWriterTests-\(UUID().uuidString)", isDirectory: true)
        let logURL = root.appendingPathComponent("events.jsonl", isDirectory: false)
        defer { try? fm.removeItem(at: root) }

        let writer = EventFileWriter(fileURL: logURL)
        await writer.append(observabilityTestEvent(level: "info", event: "buffered_info_event"))
        await writer.flushForShutdown()

        let contents = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        assertTrue(
            contents.contains("\"buffered_info_event\""),
            "a buffered info event must reach events.jsonl once shutdown flushes, not die with the process"
        )
        assertEqual(
            contents.split(separator: "\n").count,
            1,
            "the flushed info event should be one JSONL record"
        )
    }

    await runSuite("Local event shutdown flush awaits buffered events and reliability packets") {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("LocalEventShutdownFlushTests-\(UUID().uuidString)", isDirectory: true)
        let logURL = root.appendingPathComponent("events.jsonl", isDirectory: false)
        defer { try? fm.removeItem(at: root) }

        let writer = EventFileWriter(fileURL: logURL)
        await writer.append(observabilityTestEvent(level: "info", event: "buffered_at_quit"))
        var order: [String] = []
        await LocalEventShutdownFlush.run(
            flushEvents: {
                await writer.flushForShutdown()
                order.append("events")
            },
            flushPackets: {
                await Task.yield()
                order.append("packets")
            }
        )

        assertEqual(order, ["events", "packets"], "both flushes finish, events first, before the Quit reply can go out")
        let contents = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        assertTrue(contents.contains("\"buffered_at_quit\""), "the buffered event is on disk when the flush returns")
    }

    runSuite("Local events carry the exact build identity") {
        let plan = ObservabilityEventCapturePlan.make(
            level: .info,
            engine: "capture",
            event: "dictation_toggle_requested",
            message: "toggle",
            context: ["trigger": "physical_key"],
            engineState: nil,
            infoDictionary: [
                "CFBundleVersion": "4321",
                AnalyticsInfoPlistKeys.buildChannelInfoKey: "beta",
                AnalyticsInfoPlistKeys.buildRevisionInfoKey: "abc1234",
            ],
            timestamp: "2026-05-26T12:00:00.000Z",
            appVersion: "1.2.3",
            osVersion: "Version 26.0"
        )
        let environment = ProcessInfo.processInfo.environment
        assertEqual(plan.localEntry.context?["build_version"], "4321", "every local event should carry build_version")
        if environment[AnalyticsRuntimeConfiguration.buildChannelEnvironmentKey] == nil {
            assertEqual(plan.localEntry.context?["build_channel"], "beta", "every local event should carry build_channel")
        }
        if environment[AnalyticsRuntimeConfiguration.buildRevisionEnvironmentKey] == nil {
            assertEqual(
                plan.localEntry.context?["build_revision"],
                "abc1234",
                "local build revision should come from the same validated metadata as PostHog"
            )
        }

        let unstamped = ObservabilityEventCapturePlan.make(
            level: .info,
            engine: "capture",
            event: "dictation_toggle_requested",
            message: "toggle",
            context: [:],
            engineState: nil,
            infoDictionary: nil,
            timestamp: "2026-05-26T12:00:00.000Z",
            appVersion: "1.2.3",
            osVersion: "Version 26.0"
        )
        assertEqual(unstamped.localEntry.context?["build_version"], "unknown", "a missing build number reads unknown, not blank")
        if environment[AnalyticsRuntimeConfiguration.buildRevisionEnvironmentKey] == nil {
            assertEqual(unstamped.localEntry.context?["build_revision"], "unknown", "a missing revision reads unknown")
        }
    }

    runSuite("The reliability recorder gets the raw event, not the locally-blanked copy") {
        let plan = ObservabilityEventCapturePlan.make(
            level: .warning,
            engine: "parakeet",
            event: "recording_interrupted",
            message: "saved /Users/jane/Private/meeting.md",
            context: ["default_input_name": "Studio Mic", "trigger": "stall"],
            engineState: nil,
            infoDictionary: nil,
            timestamp: "2026-05-26T12:00:00.000Z",
            appVersion: "1.2.3",
            osVersion: "Version 26.0"
        )
        assertEqual(
            plan.localEntry.context?["default_input_name"],
            "[redacted-sensitive-value]",
            "the disk copy blanks sensitive keys"
        )
        assertEqual(
            plan.entry.context?["default_input_name"],
            "Studio Mic",
            "the recorder positive-allowlists and redacts itself; it must see the raw value, not \"[redacted-sensitive-value]\""
        )
        assertEqual(plan.entry.message, "saved /Users/jane/Private/meeting.md", "the recorder gets the raw message")
        assertFalse(plan.localEntry.message.contains("/Users/jane"), "the disk copy redacts paths in the message")
    }

    runSuite("Observability file writers tighten pre-existing logs before appending") {
        // The restrict-before-open sequence lives in the shared, compiled
        // ObservabilityLogFilePreparation helper, so run it for real: a
        // pre-existing world-readable log must come back owner-only, with its
        // earlier records intact, before the handle is handed out.
        let fm = FileManager.default
        let preparedRoot = fm.temporaryDirectory.appendingPathComponent("ObservabilityLogPreparationTests-\(UUID().uuidString)", isDirectory: true)
        let preparedLogURL = preparedRoot.appendingPathComponent("events.jsonl", isDirectory: false)
        defer { try? fm.removeItem(at: preparedRoot) }
        try? fm.createDirectory(at: preparedRoot, withIntermediateDirectories: true)
        fm.createFile(atPath: preparedLogURL.path, contents: Data("{\"earlier\":\"record\"}\n".utf8))
        try? fm.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: preparedLogURL.path)

        var createdNewFile = false
        var preparationErrors: [String] = []
        let preparedHandle = ObservabilityLogFilePreparation.openPreparedHandle(
            at: preparedLogURL,
            onDirectoryError: { preparationErrors.append($0) },
            onCreated: { createdNewFile = true },
            onOpenError: { preparationErrors.append($0) }
        )
        let preparedPermissions = (try? fm.attributesOfItem(atPath: preparedLogURL.path))?[.posixPermissions] as? NSNumber
        try? preparedHandle?.close()
        assertNotNil(preparedHandle, "shared log-file preparation should hand back a writable handle for an existing log")
        assertTrue(preparationErrors.isEmpty, "preparing an existing log should not report errors: \(preparationErrors)")
        assertEqual(
            preparedPermissions,
            NSNumber(value: 0o600),
            "shared log-file preparation should chmod even pre-existing logs before opening"
        )
        assertFalse(createdNewFile, "an existing log is tightened in place, not recreated")
        assertEqual(
            (try? String(contentsOf: preparedLogURL, encoding: .utf8)) ?? "",
            "{\"earlier\":\"record\"}\n",
            "tightening permissions must not drop records already in the log"
        )

        // ReliabilityPacketRecorder is compiled into the fast runner, so exercise the
        // real append path: pre-create the JSONL world-readable (0o644), append a packet
        // through the shared test seam, then confirm the file is tightened to owner-only.
        let root = fm.temporaryDirectory.appendingPathComponent("ReliabilityPacketPermissionsTests-\(UUID().uuidString)", isDirectory: true)
        let logURL = root.appendingPathComponent("reliability.jsonl", isDirectory: false)
        defer { try? fm.removeItem(at: root) }

        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        fm.createFile(atPath: logURL.path, contents: nil)
        try? fm.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: logURL.path)

        let packet = ReliabilityPacket(
            timestamp: "2026-05-26T12:00:00.000Z",
            feature: "dictation",
            stage: "transcribe",
            outcome: "success",
            event: "transcription_complete",
            appVersion: "1.2.3",
            osMajor: "26",
            context: ["feature": "dictation", "stage": "transcribe"]
        )

        let appended = ReliabilityPacketRecorder.appendForTesting(packet, to: logURL)
        assertTrue(appended, "reliability test seam should append the packet to the caller-supplied file")

        let attributes = try? fm.attributesOfItem(atPath: logURL.path)
        let permissions = attributes?[.posixPermissions] as? NSNumber
        assertEqual(
            permissions,
            NSNumber(value: 0o600),
            "reliability packets should be chmodded to owner-only even when the JSONL already exists"
        )
    }

    await runSuite("EventFileWriter tightens a pre-existing events.jsonl before appending") {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("EventFileWriterPermissions-\(UUID().uuidString)", isDirectory: true)
        let logURL = root.appendingPathComponent("events.jsonl", isDirectory: false)
        defer { try? fm.removeItem(at: root) }
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        fm.createFile(atPath: logURL.path, contents: Data("{\"earlier\":\"record\"}\n".utf8))
        try? fm.setAttributes([.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: logURL.path)

        let writer = EventFileWriter(fileURL: logURL)
        await writer.append(observabilityTestEvent(level: "warning", event: "warning_event"))
        await writer.flushForShutdown()

        let permissions = (try? fm.attributesOfItem(atPath: logURL.path))?[.posixPermissions] as? NSNumber
        assertEqual(permissions, NSNumber(value: 0o600), "events.jsonl should be owner-only even when it already existed")
        let lines = ((try? String(contentsOf: logURL, encoding: .utf8)) ?? "").split(separator: "\n")
        assertEqual(lines.first.map(String.init), "{\"earlier\":\"record\"}", "earlier records stay")
        assertTrue(lines.count == 2 && lines[1].contains("\"warning_event\""), "the warning is appended right away")
    }

    runSuite("LocalObservabilityPayloadSanitizer redacts local-only sensitive context before disk write") {
        let event = ObservabilityEvent(
            timestamp: "2026-05-26T12:00:00.000Z",
            level: "info",
            engine: "capture",
            event: "dictation_toggle_requested",
            message: "source /Users/jane/Documents/Client Calls/ACME Roadmap.md",
            context: [
                "audio_path": "/Users/jane/Private/customer.wav",
                "default_input_name": "Studio Mic",
                "default_output_name": "Studio Display Speakers",
                "meeting_title": "Customer Roadmap",
                "meeting_url": "https://meet.example.com/private-room",
                "source_app_name": "Private Notes",
                "source_app_bundle": "com.private.short",
                "source_app_bundle_id": "com.private.notes",
                "audio_device": "Jane's AirPods Pro",
                "file_path": "/Users/jane/Documents/Client Calls/ACME Roadmap.md",
                "prompt_text": "Read my private transcript",
                "raw_url": "https://meet.example.com/private-room",
                "speaker_name": "Alice Customer",
                "title": "Customer Roadmap",
                "trigger": "physical_key",
                "transcript_path": "/Users/jane/Private/customer.md",
                "transcript_text": "private transcript words",
            ],
            appVersion: "1.2.3",
            osVersion: "Version 26.0"
        )

        let sanitized = LocalObservabilityPayloadSanitizer.sanitize(event)

        assertFalse(sanitized.message.contains("Client Calls"), "local event messages should redact paths before disk write")
        assertEqual(sanitized.context?["source_app_name"], "[redacted-sensitive-value]", "source app name should be redacted locally")
        assertEqual(sanitized.context?["source_app_bundle_id"], "[redacted-sensitive-value]", "bundle id should be redacted locally")
        assertEqual(sanitized.context?["audio_device"], "[redacted-sensitive-value]", "raw audio device names should be redacted locally")
        assertEqual(sanitized.context?["file_path"], "[redacted-sensitive-value]", "file paths should be redacted locally")
        assertEqual(sanitized.context?["audio_path"], "[redacted-sensitive-value]", "audio paths should be redacted locally")
        assertEqual(sanitized.context?["default_input_name"], "[redacted-sensitive-value]", "raw input names should be redacted locally")
        assertEqual(sanitized.context?["default_output_name"], "[redacted-sensitive-value]", "raw output names should be redacted locally")
        assertEqual(sanitized.context?["meeting_title"], "[redacted-sensitive-value]", "meeting titles should be redacted locally")
        assertEqual(sanitized.context?["meeting_url"], "[redacted-sensitive-value]", "meeting URLs should be redacted locally")
        assertEqual(sanitized.context?["prompt_text"], "[redacted-sensitive-value]", "raw prompt text should be redacted locally")
        assertEqual(sanitized.context?["raw_url"], "[redacted-sensitive-value]", "raw URLs should be redacted locally")
        assertEqual(sanitized.context?["source_app_bundle"], "[redacted-sensitive-value]", "short source app bundle keys should be redacted locally")
        assertEqual(sanitized.context?["speaker_name"], "[redacted-sensitive-value]", "speaker names should be redacted locally")
        assertEqual(sanitized.context?["title"], "[redacted-sensitive-value]", "generic titles should be redacted locally")
        assertEqual(sanitized.context?["transcript_path"], "[redacted-sensitive-value]", "transcript paths should be redacted locally")
        assertEqual(sanitized.context?["transcript_text"], "[redacted-sensitive-value]", "transcript text should be redacted locally")
        assertEqual(sanitized.context?["trigger"], "physical_key", "coarse diagnostics should stay useful")
    }

    runSuite("AppLogSink redacts direct debug-log messages before storing them") {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("AppLogSinkTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let sink = AppLogSink(logFileURL: root.appendingPathComponent("debug.log", isDirectory: false))
        sink.log(
            "DICTATION | started (parakeet, Jane's AirPods Pro) then saved /Users/jane/Private/meeting.md for person@example.com with token sk-private"
        )
        let sanitized = sink.entries.last ?? ""
        assertFalse(sanitized.isEmpty, "the message should be stored for the debug panel")

        assertFalse(sanitized.contains("Jane's AirPods Pro"), "raw device names should not enter debug logs")
        assertFalse(sanitized.contains("/Users/jane/Private/meeting.md"), "absolute paths should not enter debug logs")
        assertFalse(sanitized.contains("person@example.com"), "emails should not enter debug logs")
        assertFalse(sanitized.contains("sk-private"), "tokens should not enter debug logs")
        assertTrue(sanitized.contains("(parakeet, [redacted-sensitive-value])"), "engine/device tuples should keep a safe marker")
        assertTrue(sanitized.contains("[redacted-path]"), "path redaction marker should remain")
        assertTrue(sanitized.contains("[redacted-email]"), "email redaction marker should remain")
    }

    runSuite("Log-file prepare failures hand the console a message with no absolute path") {
        // EventReporter and ReliabilityPacketRecorder print what these callbacks receive.
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ObservabilityPrepareFailure-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        // A regular file where the log directory should be makes directory creation fail.
        let blocker = root.appendingPathComponent("not-a-directory", isDirectory: false)
        fm.createFile(atPath: blocker.path, contents: Data("x".utf8))
        let logURL = blocker.appendingPathComponent("logs", isDirectory: true)
            .appendingPathComponent("events.jsonl", isDirectory: false)

        var messages: [String] = []
        let handle = ObservabilityLogFilePreparation.openPreparedHandle(
            at: logURL,
            onDirectoryError: { messages.append($0) },
            onOpenError: { messages.append($0) }
        )
        try? handle?.close()
        assertNil(handle, "a log under a regular file cannot be opened")
        assertFalse(messages.isEmpty, "the failure should be reported to the caller's console callback")
        for message in messages {
            assertFalse(message.contains(root.path), "console diagnostics must not print the absolute log path: \(message)")
            assertFalse(message.contains(fm.temporaryDirectory.path), "console diagnostics must not print the storage directory: \(message)")
        }
    }

    runSuite("LockedFileAppender swallows write failures instead of crashing the app") {
        // The 1.1.48 crash was EventFileWriter.write → LockedFileAppender.append →
        // NSFileHandle writeData: → objc_exception_throw → terminate. The legacy
        // seekToEndOfFile()/write(_:) raise uncatchable ObjC NSExceptions on I/O
        // failure; the error-returning variants must swallow them. If this suite
        // regressed, appending to a closed handle would abort the whole runner.
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("LockedFileAppenderCrashSafety-\(UUID().uuidString)", isDirectory: true)
        let logURL = root.appendingPathComponent("events.jsonl", isDirectory: false)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        fm.createFile(atPath: logURL.path, contents: nil)
        defer { try? fm.removeItem(at: root) }

        // Open the log read-only, then hand it to the appender as if it were a
        // write handle. The fd is live (so flock + fileDescriptor behave), but the
        // write fails with EBADF — the same failure shape as the 1.1.48 disk write
        // that raised NSFileHandleOperationException from writeData: and crashed.
        guard let readOnlyHandle = try? FileHandle(forReadingFrom: logURL) else {
            assertTrue(false, "expected to open a read handle")
            return
        }
        defer { try? readOnlyHandle.close() }

        // Must return normally — reaching the next line proves no NSException propagated.
        LockedFileAppender.append(Data("{\"crash\":\"safe\"}\n".utf8), to: readOnlyHandle)

        assertTrue(true, "LockedFileAppender.append returned without terminating the process")

        let contents = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        assertTrue(contents.isEmpty, "a failed append should be a no-op on disk, not a crash")
    }

    runSuite("Diagnostic file writers avoid the NSException-throwing legacy FileHandle APIs") {
        // Guards every shipped logging site the 1.1.49 stability pass converted. The
        // legacy seekToEndOfFile()/write(_:)/readData(ofLength:) raise uncatchable
        // ObjC NSExceptions on I/O failure; a revert to any of them re-arms the crash.
        let crashProneAPIs = [
            "seekToEndOfFile()",
            "readData(ofLength:",
            ".write(data)",
            "synchronizeFile()",
            "closeFile()",
        ]
        let sites = [
            "Sources/Observability/LockedFileAppender.swift",
            "Sources/Observability/EventReporter.swift",
            "Sources/Observability/ReliabilityPacketRecorder.swift",
            "Sources/Observability/AppLogSink.swift",
            "Sources/TranscriptedCore/Logging/FileLogger.swift",
            "Sources/TranscriptedCore/Speaker/RetroactiveSpeakerUpdater.swift",
        ]
        for site in sites {
            let source = strippedOfComments(readObservabilityTestRepoTextFile(site))
            assertFalse(source.isEmpty, "expected to read \(site)")
            for api in crashProneAPIs {
                assertFalse(
                    source.contains(api),
                    "\(site) must not call the NSException-throwing \(api) outside comments"
                )
            }
        }
    }

    runSuite("LockedFileAppender keeps concurrent log records line-delimited") {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ObservabilityLogWriterTests-\(UUID().uuidString)", isDirectory: true)
        let logURL = root.appendingPathComponent("events.jsonl", isDirectory: false)
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        fm.createFile(atPath: logURL.path, contents: nil)

        guard let first = try? FileHandle(forWritingTo: logURL),
              let second = try? FileHandle(forWritingTo: logURL) else {
            assertTrue(false, "expected to open two file handles")
            return
        }

        let queue = DispatchQueue(label: "test.locked-file-appender", attributes: .concurrent)
        let group = DispatchGroup()
        let expectedCount = 200

        for index in 0..<expectedCount {
            group.enter()
            queue.async {
                let prefix = index.isMultiple(of: 2) ? "a" : "b"
                let payload = String(repeating: prefix, count: 2_048)
                let line = "{\"index\":\(index),\"payload\":\"\(payload)\"}\n"
                LockedFileAppender.append(Data(line.utf8), to: index.isMultiple(of: 2) ? first : second)
                group.leave()
            }
        }

        _ = group.wait(timeout: .now() + 5)
        try? first.close()
        try? second.close()

        let content = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        assertEqual(lines.count, expectedCount, "each concurrent append should produce exactly one line")

        let validLines = lines.filter { line in
            line.hasPrefix("{\"index\":") && (line.hasSuffix("\"}") || line.hasSuffix("\"}\r"))
        }
        assertEqual(validLines.count, expectedCount, "concurrent appends should not concatenate or split JSONL records")
    }
}

private func observabilityTestEvent(level: String, event: String) -> ObservabilityEvent {
    ObservabilityEvent(
        timestamp: "2026-05-26T12:00:00.000Z",
        level: level,
        engine: "capture",
        event: event,
        message: "test",
        context: ["trigger": "physical_key"],
        appVersion: "1.2.3",
        osVersion: "Version 26.0"
    )
}

private func readObservabilityTestRepoTextFile(_ relativePath: String) -> String {
    let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        .appendingPathComponent(relativePath)
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}

// Drop `//` line comments so a contract check for a crash-prone API name does not
// trip on the explanatory comments that intentionally reference it. Coarse (it does
// not model strings), which is fine for the diagnostic-logging sources it scans.
private func strippedOfComments(_ source: String) -> String {
    source
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map { line -> Substring in
            if let range = line.range(of: "//") {
                return line[line.startIndex..<range.lowerBound]
            }
            return line
        }
        .joined(separator: "\n")
}
