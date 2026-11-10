import AVFoundation
import CoreAudio
import Dispatch
import Foundation
import XCTest
@testable import TranscriptedCore

/// Component tests use only injected hardware/listener hooks; no HAL registration or native capture.
final class CoreAudioDefaultOutputListenerTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        guard ProcessInfo.processInfo.environment["TRANSCRIPTED_DISABLE_FILE_LOGGER"] == "1" else {
            XCTFail("Listener fixtures require the file logger to be disabled")
            throw ListenerFixtureError.fileLoggerEnabled
        }
    }

    func testCallbackReturnsWhileCaptureQueueIsHeldThenArmsCurrentOutputWatch() throws {
        let hooks = OutputListenerHooks()
        let capture = makeCapture(hooks)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal(); capture.stopSync() }
        try capture.start { _ in }
        clearWatch(capture)
        let registration = try XCTUnwrap(hooks.added.first)
        XCTAssertTrue(registration.queue === capture.listenerQueue)
        XCTAssertFalse(registration.queue === capture.queue)
        let captureHeld = expectation(description: "owned capture queue held")
        capture.queue.async { captureHeld.fulfill(); release.wait() }
        wait(for: [captureHeld], timeout: 10)
        let listenerReturned = expectation(description: "listener returns before capture queue is released")
        registration.queue.async {
            registration.invoke()
            listenerReturned.fulfill()
        }
        // This timeout is a deadlock watchdog, not a latency assertion. The gate
        // remains closed until callback completion has been observed.
        wait(for: [listenerReturned], timeout: 10)
        release.signal()
        registration.queue.sync {}
        XCTAssertEqual(watchReason(capture), .outputChange)
    }

    func testStopRemovesListenerOnRegistrationQueueAndOldCallbackCannotArmWatch() throws {
        let hooks = OutputListenerHooks()
        let capture = makeCapture(hooks)
        defer { capture.stopSync() }
        try capture.start { _ in }
        let registration = try XCTUnwrap(hooks.added.first)
        capture.stopSync()
        let removal = try XCTUnwrap(hooks.removed.first)
        XCTAssertEqual(hooks.added.count, 1)
        XCTAssertEqual(hooks.removed.count, 1)
        XCTAssertTrue(removal.queue === registration.queue)
        clearWatch(capture)
        registration.queue.sync { registration.invoke() }
        XCTAssertNil(watchReason(capture), "a removed generation cannot arm a stopped capture")
    }

    func testRestartRejectsOldRegistrationButCurrentRegistrationArmsWatch() throws {
        let hooks = OutputListenerHooks()
        let capture = makeCapture(hooks)
        defer { capture.stopSync() }
        try capture.start { _ in }
        let old = try XCTUnwrap(hooks.added.first)
        capture.stopSync()
        try capture.start { _ in }
        XCTAssertEqual(hooks.added.count, 2)
        let current = try XCTUnwrap(hooks.added.last)
        clearWatch(capture)
        old.queue.sync { old.invoke() }
        XCTAssertNil(watchReason(capture), "an old callback cannot borrow the restarted recording's active state")
        current.queue.sync { current.invoke() }
        XCTAssertEqual(watchReason(capture), .outputChange)
    }

    func testFailedRegistrationCannotArmOutputWatch() throws {
        let hooks = OutputListenerHooks(addStatus: OSStatus(-1))
        let capture = makeCapture(hooks)
        defer { capture.stopSync() }
        try capture.start { _ in }
        XCTAssertEqual(hooks.added.count, 1)
        let rejected = try XCTUnwrap(hooks.added.first)
        clearWatch(capture)
        rejected.queue.sync { rejected.invoke() }
        XCTAssertNil(watchReason(capture), "an unsuccessful registration has no authority to arm a watch")
    }

    func testHardwareHooksWithoutListenerHooksDoNotRegisterDefaultOutputListener() throws {
        let capture = makeCapture(nil)
        defer { capture.stopSync() }
        try capture.start { _ in }
        XCTAssertNil(capture.defaultOutputListener, "existing fake hardware fixtures must not reach the HAL listener API")
    }

    private func makeCapture(_ hooks: OutputListenerHooks?) -> CoreAudioSystemAudioCapture {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                   channels: 2, interleaved: false)!
        return CoreAudioSystemAudioCapture(hardwareHooks: .init(
            prepare: { format }, start: {}, stop: {}, currentFormat: { format },
            otherAudioIsPlaying: { false }
        ), clock: { 100 }, telemetryEnabled: false, defaultOutputListenerHooks: hooks.map { fixture in
            .init(add: { fixture.add(queue: $0, block: $1) },
                  remove: { fixture.remove(queue: $0, block: $1) })
        })
    }

    private func clearWatch(_ capture: CoreAudioSystemAudioCapture) {
        capture.queue.sync { capture.silenceWatch = nil }
    }

    private func watchReason(_ capture: CoreAudioSystemAudioCapture) -> SystemAudioSilenceWatch.Reason? {
        // This is also the barrier for the listener's asynchronous handoff.
        capture.queue.sync { capture.silenceWatch?.reason }
    }
}

private enum ListenerFixtureError: Error { case fileLoggerEnabled }

private struct OutputListenerRegistration: @unchecked Sendable {
    let queue: DispatchQueue
    let block: AudioObjectPropertyListenerBlock
    func invoke() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        withUnsafePointer(to: &address) { block(1, $0) }
    }
}

private final class OutputListenerHooks: @unchecked Sendable {
    private let lock = NSLock()
    private var registrations: [OutputListenerRegistration] = []
    private var removals: [OutputListenerRegistration] = []
    let addStatus: OSStatus
    init(addStatus: OSStatus = noErr) { self.addStatus = addStatus }
    var added: [OutputListenerRegistration] { lock.lock(); defer { lock.unlock() }; return registrations }
    var removed: [OutputListenerRegistration] { lock.lock(); defer { lock.unlock() }; return removals }
    func add(queue: DispatchQueue, block: @escaping AudioObjectPropertyListenerBlock) -> OSStatus {
        lock.lock(); registrations.append(.init(queue: queue, block: block)); lock.unlock()
        return addStatus
    }
    func remove(queue: DispatchQueue, block: @escaping AudioObjectPropertyListenerBlock) -> OSStatus {
        lock.lock(); removals.append(.init(queue: queue, block: block)); lock.unlock()
        return noErr
    }
}
