import Foundation

/// The shutdown flush for local observability files: buffered events first,
/// then reliability packets. Both are awaited before it returns, so the Quit
/// path can reply to AppKit knowing nothing is left in memory.
///
/// `EventReporter.flushLocalEventsForShutdown` runs it with the real writers.
enum LocalEventShutdownFlush {
    static func run(
        flushEvents: () async -> Void,
        flushPackets: () async -> Void
    ) async {
        await flushEvents()
        await flushPackets()
    }
}
