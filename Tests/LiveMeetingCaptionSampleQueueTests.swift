import Foundation

func testLiveMeetingCaptionSampleQueue() {
    runSuite("LiveMeetingCaptionSampleQueue hands audio back in arrival order") {
        let queue = LiveMeetingCaptionSampleQueue(capacity: 8)
        queue.append([1, 2, 3])
        queue.append([4, 5])
        let first = queue.take(limit: 4)
        assertEqual(first.samples, [1, 2, 3, 4])
        assertFalse(first.overflowed)
        queue.append([6, 7, 8, 9, 10, 11])
        assertEqual(queue.take(limit: 100).samples, [5, 6, 7, 8, 9, 10, 11], "reads wrap around the ring in order")
        assertEqual(queue.count, 0)
    }

    runSuite("LiveMeetingCaptionSampleQueue keeps the newest audio when full and says so") {
        let queue = LiveMeetingCaptionSampleQueue(capacity: 4)
        queue.append([1, 2, 3])
        queue.append([4, 5, 6])
        let taken = queue.take(limit: 10)
        assertEqual(taken.samples, [3, 4, 5, 6], "the oldest audio goes first")
        assertTrue(taken.overflowed, "the track learns audio was lost")
        assertFalse(queue.take(limit: 10).overflowed, "the loss is reported once")

        queue.append([7, 8, 9, 10, 11, 12])
        assertEqual(queue.take(limit: 10).samples, [9, 10, 11, 12], "one oversized append keeps its newest samples")
    }

    runSuite("LiveMeetingCaptionSampleQueue empties on removeAll") {
        let queue = LiveMeetingCaptionSampleQueue(capacity: 4)
        queue.append([1, 2, 3, 4, 5])
        queue.removeAll()
        let taken = queue.take(limit: 10)
        assertEqual(taken.samples, [])
        assertFalse(taken.overflowed)
    }
}
