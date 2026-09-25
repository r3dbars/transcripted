import Foundation

/// Grayscale paint for inline ghost text. The ghost must stay readable over
/// any editor background, because web/Electron composers routinely misreport
/// their text colors and the true background is unknowable from outside.
public struct InlineGhostColorSpec: Equatable, Sendable {
    public let fillWhite: Double
    public let fillAlpha: Double

    public init(fillWhite: Double, fillAlpha: Double) {
        self.fillWhite = fillWhite
        self.fillAlpha = fillAlpha
    }

    /// Marked-text surfaces get no halo — the host composites the fill
    /// straight into its own text — so this fill must clear the contrast
    /// floor AFTER alpha compositing over both pure black and pure white.
    /// One paint, no report consulted: the clients that honor marked-text
    /// styling are the same ones that misreport their colors.
    public static let markedText = InlineGhostColorSpec(
        fillWhite: 0.50,
        fillAlpha: 0.92
    )
}

public enum InlineGhostLegibilityPolicy {
    /// The paint must clear this WCAG contrast ratio against pure white and
    /// pure black.
    public static let minimumContrastRatio: Double = 3

    /// The gray a semi-transparent fill actually becomes once the host
    /// composites it over a background — the only gray contrast can be
    /// honestly judged on for halo-less surfaces.
    public static func compositedWhite(
        of spec: InlineGhostColorSpec,
        overBackgroundWhite background: Double
    ) -> Double {
        (spec.fillAlpha * spec.fillWhite) + ((1 - spec.fillAlpha) * background)
    }

    public static func relativeLuminance(ofWhite white: Double) -> Double {
        let clamped = min(max(white, 0), 1)
        guard clamped > 0.03928 else {
            return clamped / 12.92
        }

        return pow((clamped + 0.055) / 1.055, 2.4)
    }

    public static func contrastRatio(_ first: Double, _ second: Double) -> Double {
        (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }
}
