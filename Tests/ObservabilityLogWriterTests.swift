import Foundation

func testObservabilityLogWriter() {
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

    runSuite("EventReporter exposes shutdown flushing for buffered info events") {
        let reporterSource = readObservabilityTestRepoTextFile("Sources/Observability/EventReporter.swift")
        let reliabilityRecorderSource = readObservabilityTestRepoTextFile("Sources/Observability/ReliabilityPacketRecorder.swift")
        let appSource = readObservabilityTestRepoTextFile("Sources/TranscriptedApp.swift")

        assertTrue(
            reporterSource.contains("func flushLocalEventsForShutdown() async"),
            "buffered local info events should have an explicit shutdown flush path"
        )
        assertTrue(
            reliabilityRecorderSource.contains("static func flushForShutdown() async"),
            "reliability packet writes should also have an explicit shutdown flush path"
        )
        assertTrue(
            reporterSource.contains("await ReliabilityPacketRecorder.flushForShutdown()"),
            "the shared local-event shutdown flush should drain reliability packet writes too"
        )
        assertTrue(
            appSource.contains("await EventReporter.shared.flushLocalEventsForShutdown()"),
            "termination cleanup should flush buffered event logs before replying to AppKit"
        )
    }

    runSuite("Observability file writers tighten pre-existing logs before appending") {
        // EventReporter.swift is not compiled into the fast runner, so keep its
        // restrict-before-append guarantee as a source-read assertion.
        let eventReporter = readObservabilityTestRepoTextFile("Sources/Observability/EventReporter.swift")
        assertTrue(
            eventReporter.contains("FileManager.default.restrictFileToOwnerOnly(at: fileURL)\n\n        do {"),
            "events.jsonl should be chmodded even when it already exists"
        )

        // ReliabilityPacketRecorder is compiled into the fast runner, so exercise the
        // real append path: pre-create the JSONL world-readable (0o644), append a packet
        // through the shared test seam, then confirm the file is tightened to owner-only.
        let fm = FileManager.default
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

    runSuite("AppLogger routes direct debug-log messages through the shared redactor") {
        let appLoggerSource = readObservabilityTestRepoTextFile("Sources/Observability/AppLogger.swift")
        assertTrue(
            appLoggerSource.contains("ObservabilityTextRedactor.redact(message)"),
            "AppLogger.log should scrub direct debug messages before storing or writing"
        )

        let sanitized = ObservabilityTextRedactor.redact(
            "DICTATION | started (parakeet, Jane's AirPods Pro) then saved /Users/jane/Private/meeting.md for person@example.com with token sk-private"
        )

        assertFalse(sanitized.contains("Jane's AirPods Pro"), "raw device names should not enter debug logs")
        assertFalse(sanitized.contains("/Users/jane/Private/meeting.md"), "absolute paths should not enter debug logs")
        assertFalse(sanitized.contains("person@example.com"), "emails should not enter debug logs")
        assertFalse(sanitized.contains("sk-private"), "tokens should not enter debug logs")
        assertTrue(sanitized.contains("(parakeet, [redacted-sensitive-value])"), "engine/device tuples should keep a safe marker")
        assertTrue(sanitized.contains("[redacted-path]"), "path redaction marker should remain")
        assertTrue(sanitized.contains("[redacted-email]"), "email redaction marker should remain")
    }

    runSuite("Observability file writer console diagnostics avoid absolute paths") {
        let eventReporter = readObservabilityTestRepoTextFile("Sources/Observability/EventReporter.swift")
        let reliabilityRecorder = readObservabilityTestRepoTextFile("Sources/Observability/ReliabilityPacketRecorder.swift")

        assertFalse(
            eventReporter.contains("\\(storageDir.path)"),
            "EventReporter stderr diagnostics should not print absolute storage paths"
        )
        assertFalse(
            eventReporter.contains("\\(fileURL.path)"),
            "EventReporter stdout/stderr diagnostics should not print absolute log paths"
        )
        assertFalse(
            reliabilityRecorder.contains("\\(storageDir.path)"),
            "Reliability recorder stderr diagnostics should not print absolute storage paths"
        )
        assertFalse(
            reliabilityRecorder.contains("\\(fileURL.path)"),
            "Reliability recorder stderr diagnostics should not print absolute log paths"
        )
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
            "Sources/Observability/AppLogger.swift",
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
