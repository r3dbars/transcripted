// ParakeetASRInferenceGateTests.swift
// The shared TDT decoder never runs two calls at once, including in the gap
// between one call finishing and the next queued caller resuming.

import Foundation

@MainActor
func testParakeetASRInferenceGate() async {
    await runSuite("A caller arriving during a handoff waits instead of overlapping the resumed waiter") {
        let gate = ParakeetASRInferenceGate()
        var events: [String] = []
        var running = 0
        var maxRunning = 0
        @MainActor func enter(_ name: String) {
            running += 1
            maxRunning = max(maxRunning, running)
            events.append("\(name) start")
        }
        @MainActor func leave(_ name: String) {
            running -= 1
            events.append("\(name) end")
            gate.finish()
        }

        do {
            try await gate.begin()
            enter("A")
        } catch {
            assertTrue(false, "the first caller should start immediately")
            return
        }

        var waiterDeferred = false
        let waiter = Task { @MainActor in
            do {
                try await gate.begin(onDeferred: { waiterDeferred = true })
            } catch {
                return
            }
            enter("B")
            leave("B")
        }
        while gate.waiterCount < 1 { await Task.yield() }
        assertTrue(waiterDeferred, "a caller behind active decoder work is queued")

        running -= 1
        events.append("A end")
        assertTrue(gate.finish(), "finishing with a queued caller hands the slot over")
        assertTrue(gate.hasActiveWork, "a reserved handoff still counts as decoder work")

        // C arrives in the same MainActor turn, before B has resumed.
        var lateCallerDeferred = false
        do {
            try await gate.begin(onDeferred: { lateCallerDeferred = true })
            enter("C")
            leave("C")
        } catch {
            assertTrue(false, "the late caller should eventually be admitted")
        }
        await waiter.value

        assertTrue(lateCallerDeferred, "a reserved handoff makes a new caller queue")
        assertEqual(maxRunning, 1, "decoder calls must never overlap")
        assertEqual(
            events,
            ["A start", "A end", "B start", "B end", "C start", "C end"],
            "the resumed waiter runs before the late caller"
        )
        assertFalse(gate.hasActiveWork, "the gate is idle once every caller finished")
    }

    await runSuite("Finishing with nobody queued releases the decoder") {
        let gate = ParakeetASRInferenceGate()
        do { try await gate.begin() } catch {
            assertTrue(false, "an idle gate admits immediately")
            return
        }
        assertTrue(gate.hasActiveWork, "a running call is active work")
        assertFalse(gate.finish(), "no handoff when nobody waits, so teardown may proceed")
        assertFalse(gate.hasActiveWork, "the gate is idle after the only call finishes")
    }

    await runSuite("A cancelled queued caller leaves no slot behind") {
        let gate = ParakeetASRInferenceGate()
        do { try await gate.begin() } catch {
            assertTrue(false, "an idle gate admits immediately")
            return
        }
        let queued = Task { @MainActor () -> Bool in
            do { try await gate.begin(); return true } catch { return false }
        }
        while gate.waiterCount < 1 { await Task.yield() }
        queued.cancel()
        let admitted = await queued.value
        assertFalse(admitted, "cancellation before handoff ends the wait without admission")
        assertFalse(gate.finish(), "the cancelled caller no longer receives a handoff")
        assertFalse(gate.hasActiveWork, "nothing is left reserved after cancellation")
    }
}
