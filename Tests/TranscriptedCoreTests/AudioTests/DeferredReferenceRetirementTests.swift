import Foundation
import XCTest
@testable import TranscriptedCore

/// Labels below identify manually drained fake lanes, not physical OS threads.
/// No Audio object, native backend, real queue, timer or external state exists.
final class DeferredReferenceRetirementTests: XCTestCase {
    func testValueSurvivesConstructionAndMainHandoffUntilWorkerClear() {
        let fixture = ReferenceRetirementFixture()
        XCTAssertEqual(fixture.releases.lanes, [])
        XCTAssertEqual(fixture.main.count, 0)
        fixture.box?.retire()
        XCTAssertEqual(fixture.main.count, 1)
        XCTAssertEqual(fixture.worker.count, 0)
        XCTAssertEqual(fixture.releases.lanes, [])
        fixture.main.drainOne()
        XCTAssertEqual(fixture.main.count, 0)
        XCTAssertEqual(fixture.worker.count, 1)
        XCTAssertEqual(fixture.releases.lanes, [])
        fixture.worker.drainOne()
        XCTAssertEqual(fixture.releases.lanes, ["worker"])
        XCTAssertEqual(fixture.worker.count, 0)
    }

    func testRepeatedRetireSchedulesAndReleasesExactlyOnceAcrossBothHandoffs() {
        let fixture = ReferenceRetirementFixture()
        fixture.box?.retire()
        fixture.box?.retire()
        XCTAssertEqual(fixture.main.count, 1)
        fixture.main.drainOne()
        fixture.box?.retire()
        XCTAssertEqual(fixture.main.count, 0)
        XCTAssertEqual(fixture.worker.count, 1)
        fixture.worker.drainOne()
        fixture.box?.retire()
        XCTAssertEqual(fixture.main.count, 0)
        XCTAssertEqual(fixture.worker.count, 0)
        XCTAssertEqual(fixture.releases.lanes, ["worker"])
        fixture.box = nil
        XCTAssertEqual(fixture.releases.lanes, ["worker"])
    }

    func testScheduledJobsRetainValueAfterCallerDropsBox() {
        let fixture = ReferenceRetirementFixture()
        fixture.box?.retire()
        fixture.box = nil
        XCTAssertEqual(fixture.releases.lanes, [])
        fixture.main.drainOne()
        XCTAssertEqual(fixture.worker.count, 1)
        XCTAssertEqual(fixture.releases.lanes, [])
        fixture.worker.drainOne()
        XCTAssertEqual(fixture.releases.lanes, ["worker"])
    }

    func testWorkerExplicitlyClearsValueWhileMainJobStillRetainsBox() {
        let fixture = ReferenceRetirementFixture()
        fixture.box?.retire()
        var retainedMainJob = fixture.main.take()
        XCTAssertNotNil(retainedMainJob)
        fixture.box = nil
        fixture.releases.onLane("main") { retainedMainJob?() }
        XCTAssertEqual(fixture.worker.count, 1)
        fixture.worker.drainOne()
        // The still-live main closure retains the box. Releasing only the box
        // on worker would leave the value alive here and fail this assertion.
        withExtendedLifetime(retainedMainJob) {
            XCTAssertEqual(fixture.releases.lanes, ["worker"])
        }
        fixture.releases.onLane("main") { retainedMainJob = nil }
        XCTAssertEqual(fixture.releases.lanes, ["worker"])
    }

    func testSeparateStopLikeOwnerMayOutliveOurWorkerClear() {
        let releases = ReferenceRetirementReleases()
        let main = ReferenceRetirementLane("main", releases: releases)
        let worker = ReferenceRetirementLane("worker", releases: releases)
        var externalOwner: ReferenceRetirementMarker? = ReferenceRetirementMarker(releases: releases)
        let box = DeferredReferenceRetirement(
            retaining: externalOwner!, enqueueMain: main.enqueue, enqueueWorker: worker.enqueue
        )
        box.retire()
        main.drainOne()
        worker.drainOne()
        withExtendedLifetime(externalOwner) { XCTAssertEqual(releases.lanes, []) }
        releases.onLane("external-owner") { externalOwner = nil }
        XCTAssertEqual(releases.lanes, ["external-owner"])
        box.retire()
        XCTAssertEqual(main.count, 0)
        XCTAssertEqual(worker.count, 0)
        XCTAssertEqual(releases.lanes, ["external-owner"])
    }

