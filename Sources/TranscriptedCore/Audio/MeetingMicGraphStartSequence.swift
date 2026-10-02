import Foundation

/// The order every meeting mic engine start and mic recovery follows.
///
/// 1. `settle` re-reads the input route and rebuilds the graph if it moved.
///    Opening an AirPods mic flips them to their 24 kHz call profile a moment
///    after the graph saw 48 kHz, so this comes first.
/// 2. `createSegment` sizes the mic file (or recovery segment) from the
///    settled graph. Sizing it from the unsettled one records at the wrong rate.
/// 3. `checkFormat` then `installTap`, together inside `withinGraphLock`. The
///    format is rechecked right before the tap goes in, because the route can
///    still move after the file was made.
///
/// `Audio.startAudioCapture` (engine path) and `Audio.recoverFromDeviceChange`
/// both run through here. The pinned recorder never builds an engine graph,
/// so it doesn't.
///
/// Errors come back as `Failure`, tagged with the step that threw, so callers
/// keep their per-step handling. Errors thrown by `withinGraphLock` itself
/// (stale session, engine start) are tagged `.installTap`.
enum MeetingMicGraphStartSequence {
    enum Step: Equatable, Sendable {
        case settle
        case createSegment
        case checkFormat
        case installTap
    }

    struct Failure: Error {
        let step: Step
        let underlying: Error
    }

    static func run<Graph, Segment>(
        _ graph: Graph,
        settle: (Graph) throws -> Graph,
        createSegment: (Graph) throws -> Segment,
        checkFormat: (Graph) throws -> Void,
        installTap: (Graph, Segment) throws -> Void,
        withinGraphLock: (Graph, () throws -> Void) throws -> Void
    ) throws -> (graph: Graph, segment: Segment) {
        let settled = try tagging(.settle) { try settle(graph) }
        let segment = try tagging(.createSegment) { try createSegment(settled) }
        // The step closures only run inside this call; Swift needs to be
        // told that before they can be captured by the locked body.
        try withoutActuallyEscaping(checkFormat) { checkFormat in
            try withoutActuallyEscaping(installTap) { installTap in
                try tagging(.installTap) {
                    try withinGraphLock(settled) {
                        try tagging(.checkFormat) { try checkFormat(settled) }
                        try tagging(.installTap) { try installTap(settled, segment) }
                    }
                }
            }
        }
        return (settled, segment)
    }

    private static func tagging<T>(_ step: Step, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure(step: step, underlying: error)
        }
    }
}
