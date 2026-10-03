import Foundation

/// Decides when a transcribing `meeting_pipeline_phase` diagnostics line is
/// written: once on entering transcribing, then once each time raw pipeline
/// progress moves into a new quarter. Plain Doubles only, so it stays testable
/// and names no Core type.
///
/// Both sides must be raw pipeline progress (0...1). The old gate compared the
/// UI-mapped `DisplayStatus.progress` (0.15 + 0.6p) with raw p, which land in
/// different quarters for ~42% of the range, so nearly every 0.1% tick logged.
enum MeetingPipelinePhaseCadence {
    /// - Parameters:
    ///   - previousTranscribingProgress: raw progress of the previous status if
    ///     it was also transcribing, nil otherwise (entering always records).
    ///   - progress: raw progress of the new transcribing status.
    static func shouldRecord(previousTranscribingProgress: Double?, progress: Double) -> Bool {
        guard let previous = previousTranscribingProgress else { return true }
        return quarter(of: previous) != quarter(of: progress)
    }

    static func quarter(of progress: Double) -> Int {
        Int(progress * 4)
    }
}
