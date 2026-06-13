import Combine
import Foundation

/// Phase of the in-app live transcript shown in the meeting overlay drawer.
enum LiveMeetingTranscriptFeedPhase: Equatable {
    case idle
    /// Live session started, streaming ASR still initializing.
    case starting
    /// Streaming ASR is producing text.
    case live
    /// A live session exists but live ASR is not running for this meeting
    /// (background transcription contention, or a mid-recording late join).
    /// The note is user-facing drawer copy.
    case deferred(String)
    case failed(String)
    case stopped
}

/// Main-actor store behind the meeting overlay's embedded live transcript.
///
/// `LiveMeetingTranscriber` channels push the same accepted streaming updates
/// here that they append to the agent sidecar files, so the overlay renders
/// from memory instead of polling `live_transcript.md`. Final lines
/// accumulate (capped); the newest partial per source is kept separately so
/// provisional text replaces itself instead of stacking.
@MainActor
final class LiveMeetingTranscriptFeed: ObservableObject {
    static let maxFinalEntries = 200

    @Published private(set) var phase: LiveMeetingTranscriptFeedPhase = .idle
    @Published private(set) var finalEntries: [LiveMeetingCodexTranscriptEntry] = []
    @Published private(set) var partialEntries: [LiveMeetingCodexSource: LiveMeetingCodexTranscriptEntry] = [:]

    func beginStarting() {
        phase = .starting
        finalEntries = []
        partialEntries = [:]
    }

    func beginDeferred(note: String) {
        phase = .deferred(note)
        finalEntries = []
        partialEntries = [:]
    }

    func markLive() {
        guard phase == .starting || phase == .live else { return }
        phase = .live
    }

    func markFailed(note: String) {
        phase = .failed(note)
        partialEntries = [:]
    }

    func ingest(_ entry: LiveMeetingCodexTranscriptEntry) {
        guard phase != .idle, phase != .stopped else { return }

        if entry.isFinal {
            partialEntries[entry.source] = nil
            finalEntries.append(entry)
            if finalEntries.count > Self.maxFinalEntries {
                finalEntries.removeFirst(finalEntries.count - Self.maxFinalEntries)
            }
        } else {
            partialEntries[entry.source] = entry
        }
    }

    func finish() {
        guard phase != .idle else { return }
        partialEntries = [:]
        phase = .stopped
    }

    func reset() {
        phase = .idle
        finalEntries = []
        partialEntries = [:]
    }
}
