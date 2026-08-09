import AppKit
import Foundation

func testStatusItemPresentation() {
    runSuite("status item uses quiet, distinct capture symbols") {
        let source = readSourceFixture("Sources/TranscriptedApp.swift")
        let presentation = statusItemPresentationSlice(source)

        assertTrue(
            presentation.contains("symbolName = \"record.circle\"")
                && presentation.contains("label = \"Transcripted — recording meeting\""),
            "meeting recording should use a neutral outline while preserving its accessible state"
        )
        assertTrue(
            presentation.contains("symbolName = \"waveform\"")
                && presentation.contains("label = \"Transcripted — dictating\""),
            "dictation should use a neutral waveform while preserving its accessible state"
        )
        assertTrue(
            presentation.contains("image.isTemplate = true"),
            "capture symbols should follow the menu bar appearance instead of baking in an attention color"
        )
        assertFalse(
            presentation.contains("record.circle.fill")
                || presentation.contains("mic.fill")
                || presentation.contains("systemRed")
                || presentation.contains("isTemplate = false"),
            "the always-visible capture symbols should not use the conspicuous red treatment"
        )
    }

    runSuite("status item symbols exist in the running macOS symbol catalog") {
        assertTrue(
            NSImage(systemSymbolName: "record.circle", accessibilityDescription: nil) != nil,
            "the meeting outline symbol must resolve at runtime"
        )
        assertTrue(
            NSImage(systemSymbolName: "waveform", accessibilityDescription: nil) != nil,
            "the dictation waveform symbol must resolve at runtime"
        )
    }
}

private func statusItemPresentationSlice(_ source: String) -> String {
    guard let start = source.range(of: "private func refreshStatusItemPresentation()") else {
        return ""
    }
    let tail = source[start.lowerBound...]
    guard let end = tail.range(of: "private func installSettingsMenuHandler()") else {
        return String(tail)
    }
    return String(tail[..<end.lowerBound])
}
