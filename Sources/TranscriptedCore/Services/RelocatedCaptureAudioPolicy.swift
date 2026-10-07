import Foundation

/// Decides whether a failed-queue row whose audio sits outside the current
/// capture library should be kept (hidden but durable) instead of rejected.
///
/// Keep it when the audio still looks like real archived capture audio in a
/// library the user moved away from: the mic path sits in a `<stem>_audio`
/// directory, and any optional system path uses that same archive layout.
/// The mic must either still exist, or its old library's audio folder (the
/// parent of `<stem>_audio`) must be unreachable right now — an unmounted
/// drive or offline volume — so the audio can't be checked and the row waits
/// until it can. When that folder is reachable and the mic is gone, the audio
/// is provably missing and the row is dropped. The system file may be
/// missing; once that library is active again, normal reconciliation drops
/// the optional reference and keeps the meeting retryable from its mic track.
/// Deliberately narrow so tampered paths — `/tmp`, `..` traversal, arbitrary
/// home files — are still rejected outright.
enum RelocatedCaptureAudioPolicy {
    /// Both URLs must already be canonical (standardized, symlinks resolved).
    static func shouldKeep(
        micAudioURL micURL: URL,
        systemAudioURL systemURL: URL?,
        fileManager: FileManager = .default
    ) -> Bool {
        let archiveDirectory = micURL.deletingLastPathComponent()
        guard archiveDirectory.lastPathComponent.hasSuffix("_audio") else {
            return false
        }
        if !fileManager.fileExists(atPath: micURL.path) {
            var isDirectory: ObjCBool = false
            let oldAudioFolder = archiveDirectory.deletingLastPathComponent()
            let oldLibraryReachable = fileManager.fileExists(atPath: oldAudioFolder.path, isDirectory: &isDirectory)
                && isDirectory.boolValue
            guard !oldLibraryReachable else { return false }
        }
        guard let systemURL else { return true }
        return systemURL.deletingLastPathComponent().lastPathComponent.hasSuffix("_audio")
    }
}
