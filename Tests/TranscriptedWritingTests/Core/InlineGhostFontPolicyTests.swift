import Testing
@testable import TranscriptedWritingCore

@Suite("Inline ghost font policy")
struct InlineGhostFontPolicyTests {
    @Test("A plausible report always wins over the measured line")
    func plausibleReportAlwaysWinsOverMeasuredLine() {
        // A truthful 16pt font under double line spacing must not be
        // overridden into an oversized ghost by the roomy line rect.
        let resolved = InlineGhostFontPolicy.resolvedPointSize(
            reportedPointSize: 16,
            measuredLineHeight: 32,
            fallbackPointSize: 13
        )

        #expect(resolved == 16)
    }

    @Test("No report falls back to the measured line, not a fabricated size")
    func noReportFallsBackToMeasuredLine() {
        let resolved = InlineGhostFontPolicy.resolvedPointSize(
            reportedPointSize: nil,
            measuredLineHeight: 28,
            fallbackPointSize: 13
        )

        #expect(abs(resolved - 20.16) < 0.01)
    }

    @Test("An implausible report is replaced by the measured line")
    func implausibleReportIsReplacedByMeasuredLine() {
        for reported in [2.0, 500, .nan, -13] {
            let resolved = InlineGhostFontPolicy.resolvedPointSize(
                reportedPointSize: reported,
                measuredLineHeight: 28,
                fallbackPointSize: 13
            )

            #expect(abs(resolved - 20.16) < 0.01)
        }
    }

    @Test("Degenerate line heights leave a plausible report standing")
    func degenerateLineHeightsLeavePlausibleReportStanding() {
        for lineHeight in [4.0, 500, .infinity, -20] {
            let resolved = InlineGhostFontPolicy.resolvedPointSize(
                reportedPointSize: 13,
                measuredLineHeight: lineHeight,
                fallbackPointSize: 11
            )

            #expect(resolved == 13)
        }
    }

    @Test("Nothing trustworthy returns the caller's fallback untouched")
    func nothingTrustworthyReturnsCallerFallback() {
        #expect(InlineGhostFontPolicy.resolvedPointSize(
            reportedPointSize: nil,
            measuredLineHeight: nil,
            fallbackPointSize: 13
        ) == 13)

        #expect(InlineGhostFontPolicy.resolvedPointSize(
            reportedPointSize: .nan,
            measuredLineHeight: .infinity,
            fallbackPointSize: 15
        ) == 15)
    }

    @Test("Derived sizes never leave the plausible band")
    func derivedSizesNeverLeavePlausibleBand() {
        for lineHeight in stride(from: 12.0, through: 130, by: 1) {
            let resolved = InlineGhostFontPolicy.resolvedPointSize(
                reportedPointSize: nil,
                measuredLineHeight: lineHeight,
                fallbackPointSize: 13
            )

            #expect(InlineGhostFontPolicy.plausiblePointSizes.contains(resolved))
        }
    }
}
