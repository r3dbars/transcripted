import Foundation

@MainActor
func testWritingPauseWakeup() async {
    await runSuite("A Writing pause owns one expiry wakeup and explicit resume cancels it") {
        let wakeup = WritingPauseWakeup()
        let deadline = Date().addingTimeInterval(3_600)
        var resumes = 0
        wakeup.schedule(until: deadline) { resumes += 1 }
        let timer = wakeup.timer
        assertTrue(timer?.isValid == true)
        wakeup.schedule(until: deadline) { resumes += 1 }
        assertTrue(wakeup.timer === timer, "updating settings cannot add another timer")
        wakeup.schedule(until: nil) { resumes += 1 }
        assertTrue(wakeup.timer == nil)
        assertFalse(timer?.isValid ?? true)
        timer?.fire()
        assertEqual(resumes, 0, "an explicit resume/stop leaves no stale expiry action")

        wakeup.schedule(until: deadline) { resumes += 1 }
        let next = wakeup.timer
        next?.fire()
        assertEqual(resumes, 1, "expiry reapplies the current background policy once")
        assertTrue(wakeup.timer == nil)
        next?.fire()
        assertEqual(resumes, 1)
    }

    await runSuite("Extending a pause cancels its former expiry action") {
        let wakeup = WritingPauseWakeup()
        let deadline = Date().addingTimeInterval(3_600)
        var resumes = 0
        wakeup.schedule(until: deadline) { resumes += 1 }
        let old = wakeup.timer
        wakeup.schedule(until: deadline.addingTimeInterval(3_600)) { resumes += 1 }
        assertFalse(old?.isValid ?? true)
        old?.fire()
        assertEqual(resumes, 0)
        wakeup.timer?.fire()
        assertEqual(resumes, 1)
    }
}
