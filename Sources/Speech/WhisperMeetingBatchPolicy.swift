// WhisperMeetingBatchPolicy.swift
// How many segments of a Whisper meeting batch WhisperKit decodes at once.
//
// WhisperKit's batch API (`transcribeWithResults(audioArrays:decodeOptions:)`)
// starts `concurrentWorkerCount` `transcribe` calls at the same time on one
// WhisperKit instance, and 0 means every segment at once. Those calls share
// the instance's `progress`, timings, and text decoder state without a lock.
// The worker count lives here, apart from WhisperEngine (which pulls in
// WhisperKit), so the fast test runner can check it.

import Foundation

enum WhisperMeetingBatchPolicy {
    /// How many 30 s Whisper windows of speech one meeting batch holds. This
    /// sets the batch size only, not how many decode at once.
    static let windowsPerBatch = 4

    /// The `concurrentWorkerCount` a meeting batch passes to WhisperKit.
    /// One: parallel decodes on one instance race on its shared `progress`
    /// and crashed Whisper meetings (APPLE-MACOS-45). Not 0, which means
    /// all at once.
    static let concurrentWorkerCount = 1

    /// The most segments WhisperKit decodes at the same time for a batch of
    /// `segmentCount` segments, with WhisperKit's meaning of the worker
    /// count: 0 runs the whole batch at once, otherwise it runs that many.
    static func simultaneousDecodes(segmentCount: Int) -> Int {
        guard segmentCount > 0 else { return 0 }
        guard concurrentWorkerCount > 0 else { return segmentCount }
        return min(segmentCount, concurrentWorkerCount)
    }
}
