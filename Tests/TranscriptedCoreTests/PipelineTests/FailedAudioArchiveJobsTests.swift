import Foundation
import XCTest
@testable import TranscriptedCore

@MainActor
final class FailedAudioArchiveJobsTests: XCTestCase {
    // Select ONLY this unheld case for an inline-work mutation. The held
    // worker cases below must never be selected for a main-thread mutant.
    func testUnheldWorkRunsOffMainAndCompletionIncludesMainActorApply() async {
        let jobs = FailedAudioArchiveJobs()
        let record = ArchiveJobRecord()
        jobs.schedule(work: {
            ArchiveJobThreadResult(value: 17, wasMainThread: Thread.isMainThread)
        }, apply: { output in
            record.threadResult = output
            record.applyWasMainThread = Thread.isMainThread
        })
        let completion = jobs.beginWaitingForScheduledJobs()
        await completion.wait()
        XCTAssertEqual(record.threadResult?.value, 17)
        XCTAssertEqual(record.threadResult?.wasMainThread, false)
        XCTAssertEqual(record.applyWasMainThread, true)
    }

    func testDistinctInvocationsBothApplyEvenWhenTheirResultsAreIdentical() async {
        let jobs = FailedAudioArchiveJobs()
        let record = ArchiveJobRecord()
        let first = ArchiveJobWorkGate("first work entered")
        let second = ArchiveJobWorkGate("second work entered")
        defer { first.release(); second.release() }
        let secondApplied = XCTestExpectation(description: "second invocation applied")
        jobs.schedule(work: { first.wait(); return 7 }, apply: { value in
            record.labels.append("first")
            record.values.append(value)
        })
        jobs.schedule(work: { second.wait(); return 7 }, apply: { value in
            record.labels.append("second")
            record.values.append(value)
            secondApplied.fulfill()
        })
        let completion = jobs.beginWaitingForScheduledJobs()
        await archiveJobEvents([first.entered, second.entered])
        second.release()
        await archiveJobEvents([secondApplied])
        XCTAssertEqual(record.labels, ["second"])
        first.release()
        await completion.wait()
        XCTAssertEqual(record.labels, ["second", "first"])
        XCTAssertEqual(record.values, [7, 7], "equal outputs must not coalesce separate job invocations")
    }

    func testNilOutputStillReachesApplyAndSettlesTheCompletion() async {
        let jobs = FailedAudioArchiveJobs()
        let record = ArchiveJobRecord()
        jobs.schedule(work: { Optional<Int>.none }, apply: { output in
            record.optionalValues.append(output)
            record.labels.append("nil applied")
        })
        await jobs.beginWaitingForScheduledJobs().wait()
        XCTAssertEqual(record.optionalValues, [nil])
        XCTAssertEqual(record.labels, ["nil applied"])
    }

    func testSnapshotExcludesFutureAdmissionEvenWhenWaitStartsAfterBothJobs() async {
        let jobs = FailedAudioArchiveJobs()
        let record = ArchiveJobRecord()
        let captured = ArchiveJobWorkGate("captured work entered")
        let future = ArchiveJobWorkGate("future work entered")
        defer { captured.release(); future.release() }
        jobs.schedule(work: { captured.wait(); return 1 }, apply: { value in
            record.labels.append("captured applied")
            record.values.append(value)
        })
        // The snapshot boundary is synchronous; wait() is deliberately later.
        let snapshot = jobs.beginWaitingForScheduledJobs()
        jobs.schedule(work: { future.wait(); return 2 }, apply: { value in
            record.labels.append("future applied")
            record.values.append(value)
        })
        let drainAll = jobs.beginWaitingForScheduledJobs()
        await archiveJobEvents([captured.entered, future.entered])
        let finished = XCTestExpectation(description: "captured set settled while future work remains held")
        let waiter = Task { @MainActor in
            await snapshot.wait()
            record.labels.append("snapshot finished")
            finished.fulfill()
        }
        captured.release()
        // Positive completion is the witness. Timeout is only a deadlock
        // watchdog; no elapsed time or speed is measured or asserted.
        await archiveJobEvents([finished])
        XCTAssertEqual(record.labels, ["captured applied", "snapshot finished"])
        XCTAssertEqual(record.values, [1])
        // Always release future work before awaiting the waiter, including
        // after watchdog failure if an incorrect snapshot joined future work.
        future.release()
        await waiter.value
        await drainAll.wait()
        XCTAssertEqual(record.values, [1, 2])
    }

