import Foundation

/// Resolves the point size the inline ghost renders at. Web/Electron
/// composers routinely omit their font over the input-method protocol, and
/// the old fix — filling the absence with a fabricated default — is what
/// made ghosts render tiny. A plausible reported font is trusted (a wrong
/// override would distort hosts with roomy line spacing, and a client that
/// honors our styling renders its own reported font correctly anyway);
/// only when the report is absent or implausible does the caret line's
/// measured on-screen height stand in. With neither, the caller's own
/// fallback is returned untouched — never a fabricated size.
public enum InlineGhostFontPolicy {
    /// Reported sizes outside this band are noise, not fonts.
    public static let plausiblePointSizes = 9.0...96.0
    /// Line rects outside this band don't describe a single text line.
    static let plausibleLineHeights = 12.0...130.0
    /// Typical text sets its line height at roughly 1.4× the point size.
    static let pointSizePerLineHeight = 0.72

    public static func resolvedPointSize(
        reportedPointSize: Double?,
        measuredLineHeight: Double?,
        fallbackPointSize: Double
    ) -> Double {
        if let reported = plausibleReportedSize(reportedPointSize) {
            return reported
        }

        if let derived = derivedPointSize(measuredLineHeight) {
            return derived
        }

        return fallbackPointSize
    }

    private static func plausibleReportedSize(_ size: Double?) -> Double? {
        guard let size, size.isFinite, plausiblePointSizes.contains(size) else {
            return nil
        }

        return size
    }

    private static func derivedPointSize(_ lineHeight: Double?) -> Double? {
        guard let lineHeight, lineHeight.isFinite, plausibleLineHeights.contains(lineHeight) else {
            return nil
        }

        let derived = lineHeight * pointSizePerLineHeight
        return min(max(derived, plausiblePointSizes.lowerBound), plausiblePointSizes.upperBound)
    }
}
