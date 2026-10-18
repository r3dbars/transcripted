// lint-fixture-path: Sources/UI/FixtureOperationQueues.swift
// Work handed to a background OperationQueue, an observer on a background
// queue, or a @concurrent func runs off the main actor.
import Foundation
@MainActor
final class CleanupController {
    let backgroundQueue = OperationQueue()

    func start(url: URL) {
        NotificationCenter.default.addObserver(forName: .NSCalendarDayChanged, object: nil, queue: backgroundQueue) { _ in
            try? FileManager.default.removeItem(at: url)
        }
        let op = BlockOperation {
            try? FileManager.default.removeItem(at: url)
        }
        backgroundQueue.addOperation(op)
    }

    @concurrent
    func save(_ data: Data, to url: URL) async throws {
        try data.write(to: url)
    }
}
