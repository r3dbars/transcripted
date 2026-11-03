import Foundation

@MainActor
func testWhisperOperationGate() async {
    await runSuite("Whisper native operations serialize decode, detection, disposal and cancellation") {
        // Promise: dictation, meeting decode, language detection and model disposal
        // execute in request order, even while the native operation suspends.
        let gate = WhisperOperationGate()
        let native = SuspendedWhisperOperations()
        let dictation = Task { @MainActor in
            try await gate.run { await native.perform("dictation") }
        }
        await native.waitForStart("dictation")
        let meeting = Task { @MainActor in
            try await gate.run { await native.perform("meeting") }
        }
        while gate.waiterCount < 1 { await Task.yield() }
        let language = Task { @MainActor in
            try await gate.run { await native.perform("language") }
        }
        while gate.waiterCount < 2 { await Task.yield() }
        let unload = Task { @MainActor in
            try await gate.run { await native.perform("unload") }
        }
        while gate.waiterCount < 3 { await Task.yield() }
        assertEqual(native.events, ["start:dictation"], "waiting work never touches the active model")
        native.finish("dictation")
        _ = try? await dictation.value
        await native.waitForStart("meeting")
        assertEqual(native.events, ["start:dictation", "end:dictation", "start:meeting"], "a meeting waits for dictation to finish")
        native.finish("meeting")
        _ = try? await meeting.value
        await native.waitForStart("language")
        native.finish("language")
        _ = try? await language.value
        await native.waitForStart("unload")
        native.finish("unload")
        _ = try? await unload.value
        assertEqual(native.events, ["start:dictation", "end:dictation", "start:meeting", "end:meeting", "start:language", "end:language", "start:unload", "end:unload"], "disposal runs only after every admitted operation returns")

        // Promise: canceling queued work completes before the active native call,
        // removes only that caller, and leaves the next operation able to proceed.
        let held = Task { @MainActor in
            try await gate.run { await native.perform("held") }
        }
        await native.waitForStart("held")
        let canceled = Task { @MainActor () -> Bool in
            do {
                try await gate.run { native.events.append("canceled-ran") }
                return false
            } catch { return error is CancellationError }
        }
        while gate.waiterCount < 1 { await Task.yield() }
        let following = Task { @MainActor in
            try await gate.run { native.events.append("following-ran") }
        }
        while gate.waiterCount < 2 { await Task.yield() }
        canceled.cancel()
        let canceledPromptly = await canceled.value
        assertTrue(canceledPromptly, "queued cancellation returns while the holder is still suspended")
        assertEqual(gate.waiterCount, 1, "only the canceled operation leaves the queue")
        assertTrue(!native.events.contains("canceled-ran"), "canceled work never enters the native operation")
        held.cancel()
        assertTrue(!native.events.contains("following-ran"), "canceling active work does not release a still-running native call")
        native.finish("held")
        _ = try? await held.value
        _ = try? await following.value
        assertEqual(native.events.suffix(2).map { $0 }, ["end:held", "following-ran"], "the next caller enters after canceled native work actually returns")

        // Promise: an operation that throws or was canceled before admission never
        // strands a permit. Later model load and inference can still execute.
        do {
            try await gate.run { throw WhisperGateTestFailure.expected }
            assertTrue(false, "operation failure must propagate")
        } catch {
            assertTrue(error is WhisperGateTestFailure, "the caller receives the operation's original failure")
        }
        let alreadyCanceled = Task { @MainActor () -> Bool in
            do {
                try await gate.run { native.events.append("pre-canceled-ran") }
                return false
            } catch { return error is CancellationError }
        }
        alreadyCanceled.cancel()
        let rejected = await alreadyCanceled.value
        assertTrue(rejected, "a pre-canceled caller is rejected")
        assertTrue(!native.events.contains("pre-canceled-ran"), "pre-canceled work never runs")
        let finalValue = try? await gate.run { 42 }
        assertEqual(finalValue, 42, "failure and cancellation leave the gate usable")
    }
}

private enum WhisperGateTestFailure: Error { case expected }

@MainActor
private final class SuspendedWhisperOperations {
    var events: [String] = []
    private var completions: [String: CheckedContinuation<Void, Never>] = [:]

    func perform(_ name: String) async {
        events.append("start:\(name)")
        await withCheckedContinuation { completions[name] = $0 }
        events.append("end:\(name)")
    }

    func waitForStart(_ name: String) async {
        while completions[name] == nil { await Task.yield() }
    }

    func finish(_ name: String) {
        completions.removeValue(forKey: name)?.resume()
    }
}
