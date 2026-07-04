import Foundation

func testDictationStopFinalizationPolicy() async {
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

    await runSuite("DictationStopFinalizer.finalize - default starts save before Auto Enter and finishes after") {
        var events: [String] = []
        let result: DictationStopFinalizationResult<String, String?> = await DictationStopFinalizer.finalize(
            order: .saveBeforeAutoEnter,
            startSaving: {
                events.append("start_save")
                return Task { nil }
            },
            finishSaving: { task in
                events.append("finish_save_started")
                let result = await task.value
                events.append("finish_save_finished")
                return result
            },
            saveSynchronously: {
                events.append("save_synchronously")
                return nil
            },
            performAutoEnter: {
                events.append("auto_enter")
                return "sent"
            }
        )

        assertEqual(
            events,
            [
                "start_save",
                "auto_enter",
                "finish_save_started",
                "finish_save_finished",
            ],
            "save-before finalization should start saving, send Auto Enter, then await the save result"
        )
        assertEqual(result.autoEnterOutcome, "sent", "finalizer should preserve the Auto Enter result")
        assertNil(result.saveResult, "successful save should report no failure")
    }

    await runSuite("DictationStopFinalizer.finalize - legacy order keeps save after Auto Enter") {
        var events: [String] = []
        let result: DictationStopFinalizationResult<String, String?> = await DictationStopFinalizer.finalize(
            order: .saveAfterAutoEnter,
            startSaving: {
                events.append("start_save")
                return Task { nil }
            },
            finishSaving: { task in
                events.append("finish_save")
                return await task.value
            },
            saveSynchronously: {
                events.append("save_synchronously")
                return "disk full"
            },
            performAutoEnter: {
                events.append("auto_enter")
                return "sent"
            }
        )

        assertEqual(
            events,
            [
                "auto_enter",
                "save_synchronously",
            ],
            "save-after finalization should preserve the legacy Auto Enter first order"
        )
        assertEqual(result.autoEnterOutcome, "sent", "finalizer should preserve the Auto Enter result")
        assertEqual(result.saveResult, "disk full", "finalizer should preserve synchronous save failures")
    }
}
