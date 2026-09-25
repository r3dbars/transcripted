import Testing
@testable import TranscriptedWritingCore

@Suite("Inline ghost legibility policy")
struct InlineGhostLegibilityPolicyTests {
    @Test("Marked-text paint clears the floor AFTER alpha compositing")
    func markedTextPaintClearsFloorAfterCompositing() {
        // No halo exists on this surface, so the honest test composites the
        // semi-transparent fill into each background before judging contrast.
        for background in [0.0, 1.0] {
            let composited = InlineGhostLegibilityPolicy.compositedWhite(
                of: .markedText,
                overBackgroundWhite: background
            )
            let compositedLuminance = InlineGhostLegibilityPolicy.relativeLuminance(ofWhite: composited)
            let backgroundLuminance = InlineGhostLegibilityPolicy.relativeLuminance(ofWhite: background)

            #expect(
                InlineGhostLegibilityPolicy.contrastRatio(compositedLuminance, backgroundLuminance)
                    >= InlineGhostLegibilityPolicy.minimumContrastRatio
            )
        }
    }
}
