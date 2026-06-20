// CaptureLibraryChangeBroadcaster.swift
// Single source of truth for "the saved meeting capture files just changed on
// disk" notifications.
//
// Background post-save work mutates the on-disk artifacts of an already-saved
// meeting: `MeetingAudioStorageManager` recompresses retained WAV audio to M4A
// (deleting the WAV), and `MeetingTranscriptStyler` can rename the transcript
// `.md` plus its `audio/<stem>_audio/` directory. Home scans the capture folder
// once and caches each meeting's transcript + audio URLs, so those mutations can
// leave Home holding URLs that no longer exist (stale-reveal / rename races).
//
// Producers call `noteArtifactsChanged(transcriptURLs:)` after they change files.
// The broadcaster coalesces bursts (recompression fires once per file and again
// during launch/settings backfill) into a single debounced
// `.meetingCaptureArtifactsDidChange` notification so Home can re-resolve its
// cache from disk. Passing an empty `transcriptURLs` means "something changed but
// the exact transcripts are unknown" (a library-wide backfill) and asks
// subscribers to refresh everything they show.

import Foundation

extension Notification.Name {
    /// Posted (debounced) after background post-save processing changes a saved
    /// meeting's on-disk audio or transcript files. `userInfo` carries the
    /// affected transcript identifiers under
    /// `CaptureLibraryChange.affectedTranscriptIDsKey` (an empty array means a
    /// library-wide change of unknown scope).
    static let meetingCaptureArtifactsDidChange = Notification.Name(
        "Transcripted.MeetingCaptureArtifactsDidChange"
    )
}

enum CaptureLibraryChange {
    /// `userInfo` key holding `[String]` transcript identifiers
    /// (`URL.standardizedFileURL.path`). An empty array means the change scope is
    /// library-wide / unknown.
    static let affectedTranscriptIDsKey = "affectedTranscriptIDs"

    /// Stable identifier for a transcript URL, matching `RecentMeetingItem.id`
    /// (the transcript path) so subscribers can correlate by id when they want to.
    static func id(for transcriptURL: URL) -> String {
        transcriptURL.standardizedFileURL.path
    }
}

/// Coalesces a burst of "capture files changed" producer calls into a single
/// debounced notification. `@MainActor` so the pending state needs no locking;
/// producers running off the main actor hop on with `MainActor.run`.
@MainActor
final class CaptureLibraryChangeBroadcaster {
    static let shared = CaptureLibraryChangeBroadcaster()

    private let notificationCenter: NotificationCenter
    private let debounceInterval: TimeInterval
    private let scheduleFlush: (@escaping @MainActor () -> Void) -> Void

    private var pendingIDs: Set<String> = []
    private var hasLibraryWidePending = false
    private var isFlushScheduled = false

    /// - Parameters:
    ///   - debounceInterval: trailing-edge coalescing window for the default
    ///     scheduler.
    ///   - scheduleFlush: injection seam for tests — receives the flush work and
    ///     decides when to run it. Defaults to a `Task.sleep`-based trailing
    ///     debounce on the main actor.
    init(
        notificationCenter: NotificationCenter = .default,
        debounceInterval: TimeInterval = 0.25,
        scheduleFlush: ((@escaping @MainActor () -> Void) -> Void)? = nil
    ) {
        self.notificationCenter = notificationCenter
        self.debounceInterval = debounceInterval
        self.scheduleFlush = scheduleFlush ?? { work in
            let nanoseconds = UInt64(max(0, debounceInterval) * 1_000_000_000)
            Task { @MainActor in
                if nanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: nanoseconds)
                }
                work()
            }
        }
    }

    /// Record that the on-disk artifacts for the given saved transcripts changed.
    /// An empty array signals a library-wide change of unknown scope. Repeated
    /// calls within the debounce window coalesce into a single notification that
    /// carries the union of affected identifiers.
    func noteArtifactsChanged(transcriptURLs: [URL]) {
        if transcriptURLs.isEmpty {
            hasLibraryWidePending = true
        } else {
            for url in transcriptURLs {
                pendingIDs.insert(CaptureLibraryChange.id(for: url))
            }
        }
        scheduleFlushIfNeeded()
    }

    /// Convenience for the library-wide / unknown-scope case (e.g. launch and
    /// settings backfill passes that touch many meetings).
    func noteLibraryWideChange() {
        noteArtifactsChanged(transcriptURLs: [])
    }

    private func scheduleFlushIfNeeded() {
        guard !isFlushScheduled else { return }
        guard hasLibraryWidePending || !pendingIDs.isEmpty else { return }
        isFlushScheduled = true
        scheduleFlush { [weak self] in
            self?.flush()
        }
    }

    /// Emit the coalesced notification for everything noted since the last flush.
    /// Idempotent: a flush with nothing pending posts nothing.
    func flush() {
        isFlushScheduled = false
        guard hasLibraryWidePending || !pendingIDs.isEmpty else { return }

        let ids = hasLibraryWidePending ? [] : pendingIDs.sorted()
        pendingIDs.removeAll(keepingCapacity: true)
        hasLibraryWidePending = false

        notificationCenter.post(
            name: .meetingCaptureArtifactsDidChange,
            object: nil,
            userInfo: [CaptureLibraryChange.affectedTranscriptIDsKey: ids]
        )
    }
}
