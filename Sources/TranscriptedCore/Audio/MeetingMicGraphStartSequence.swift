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

    /// Meeting start's version of `run`. A failed format check, tap install
    /// or engine start (an `.checkFormat`/`.installTap` failure) gets one
    /// `rebuild`: a fresh graph that runs settle and the locked steps again.
    /// It records into the segment already made when `retryGraphFitsSegment`
    /// says the formats match. Otherwise `remakeSegment` makes the segment
    /// again for the retry graph. No tap has run, so the segment is still
    /// empty, and a moved format is the usual reason the check failed:
    /// AirPods switch to their 24 kHz call profile after the 48 kHz segment
    /// was made, so the fresh graph comes back at 24 kHz. A failed remake is
    /// a `.createSegment` failure. The retry is skipped when `shouldRetry`
    /// rejects the error (a stopped start); the first failure is thrown.
    /// Device recovery has its own retry and keeps using `run`.
    static func runRetryingOnceOnFreshGraph<Graph, Segment>(
        _ graph: Graph,
        settle: (Graph) throws -> Graph,
        createSegment: (Graph) throws -> Segment,
        checkFormat: (Graph) throws -> Void,
        installTap: (Graph, Segment) throws -> Void,
        withinGraphLock: (Graph, () throws -> Void) throws -> Void,
        shouldRetry: (Error) -> Bool,
        rebuild: (_ failedGraph: Graph) throws -> Graph,
        retryGraphFitsSegment: (_ segmentGraph: Graph, _ retryGraph: Graph) -> Bool,
        remakeSegment: (_ retryGraph: Graph) throws -> Segment
    ) throws -> (graph: Graph, segment: Segment) {
        var settledGraph: Graph?
        var madeSegment: Segment?
        do {
            return try run(
                graph,
                settle: { graph in
                    let settled = try settle(graph)
                    settledGraph = settled
                    return settled
                },
                createSegment: { graph in
                    let segment = try createSegment(graph)
                    madeSegment = segment
                    return segment
                },
                checkFormat: checkFormat,
                installTap: installTap,
                withinGraphLock: withinGraphLock
            )
        } catch let failure as Failure {
            guard failure.step == .checkFormat || failure.step == .installTap,
                  shouldRetry(failure.underlying),
                  let failedGraph = settledGraph,
                  let segment = madeSegment else {
                throw failure
            }
            let retryGraph: Graph
            do {
                retryGraph = try settle(try rebuild(failedGraph))
            } catch {
                throw failure
            }
            var retrySegment = segment
            if !retryGraphFitsSegment(failedGraph, retryGraph) {
                retrySegment = try tagging(.createSegment) { try remakeSegment(retryGraph) }
            }
            try withoutActuallyEscaping(checkFormat) { checkFormat in
                try withoutActuallyEscaping(installTap) { installTap in
                    try tagging(.installTap) {
                        try withinGraphLock(retryGraph) {
                            try tagging(.checkFormat) { try checkFormat(retryGraph) }
                            try tagging(.installTap) { try installTap(retryGraph, retrySegment) }
                        }
                    }
                }
            }
            return (retryGraph, retrySegment)
        }
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
