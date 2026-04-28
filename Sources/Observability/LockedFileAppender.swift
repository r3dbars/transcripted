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

        handle.seekToEndOfFile()
        handle.write(data)
    }
}
