// AudioImportQueue.swift
// Files the user asked to transcribe that haven't been handed to the meeting
// import flow yet.
//
// MeetingSessionController.importAudioFile(from:) takes one file and refuses
// while a meeting is capturing (starting/recording/stopping) so it can't
// disturb the live recording's state. The app keeps this FIFO in front of it:
// the open panel and drag and drop both add here, the app feeds files one at a
// time while nothing is capturing, and anything added during a recording
// waits until that recording stops. Once handed over, the meeting
// transcription queue owns the file like any other import.

import Foundation
import UniformTypeIdentifiers

struct AudioImportQueue {
    private(set) var pending: [URL] = []

    var isEmpty: Bool { pending.isEmpty }
    var count: Int { pending.count }

    /// Adds files in order, skipping any already waiting. Returns how many
    /// were actually added.
    @discardableResult
    mutating func add(_ urls: [URL]) -> Int {
        var added = 0
        for url in urls {
            let key = Self.identity(of: url)
            guard !pending.contains(where: { Self.identity(of: $0) == key }) else { continue }
            pending.append(url)
            added += 1
        }
        return added
    }

    mutating func popFirst() -> URL? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    /// Puts a file back at the head of the line, used when a hand-off was
    /// refused because a recording started in the meantime.
    mutating func pushFront(_ url: URL) {
        let key = Self.identity(of: url)
        pending.removeAll { Self.identity(of: $0) == key }
        pending.insert(url, at: 0)
    }

    /// The files in `urls` the import flow can take: regular files whose type
    /// is audio or audio+video (the same types the open panel allows). Folders
    /// and everything else are dropped. Order is kept.
    static func importableFiles(from urls: [URL]) -> [URL] {
        urls.filter { url in
            guard url.isFileURL, !url.hasDirectoryPath else { return false }
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                return false
            }
            return isImportableType(url)
        }
    }

    static func isImportableType(_ url: URL) -> Bool {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)
            ?? UTType(filenameExtension: url.pathExtension)
        guard let type else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .audiovisualContent)
    }

    private static func identity(of url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
