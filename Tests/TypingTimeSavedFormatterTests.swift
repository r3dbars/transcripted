import Foundation

func testTypingTimeSavedFormatter() {
    runSuite("TypingTimeSavedFormatter handles zero and sub-hour bands") {
        assertEqual(TypingTimeSavedFormatter.format(dictatedWords: 0), "0h", "Zero words should report 0h")
        assertEqual(TypingTimeSavedFormatter.format(dictatedWords: -50), "0h", "Non-positive words should report 0h")
        assertEqual(TypingTimeSavedFormatter.format(dictatedWords: 1), "<1h", "A single word should land in the <1h band")
        assertEqual(TypingTimeSavedFormatter.format(dictatedWords: 100), "<1h", "A small word count should land in the <1h band")
        assertEqual(TypingTimeSavedFormatter.format(dictatedWords: 2399), "<1h", "Just under one hour should stay <1h")
    }

    runSuite("TypingTimeSavedFormatter formats single-digit-hour bands with tenths") {
        assertEqual(TypingTimeSavedFormatter.format(dictatedWords: 2400), "1.0h", "Exactly one hour (40 wpm) should be 1.0h")
        assertEqual(TypingTimeSavedFormatter.format(dictatedWords: 2401), "1.0h", "Just over one hour should still round to 1.0h")
        assertEqual(TypingTimeSavedFormatter.format(dictatedWords: 12000), "5.0h", "Five exact hours should be 5.0h")
        assertEqual(TypingTimeSavedFormatter.format(dictatedWords: 13080), "5.5h", "Tenths rounding should produce 5.5h")
        assertEqual(TypingTimeSavedFormatter.format(dictatedWords: 21600), "9.0h", "Nine exact hours should be 9.0h")
    }

    runSuite("TypingTimeSavedFormatter carries tenths rounding up into the whole-hour band") {
        // 23904 words -> 9.96h -> tenths round to 10.0 -> "10h" via the carry branch
        assertEqual(TypingTimeSavedFormatter.format(dictatedWords: 23904), "10h", "Sub-10h that rounds up should report 10h without a decimal")
    }

    runSuite("TypingTimeSavedFormatter formats ten-or-more hours as whole hours") {
        assertEqual(TypingTimeSavedFormatter.format(dictatedWords: 24000), "10h", "Exactly ten hours should be 10h")
        assertEqual(TypingTimeSavedFormatter.format(dictatedWords: 28800), "12h", "Large word counts should report whole hours")
    }
}