    func testEmptySnapshotExcludesAJobAdmittedBeforeItsWaitIsCalled() async {
        let jobs = FailedAudioArchiveJobs()
        let record = ArchiveJobRecord()
        let empty = jobs.beginWaitingForScheduledJobs()
        let future = ArchiveJobWorkGate("future work after empty snapshot entered")
        defer { future.release() }
        jobs.schedule(work: { future.wait(); return 9 }, apply: { value in record.values.append(value) })
        let drain = jobs.beginWaitingForScheduledJobs()
        await archiveJobEvents([future.entered])
        let finished = XCTestExpectation(description: "empty captured set finished before future release")
        let waiter = Task { @MainActor in
            await empty.wait()
            finished.fulfill()
        }
        await archiveJobEvents([finished])
        XCTAssertTrue(record.values.isEmpty)
        future.release()
        await waiter.value
        await drain.wait()
        XCTAssertEqual(record.values, [9])
    }

    func testCancellingAWaiterDoesNotCancelAdmittedWorkOrItsApply() async {
        let jobs = FailedAudioArchiveJobs()
        let record = ArchiveJobRecord()
        let work = ArchiveJobWorkGate("work held before waiter cancellation")
        defer { work.release() }
        jobs.schedule(work: {
            work.wait()
            return ArchiveJobCancellationResult(value: 23, wasCancelled: Task.isCancelled)
        }, apply: { output in
            record.values.append(output.value)
            record.workWasCancelled = output.wasCancelled
        })
        let completion = jobs.beginWaitingForScheduledJobs()
        await archiveJobEvents([work.entered])
        let finished = XCTestExpectation(description: "cancelled waiter still observes apply completion")
        let started = XCTestExpectation(description: "waiter entered its captured completion")
        let waiter = Task { @MainActor in
            started.fulfill()
            await completion.wait()
            XCTAssertEqual(record.values, [23], "wait still means the captured apply has settled")
            finished.fulfill()
        }
        await archiveJobEvents([started])
        waiter.cancel()
        work.release()
        await archiveJobEvents([finished])
        await waiter.value
        await completion.wait()
        XCTAssertEqual(record.values, [23])
        XCTAssertEqual(record.workWasCancelled, false)
    }

    func testReleasingTheTrackerDoesNotCancelAdmittedWorkOrApply() async {
        var jobs: FailedAudioArchiveJobs? = FailedAudioArchiveJobs()
        weak var weakJobs = jobs
        let record = ArchiveJobRecord()
        let work = ArchiveJobWorkGate("work held while tracker releases")
        defer { work.release() }
        jobs!.schedule(work: { work.wait(); return 31 }, apply: { value in record.values.append(value) })
        let completion = jobs!.beginWaitingForScheduledJobs()
        await archiveJobEvents([work.entered])
        jobs = nil
        XCTAssertNil(weakJobs, "a pending job must not create a tracker-to-task-to-tracker ownership cycle")
        work.release()
        await completion.wait()
        XCTAssertEqual(record.values, [31])
    }

    func testWaitingAgainAfterCompletionDoesNotRepeatApply() async {
        let jobs = FailedAudioArchiveJobs()
        let record = ArchiveJobRecord()
        jobs.schedule(work: { 41 }, apply: { value in record.values.append(value) })
        let first = jobs.beginWaitingForScheduledJobs()
        await first.wait()
        let settled = jobs.beginWaitingForScheduledJobs()
        await settled.wait()
        await first.wait()
        XCTAssertEqual(record.values, [41])
    }
}

private struct ArchiveJobThreadResult: Sendable {
    let value: Int
    let wasMainThread: Bool
}

private struct ArchiveJobCancellationResult: Sendable {
    let value: Int
    let wasCancelled: Bool
}

@MainActor
private final class ArchiveJobRecord {
    var labels: [String] = []
    var values: [Int] = []
    var optionalValues: [Int?] = []
    var threadResult: ArchiveJobThreadResult?
    var applyWasMainThread: Bool?
    var workWasCancelled: Bool?
}

/// Only detached fake work blocks here. All test/MainActor waits are async.
private final class ArchiveJobWorkGate: @unchecked Sendable {
    let entered: XCTestExpectation
    private let condition = NSCondition()
    private var released = false

    init(_ description: String) { entered = XCTestExpectation(description: description) }

    func wait() {
        entered.fulfill()
        condition.lock()
        while !released { condition.wait() }
        condition.unlock()
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

/// A generous missing-event watchdog, never a latency assertion. Callers keep
/// going after failure to release every work gate and join owned tasks/sets.
private func archiveJobEvents(_ events: [XCTestExpectation]) async {
    let result = await XCTWaiter.fulfillment(of: events, timeout: 30)
    XCTAssertEqual(result, .completed, "A scripted job event did not complete; releasing held work for cleanup")
}
