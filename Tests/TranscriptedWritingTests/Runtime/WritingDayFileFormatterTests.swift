import Foundation
import Testing
@testable import TranscriptedWritingRuntime

@Suite("Save my writing day-file format")
struct WritingDayFileFormatterTests {
    private let chicago = TimeZone(identifier: "America/Chicago")!
    private let english = Locale(identifier: "en_US")
    /// 2026-09-25T15:42:11.387Z, the contract example's first keystroke.
    private let captured: Int64 = 1_790_350_931_387

    /// `~/tilde-port/phase3-format.md`, "File", byte for byte: the header
    /// once, then the first section. The counts are the example's own.
    @Test("A new day file matches the phase 3 contract example")
    func contractExample() {
        let file = String(decoding: WritingDayFileFormatter.contents(
            appending: exampleSection(),
            to: nil,
            header: WritingDayFileFormatter.dayHeader(forMilliseconds: captured, timeZone: chicago, locale: english)
        ), as: UTF8.self)
        #expect(file == """
        ---
        title: "Writing for September 25, 2026"
        date: 2026-09-25
        capture_type: writing_day
        format_version: 1
        ---

        # Writing for September 25, 2026

        ## 10:42 AM - Pushing the launch to Thursday so QA

        Entry ID: `writing-20260925-104211-387-4f2a9c1e`
        Captured: 2026-09-25T15:42:11.387Z
        Source app: Slack
        Bundle ID: `com.tinyspeck.slackmacgap`
        Words: 14
        Characters: 71
        Accepted words: 3

        Pushing the launch to Thursday so QA can finish the AirPods pass.
        """)
        #expect(WritingDayFileFormatter.fileName(forMilliseconds: captured, timeZone: chicago) == "Writing_2026-09-25.md")
        #expect(WritingDayFileFormatter.entryID(
            forMilliseconds: captured,
            hexSuffix: "4f2a9c1e",
            timeZone: chicago
        ) == "writing-20260925-104211-387-4f2a9c1e")
    }

    @Test("Later saves append a section only, after one blank line")
    func appends() {
        let header = WritingDayFileFormatter.dayHeader(forMilliseconds: captured, timeZone: chicago, locale: english)
        let first = WritingDayFileFormatter.contents(appending: exampleSection(), to: nil, header: header)
        let later = section(text: "Second note for the afternoon", at: captured + 23 * 60_000)
        let appended = WritingDayFileFormatter.contents(appending: later, to: first, header: header)
        let text = String(decoding: appended, as: UTF8.self)
        #expect(text.hasPrefix(String(decoding: first, as: UTF8.self) + "\n\n## 11:05 AM - Second note for the afternoon\n\n"))
        #expect(text.components(separatedBy: "capture_type: writing_day").count == 2)
        #expect(!text.hasSuffix("\n"))

        let endsBlank = first + Data("\n\n".utf8)
        let noDoubleGap = WritingDayFileFormatter.contents(appending: later, to: endsBlank, header: header)
        #expect(String(decoding: noDoubleGap, as: UTF8.self).contains("pass.\n\n## 11:05 AM"))
    }

    @Test("Very short writing gets a dated title")
    func fallbackTitle() {
        let text = section(text: "on it", at: captured)
        #expect(text.hasPrefix("## 10:42 AM - Writing Sep 25 at 10:42 AM\n"))
    }

    @Test("A line starting like a section heading stays in the body")
    func escapesHeadings() {
        let text = section(text: "## Launch plan for Q4", at: captured)
        #expect(text.hasPrefix("## 10:42 AM - ## Launch plan for Q4\n"))
        #expect(text.hasSuffix("\n\n\\## Launch plan for Q4"))
    }

    @Test("Captured keeps exact milliseconds in UTC")
    func capturedMilliseconds() {
        #expect(WritingDayFileFormatter.iso8601UTC(milliseconds: 1_790_350_931_001) == "2026-09-25T15:42:11.001Z")
        #expect(WritingDayFileFormatter.iso8601UTC(milliseconds: 1_790_350_931_999) == "2026-09-25T15:42:11.999Z")
        #expect(WritingDayFileFormatter.iso8601UTC(milliseconds: 1_790_350_931_000) == "2026-09-25T15:42:11.000Z")
    }

    @Test("An entry belongs to the local day of its first keystroke")
    func localDay() {
        // 2026-09-26T03:30:00Z is still September 25 in Chicago.
        let lateNight: Int64 = 1_790_393_400_000
        #expect(WritingDayFileFormatter.fileName(forMilliseconds: lateNight, timeZone: chicago) == "Writing_2026-09-25.md")
        #expect(WritingDayFileFormatter.fileName(
            forMilliseconds: lateNight,
            timeZone: TimeZone(identifier: "UTC")!
        ) == "Writing_2026-09-26.md")
    }

    private func exampleSection() -> String {
        WritingDayFileFormatter.section(
            WritingDayFileFormatter.Section(
                entryID: "writing-20260925-104211-387-4f2a9c1e",
                capturedAtMilliseconds: captured,
                sourceAppName: "Slack",
                bundleIdentifier: "com.tinyspeck.slackmacgap",
                wordCount: 14,
                characterCount: 71,
                acceptedWordCount: 3,
                text: "Pushing the launch to Thursday so QA can finish the AirPods pass."
            ),
            timeZone: chicago,
            locale: english
        )
    }

    private func section(text: String, at milliseconds: Int64) -> String {
        WritingDayFileFormatter.section(
            WritingDayFileFormatter.Section(
                entryID: "writing-test",
                capturedAtMilliseconds: milliseconds,
                sourceAppName: "Notes",
                bundleIdentifier: "com.apple.Notes",
                wordCount: 1,
                characterCount: text.count,
                acceptedWordCount: 0,
                text: text
            ),
            timeZone: chicago,
            locale: english
        )
    }
}
