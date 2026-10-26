// lint-fixture-path: Tools/SpeakerEvalHarness/Sources/speaker-eval-harness/Fixture.swift
// The fix: resolve the set root and refuse any target whose parent isn't under it.
import Foundation

enum StaleResults {
    static func remove(_ meetings: Set<String>, setDirectory: URL, fileManager: FileManager = .default) throws {
        let root = setDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let targets = try meetings.map { meeting -> URL in
            let target = setDirectory.appendingPathComponent(meeting, isDirectory: true)
                .appendingPathComponent("lab_result.json").standardizedFileURL
            let parent = target.deletingLastPathComponent().resolvingSymlinksInPath().path
            guard parent.hasPrefix(root + "/") else {
                throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: target.path])
            }
            return target
        }
        for target in targets where fileManager.fileExists(atPath: target.path) {
            try fileManager.removeItem(at: target)
        }
    }
}
