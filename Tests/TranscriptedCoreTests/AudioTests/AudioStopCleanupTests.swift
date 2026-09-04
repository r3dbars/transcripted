import XCTest
@testable import TranscriptedCore

final class AudioStopCleanupTests: XCTestCase {
    func testBlockedMicrophoneStopDoesNotHoldSystemCaptureOrWriterOpen() {
        assertIndependentShutdown(blockMicrophone: true)
    }

    func testBlockedSystemStopDoesNotHoldMicrophoneOrWriterOpen() {
        assertIndependentShutdown(blockMicrophone: false)
    }

    private func assertIndependentShutdown(blockMicrophone: Bool) {
        let blockedStopStarted = DispatchSemaphore(value: 0)
        let unblockStop = DispatchSemaphore(value: 0)
        let independentWriterClosed = DispatchSemaphore(value: 0)
        let blockedWriterClosed = DispatchSemaphore(value: 0)
        let completed = DispatchSemaphore(value: 0)
        defer { unblockStop.signal() }

        let blockedStop = {
            blockedStopStarted.signal()
            _ = unblockStop.wait(timeout: .now() + 5)
        }
        let blockedClose = { blockedWriterClosed.signal(); return }
        let independentClose = { independentWriterClosed.signal(); return }
        AudioStopCleanup.schedule(
            group: DispatchGroup(),
            microphoneFileQueue: DispatchQueue(label: "test.mic.writer"),
            systemFileQueue: DispatchQueue(label: "test.system.writer"),
            stopMicrophone: blockMicrophone ? blockedStop : {},
            stopSystem: blockMicrophone ? {} : blockedStop,
            closeMicrophone: blockMicrophone ? blockedClose : independentClose,
            closeSystem: blockMicrophone ? independentClose : blockedClose,
            completion: { completed.signal() }
        )

        XCTAssertEqual(blockedStopStarted.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(independentWriterClosed.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(blockedWriterClosed.wait(timeout: .now()), .timedOut)
        XCTAssertEqual(completed.wait(timeout: .now()), .timedOut)
        unblockStop.signal()
        XCTAssertEqual(blockedWriterClosed.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
    }

    func testFinalizationWaitsForBothAdmittedWriterTailsAndHostBufferDrain() {
        let microphoneQueue = DispatchQueue(label: "test.mic.writer")
        let systemQueue = DispatchQueue(label: "test.system.writer")
        let micTail = DispatchSemaphore(value: 0)
        let systemTail = DispatchSemaphore(value: 0)
        let micClosed = DispatchSemaphore(value: 0)
        let systemClosed = DispatchSemaphore(value: 0)
        let producersStopped = DispatchGroup()
        let completed = DispatchSemaphore(value: 0)
        let cleanup = DispatchGroup()
        cleanup.enter() // An admitted host buffer is still being consumed.
        producersStopped.enter()
        producersStopped.enter()
        defer { micTail.signal(); systemTail.signal() }

        microphoneQueue.async { _ = micTail.wait(timeout: .now() + 5) }
        systemQueue.async { _ = systemTail.wait(timeout: .now() + 5) }
        AudioStopCleanup.schedule(
            group: cleanup,
            microphoneFileQueue: microphoneQueue,
            systemFileQueue: systemQueue,
            stopMicrophone: { producersStopped.leave() },
            stopSystem: { producersStopped.leave() },
            closeMicrophone: { micClosed.signal() },
            closeSystem: { systemClosed.signal() },
            completion: { completed.signal() }
        )

        XCTAssertEqual(producersStopped.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(micClosed.wait(timeout: .now()), .timedOut)
        XCTAssertEqual(systemClosed.wait(timeout: .now()), .timedOut)
        micTail.signal()
        XCTAssertEqual(micClosed.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(completed.wait(timeout: .now()), .timedOut)
        systemTail.signal()
        XCTAssertEqual(systemClosed.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(completed.wait(timeout: .now()), .timedOut)
        cleanup.leave()
        XCTAssertEqual(completed.wait(timeout: .now() + 2), .success)
    }
}
