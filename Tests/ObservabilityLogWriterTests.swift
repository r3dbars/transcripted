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
        let appSource = readObservabilityTestRepoTextFile("Sources/TranscriptedApp.swift")

        assertTrue(
            reporterSource.contains("func flushLocalEventsForShutdown() async"),
            "buffered local info events should have an explicit shutdown flush path"
        )
        assertTrue(
            appSource.contains("await EventReporter.shared.flushLocalEventsForShutdown()"),
            "termination cleanup should flush buffered event logs before replying to AppKit"
        )
    }

    runSuite("Observability file writers tighten pre-existing logs before appending") {
        let eventReporter = readObservabilityTestRepoTextFile("Sources/Observability/EventReporter.swift")
        let reliabilityRecorder = readObservabilityTestRepoTextFile("Sources/Observability/ReliabilityPacketRecorder.swift")

        assertTrue(
            eventReporter.contains("FileManager.default.restrictFileToOwnerOnly(at: fileURL)\n\n        do {"),
            "events.jsonl should be chmodded even when it already exists"
        )
        assertTrue(
            reliabilityRecorder.contains("FileManager.default.restrictFileToOwnerOnly(at: fileURL)\n\n        do {"),
            "reliability packets should be chmodded even when the JSONL already exists"
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
                "source_app_name": "Private Notes",
                "source_app_bundle_id": "com.private.notes",
                "audio_device": "Jane's AirPods Pro",
                "file_path": "/Users/jane/Documents/Client Calls/ACME Roadmap.md",
                "trigger": "physical_key",
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
        assertEqual(sanitized.context?["trigger"], "physical_key", "coarse diagnostics should stay useful")
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
