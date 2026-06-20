import Foundation

func testUnrecognizedSelectorReason() {
    runSuite("parses an instance-method unrecognized-selector reason") {
        let parsed = UnrecognizedSelectorReason.parse(
            "-[NSButton openSettings]: unrecognized selector sent to instance 0x600001234560"
        )
        assertEqual(parsed?.receiver, "NSButton", "receiver class should be captured")
        assertEqual(parsed?.selector, "openSettings", "selector should be captured")
        assertEqual(parsed?.isClassMethod, false, "instance methods use the '-' prefix")
    }

    runSuite("parses a selector that takes arguments (trailing colon)") {
        let parsed = UnrecognizedSelectorReason.parse(
            "-[TranscriptedAppDelegate togglePopover:]: unrecognized selector sent to instance 0x12ab"
        )
        assertEqual(parsed?.receiver, "TranscriptedAppDelegate")
        assertEqual(parsed?.selector, "togglePopover:")
    }

    runSuite("parses a class-method unrecognized-selector reason") {
        let parsed = UnrecognizedSelectorReason.parse(
            "+[SomeClass classThing]: unrecognized selector sent to class 0x1f0"
        )
        assertEqual(parsed?.receiver, "SomeClass")
        assertEqual(parsed?.selector, "classThing")
        assertEqual(parsed?.isClassMethod, true, "class methods use the '+' prefix")
    }

    runSuite("returns nil for unrelated reasons") {
        assertNil(UnrecognizedSelectorReason.parse(nil), "nil reason yields nil")
        assertNil(
            UnrecognizedSelectorReason.parse("some other NSException reason"),
            "reasons without the marker yield nil"
        )
        // Has brackets but is not an unrecognized-selector message.
        assertNil(
            UnrecognizedSelectorReason.parse("array index [5] out of bounds"),
            "bracketed non-selector reasons yield nil"
        )
        // Marker present but no method-dispatch prefix.
        assertNil(
            UnrecognizedSelectorReason.parse("unrecognized selector for [thing] somewhere"),
            "missing -/+ dispatch prefix yields nil"
        )
    }

    runSuite("does not leak the instance pointer or trailing text") {
        let parsed = UnrecognizedSelectorReason.parse(
            "-[NSButton openSettings]: unrecognized selector sent to instance 0xdeadbeef"
        )
        assertFalse(parsed?.selector.contains("0x") ?? true, "selector must not include the pointer")
        assertFalse(parsed?.receiver.contains("0x") ?? true, "receiver must not include the pointer")
        assertFalse(parsed?.selector.contains("unrecognized") ?? true, "selector must not include trailing text")
    }
}
