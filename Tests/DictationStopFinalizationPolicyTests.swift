import Foundation

func testDictationStopFinalizationPolicy() {
    runSuite("DictationStopFinalizationOrder.parse - accepts canonical raw values") {
        assertEqual(
            DictationStopFinalizationOrder.parse("saveBeforeAutoEnter"),
            .saveBeforeAutoEnter,
            "benchmark config should accept the current default raw value"
        )
        assertEqual(
            DictationStopFinalizationOrder.parse("saveAfterAutoEnter"),
            .saveAfterAutoEnter,
            "benchmark config should accept the legacy auto-enter-first raw value"
        )
    }

    runSuite("DictationStopFinalizationOrder.parse - accepts snake-case and hyphenated values") {
        assertEqual(
            DictationStopFinalizationOrder.parse(" save_before_auto_enter\n"),
            .saveBeforeAutoEnter,
            "operator-provided config should tolerate whitespace and snake case"
        )
        assertEqual(
            DictationStopFinalizationOrder.parse("SAVE-AFTER-AUTO-ENTER"),
            .saveAfterAutoEnter,
            "operator-provided config should tolerate hyphenated uppercase values"
        )
    }

    runSuite("DictationStopFinalizationOrder.parse - rejects unknown values") {
        assertNil(
            DictationStopFinalizationOrder.parse(""),
            "blank benchmark config should fail closed instead of choosing an order"
        )
        assertNil(
            DictationStopFinalizationOrder.parse("saveThenPaste"),
            "unknown benchmark config should fail closed instead of changing stop ordering"
        )
    }

    runSuite("DictationStopFinalizationPolicy.order - saves before Auto Enter by default") {
        assertEqual(
            DictationStopFinalizationPolicy.order,
            .saveBeforeAutoEnter,
            "the default should keep the dictation artifact save ahead of the optional Auto Enter delay"
        )
    }
}