    func testInlineSchedulersAndReentrantRetireNeverInvokeCallbacksUnderLocks() {
        let releases = ReferenceRetirementReleases()
        let weakBox = ReferenceRetirementWeakBox()
        let box = DeferredReferenceRetirement(
            retaining: ReferenceRetirementMarker(releases: releases, afterRelease: {
                // Explicit clear must release the value outside the helper's
                // lock as well as invoke both injected schedulers outside it.
                weakBox.value?.retire()
            }),
            enqueueMain: { job in
                releases.onLane("main") {
                    weakBox.value?.retire()
                    job()
                }
            },
            enqueueWorker: { job in
                releases.onLane("worker") {
                    weakBox.value?.retire()
                    job()
                }
            }
        )
        weakBox.value = box
        box.retire()
        XCTAssertEqual(releases.lanes, ["worker"])
        box.retire()
        XCTAssertEqual(releases.lanes, ["worker"])
    }
}

private final class ReferenceRetirementFixture {
    let releases = ReferenceRetirementReleases()
    let main: ReferenceRetirementLane
    let worker: ReferenceRetirementLane
    var box: DeferredReferenceRetirement?

    init() {
        main = ReferenceRetirementLane("main", releases: releases)
        worker = ReferenceRetirementLane("worker", releases: releases)
        box = DeferredReferenceRetirement(
            retaining: ReferenceRetirementMarker(releases: releases),
            enqueueMain: main.enqueue, enqueueWorker: worker.enqueue
        )
    }
}

private final class ReferenceRetirementWeakBox: @unchecked Sendable {
    // Assigned/read only during the single synchronous fake-lane test.
    weak var value: DeferredReferenceRetirement?
}

private final class ReferenceRetirementMarker {
    let releases: ReferenceRetirementReleases
    let afterRelease: @Sendable () -> Void

    init(releases: ReferenceRetirementReleases, afterRelease: @escaping @Sendable () -> Void = {}) {
        self.releases = releases
        self.afterRelease = afterRelease
    }

    deinit {
        releases.record()
        afterRelease()
    }
}

private final class ReferenceRetirementReleases: @unchecked Sendable {
    private let lock = NSLock()
    private var lane = "caller"
    private var recorded: [String] = []

    var lanes: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    func record() {
        lock.lock()
        recorded.append(lane)
        lock.unlock()
    }

    func onLane(_ label: String, _ body: () -> Void) {
        lock.lock()
        let previous = lane
        lane = label
        lock.unlock()
        defer {
            lock.lock()
            lane = previous
            lock.unlock()
        }
        body()
    }
}

private final class ReferenceRetirementLane: @unchecked Sendable {
    private let lock = NSLock()
    private let label: String
    private let releases: ReferenceRetirementReleases
    private var jobs: [@Sendable () -> Void] = []

    init(_ label: String, releases: ReferenceRetirementReleases) {
        self.label = label
        self.releases = releases
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return jobs.count
    }

    func enqueue(_ job: @escaping @Sendable () -> Void) {
        lock.lock()
        jobs.append(job)
        lock.unlock()
    }

    func take() -> (@Sendable () -> Void)? {
        lock.lock()
        defer { lock.unlock() }
        return jobs.isEmpty ? nil : jobs.removeFirst()
    }

    func drainOne() {
        guard let job = take() else {
            XCTFail("expected one scheduled fake-lane job")
            return
        }
        releases.onLane(label, job)
    }
}
