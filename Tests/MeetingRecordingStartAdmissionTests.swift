import Foundation

/// Pure start-admission promises only. No controller, Audio, permission API,
/// preferences, filesystem or user state is constructed by this fixture.
@MainActor
func testMeetingRecordingStartAdmission() async {
    await runSuite("Already-blocked meeting admission never asks for permission") {
        var permissionCalls = 0
        var allowanceCalls = 0
        let decision: Bool? = await MeetingRecordingStartAdmission.resolve(isAllowed: {
            allowanceCalls += 1
            return false
        }, permission: {
            permissionCalls += 1
            return true
        })
        assertNil(decision)
        assertEqual(permissionCalls, 0)
        assertEqual(allowanceCalls, 1)
    }

    await runSuite("Allowed admission preserves both true and false permission decisions exactly") {
        for permitted in [true, false] {
            var permissionCalls = 0
            var allowanceCalls = 0
            let decision: Bool? = await MeetingRecordingStartAdmission.resolve(isAllowed: {
                allowanceCalls += 1
                return true
            }, permission: {
                permissionCalls += 1
                return permitted
            })
            assertEqual(decision, Optional(permitted), "false is a real permission decision, not blocked admission")
            assertEqual(permissionCalls, 1)
            assertEqual(allowanceCalls, 2)
        }
    }

    await runSuite("Quit accepted during held permission rejects the result without downstream start") {
        let gate = MeetingAdmissionPermissionGate()
        defer { gate.release(false) }
        var quitting = false
        var downstream: [Bool] = []
        let task = Task { @MainActor in
            let result = await MeetingRecordingStartAdmission.resolve(
                isAllowed: { !quitting }, permission: { await gate.permission() }
            )
            if let result { downstream.append(result) }
            gate.noteFinished()
            return result
        }
        assertTrue(await gate.waitUntilEnteredOrFinished(), "permission must be pending before Quit changes")
        quitting = true
        gate.release(true)
        let result = await task.value
        assertNil(result)
        assertEqual(gate.calls, 1)
        assertEqual(downstream, [])
    }

    await runSuite("Refusing Quit before permission returns preserves the original admitted decision") {
        let gate = MeetingAdmissionPermissionGate()
        defer { gate.release(false) }
        var quitting = false
        var allowanceChecks: [Bool] = []
        let task = Task { @MainActor in
            let result = await MeetingRecordingStartAdmission.resolve(isAllowed: {
                allowanceChecks.append(!quitting)
                return !quitting
            }, permission: { await gate.permission() })
            gate.noteFinished()
            return result
        }
        assertTrue(await gate.waitUntilEnteredOrFinished())
        quitting = true
        // These are explicit input changes while the permission operation is
        // suspended: a refused Quit restores allowance before it completes.
        quitting = false
        gate.release(false)
        let result = await task.value
        assertEqual(result, Optional(false))
        assertEqual(gate.calls, 1)
        assertEqual(allowanceChecks, [true, true])
    }

    await runSuite("Unblocking later cannot replay a rejected result but a fresh allowed request can proceed") {
        let gate = MeetingAdmissionPermissionGate()
        defer { gate.release(false) }
        var quitting = false
        var downstream: [Bool] = []
        let task = Task { @MainActor in
            let result = await MeetingRecordingStartAdmission.resolve(
                isAllowed: { !quitting }, permission: { await gate.permission() }
            )
            if let result { downstream.append(result) }
            gate.noteFinished()
            return result
        }
        assertTrue(await gate.waitUntilEnteredOrFinished())
        quitting = true
        gate.release(false)
        let rejected = await task.value
        assertNil(rejected)
        quitting = false
        assertEqual(downstream, [], "a completed rejected request has no deferred start")
        var freshPermissionCalls = 0
        let fresh = await MeetingRecordingStartAdmission.resolve(isAllowed: { !quitting }, permission: {
            freshPermissionCalls += 1
            return true
        })
        if let fresh { downstream.append(fresh) }
        assertEqual(fresh, Optional(true))
        assertEqual(freshPermissionCalls, 1)
        assertEqual(gate.calls, 1)
        assertEqual(downstream, [true])
    }

    await runSuite("A held allowed permission result is requested and delivered once") {
        let gate = MeetingAdmissionPermissionGate()
        defer { gate.release(false) }
        var delivered: [Bool] = []
        let task = Task { @MainActor in
            let result = await MeetingRecordingStartAdmission.resolve(
                isAllowed: { true }, permission: { await gate.permission() }
            )
            if let result { delivered.append(result) }
            gate.noteFinished()
            return result
        }
        assertTrue(await gate.waitUntilEnteredOrFinished())
        assertEqual(gate.calls, 1)
        assertEqual(delivered, [])
        gate.release(true)
        let result = await task.value
        gate.release(false) // Fixture release is idempotent; cannot redeliver.
        assertEqual(result, Optional(true))
        assertEqual(gate.calls, 1)
        assertEqual(delivered, [true])
    }
}

@MainActor
private final class MeetingAdmissionPermissionGate {
    private(set) var calls = 0
    private var released: Bool?
    private var finished = false
    private var permissions: [CheckedContinuation<Bool, Never>] = []
    private var enteredOrFinished: [CheckedContinuation<Bool, Never>] = []

    func permission() async -> Bool {
        calls += 1
        let observers = enteredOrFinished
        enteredOrFinished.removeAll()
        for observer in observers { observer.resume(returning: true) }
        if let released { return released }
        return await withCheckedContinuation { permissions.append($0) }
    }

    func waitUntilEnteredOrFinished() async -> Bool {
        if calls > 0 { return true }
        if finished { return false }
        return await withCheckedContinuation { enteredOrFinished.append($0) }
    }

    func release(_ value: Bool) {
        guard released == nil else { return }
        released = value
        let pending = permissions
        permissions.removeAll()
        for continuation in pending { continuation.resume(returning: value) }
    }

    func noteFinished() {
        finished = true
        let observers = enteredOrFinished
        enteredOrFinished.removeAll()
        for observer in observers { observer.resume(returning: false) }
    }
}
