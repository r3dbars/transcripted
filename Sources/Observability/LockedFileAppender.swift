// LockedFileAppender.swift
// Cross-process-safe append helper for local diagnostic logs.

import Foundation

enum LockedFileAppender {
    private static let processLock = NSLock()

    static func append(_ data: Data, to handle: FileHandle) {
        processLock.lock()
        defer { processLock.unlock() }

        let fd = handle.fileDescriptor
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }

        do {
            // Use the Swift error-returning variants. The legacy
            // seekToEndOfFile()/write(_:) raise ObjC NSExceptions on I/O failure
            // (disk full, closed fd, rotated file), which Swift cannot catch — so
            // they hard-crash the app. Diagnostic logging must never crash the app.
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            fputs("⚠️ LOG | diagnostic append failed: \(ObservabilityTextRedactor.redact(error.localizedDescription))\n", stderr)
        }
    }
}
