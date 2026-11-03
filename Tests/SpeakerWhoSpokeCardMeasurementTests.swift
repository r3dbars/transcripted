import CoreGraphics

// Promises for how the Speakers page's "Who spoke?" card sizes itself inside
// the page's scroll view. User report on 1.1.74: scrolling a card with many
// voices froze the app. SwiftUI asks the card's size on every layout pass,
// scrolling included, so answering must not lay the whole card out, and the
// card must not keep handing SwiftUI the same height.
func testSpeakerWhoSpokeCardMeasurement() {
    typealias Measurement = SpeakerWhoSpokeCardMeasurement

    runSuite("Asking the card's size reads the last measured height instead of laying the card out") {
        var card = Measurement()
        _ = card.layoutChanged()
        _ = card.measured(480)
        assertEqual(card.intrinsicHeight, 480, "a scroll asks the size; the answer is the height already measured")
        _ = card.layoutChanged()
        assertEqual(card.intrinsicHeight, 480, "while the next measurement waits, the size stays the last one")
        _ = card.measured(520)
        assertEqual(card.intrinsicHeight, 520)
    }

    runSuite("Row changes while a measurement is waiting schedule no second one") {
        var card = Measurement()
        assertTrue(card.layoutChanged(), "the first change schedules a measurement")
        assertFalse(card.layoutChanged(), "a second change rides the one already scheduled")
        assertFalse(card.layoutChanged(), "so does a third")
        _ = card.measured(480)
        assertFalse(card.isMeasurePending)
        assertTrue(card.layoutChanged(), "after it runs, the next change schedules a new one")
    }

    runSuite("An unchanged height is not handed to SwiftUI again") {
        var card = Measurement()
        _ = card.layoutChanged()
        assertEqual(card.measured(480), 480, "the first height goes to SwiftUI")
        _ = card.layoutChanged()
        assertNil(card.measured(480), "the same height again changes nothing on the page")
        _ = card.layoutChanged()
        assertEqual(card.measured(520), 520, "a taller card goes to SwiftUI")
    }
}
