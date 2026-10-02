// EventFileWriter.swift
// Actor that appends EventReporter's local events to events.jsonl: info
// events batch briefly, warnings and errors flush at once.

import Foundation

actor EventFileWriter {
    private let fileURL: URL
    private var handle: FileHandle?
    private var isPrepared = false
    private var approximateSize: UInt64 = 0
    private var bufferedInfoEventLines: [Data] = []
    private var infoFlushTask: Task<Void, Never>?
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = []  // Compact — one record per line
        return e
    }()

    static func defaultFileURL() -> URL {
        FileManager.default.transcriptedLogsDirURL.appendingPathComponent("events.jsonl")
    }

    /// `fileURL` is for tests; the app always writes the default events.jsonl.
    init(fileURL: URL = EventFileWriter.defaultFileURL()) {
        self.fileURL = fileURL
    }

    func append(_ event: ObservabilityEvent) {
        guard let lineData = lineData(for: event) else { return }
        guard prepareIfNeeded() else { return }

        if EventFileWritePolicy.shouldBuffer(level: event.level) {
            bufferedInfoEventLines.append(lineData)
            if EventFileWritePolicy.shouldFlushBufferedInfoEvents(count: bufferedInfoEventLines.count) {
                flushBufferedInfoEvents()
            } else {
                scheduleInfoFlush()
            }
            return
        }

        flushBufferedInfoEvents()
        write(lineData)
    }

    func flushForShutdown() {
        guard prepareIfNeeded() else { return }
        flushBufferedInfoEvents()
        try? handle?.synchronize()
    }

    private func lineData(for event: ObservabilityEvent) -> Data? {
        let data: Data
        do {
            data = try encoder.encode(event)
        } catch {
            fputs("⚠️ EVENT | failed to encode event '\(event.event)': \(error.localizedDescription)\n", stderr)
            return nil
        }

        var lineData = data
        lineData.append(0x0A)
        return lineData
    }

    private func scheduleInfoFlush() {
        guard infoFlushTask == nil else { return }
        let delay = EventFileWritePolicy.infoFlushDelayNanoseconds
        infoFlushTask = Task {
            try? await Task.sleep(nanoseconds: delay)
            self.flushBufferedInfoEvents()
        }
    }

    private func flushBufferedInfoEvents() {
        guard !bufferedInfoEventLines.isEmpty else { return }

        let task = infoFlushTask
        infoFlushTask = nil
        task?.cancel()

        let payload = bufferedInfoEventLines.reduce(into: Data()) { partial, line in
            partial.append(line)
        }
        bufferedInfoEventLines.removeAll(keepingCapacity: true)
        write(payload)
    }

    private func write(_ lineData: Data) {
        if handle == nil {
            // A rotation earlier in this same append cycle (the info-buffer
            // flush crossing the threshold) closes the handle; reopen here so
            // the warning/error event that triggered the flush is not lost.
            guard prepareIfNeeded() else { return }
        }
        if let handle {
            LockedFileAppender.append(lineData, to: handle)
            approximateSize += UInt64(lineData.count)
            if approximateSize > TranscriptedConstants.jsonlLogRotationThreshold {
                // Close so the next write re-prepares, which rotates the file.
                try? handle.close()
                self.handle = nil
                isPrepared = false
            }
        }
    }

    private func prepareIfNeeded() -> Bool {
        guard !isPrepared else { return true }

        guard let prepared = ObservabilityLogFilePreparation.openPreparedHandle(
            at: fileURL,
            onDirectoryError: { fputs("⚠️ EVENT | failed to create local event directory: \($0)\n", stderr) },
            onRotated: { fputs("📊 EVENT | rotated events.jsonl\n", stderr) },
            onCreated: { fputs("📊 EVENT | created events.jsonl\n", stderr) },
            onOpenError: { fputs("⚠️ EVENT | failed to open local event log: \($0)\n", stderr) }
        ) else {
            return false
        }

        do {
            handle = prepared
            // seekToEnd() (error-returning) instead of the legacy seekToEndOfFile(),
            // which raises an uncatchable ObjC NSException on failure. Any error here
            // is caught below and treated as a failed prepare rather than a crash.
            approximateSize = try prepared.seekToEnd()
            isPrepared = true
            return true
        } catch {
            fputs("⚠️ EVENT | failed to open local event log: \(ObservabilityTextRedactor.redact(error.localizedDescription))\n", stderr)
            try? prepared.close()
            handle = nil
            return false
        }
    }

    deinit {
        if let handle, !bufferedInfoEventLines.isEmpty {
            let payload = bufferedInfoEventLines.reduce(into: Data()) { partial, line in
                partial.append(line)
            }
            LockedFileAppender.append(payload, to: handle)
        }
        infoFlushTask?.cancel()
        try? handle?.close()
    }
}

