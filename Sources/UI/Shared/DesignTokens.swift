import AppKit
import SwiftUI

/// The one source for Transcripted's look ("quiet paper, live green").
///
/// Every surface reads from here: the main window and onboarding through
/// `LibraryTokens`, the menu bar popover through `MenuTokens`, the notch island
/// through `NotchIslandPalette`. Colors come in AppKit (`DesignTokens.NS`) and
/// SwiftUI (`DesignTokens.*`) twins that resolve for light and dark.
///
/// Rules: primary buttons are ink, never a hue. Green (`live`) means live or
/// just-worked only: listening, recording, pasted, live progress. Never a
/// button, starred, copied, saved, "You" or today's date. Stream colors are
/// small marks, not fills. How to use it: `docs/ui-tokens.md`.
enum DesignTokens {
    // MARK: AppKit colors

    enum NS {
        /// Main content background (paper).
        static let paper = dynamic(dark: rgb(0x232325), light: rgb(0xF7F7F5))
        /// The darker sidebar tone next to the paper.
        static let paperSidebar = dynamic(dark: rgb(0x1A1A1B), light: rgb(0xEBEBE9))
        /// Primary text and primary-button fill.
        static let ink = dynamic(dark: rgb(0xF7F7F5), light: rgb(0x1A1A19))
        /// Secondary text: durations, counts, status lines.
        static let ink2 = inkAlpha(0.55)
        /// Tertiary text: timestamps, hints, labels.
        static let ink3 = inkAlpha(0.34)
        /// Dividers and quiet strokes.
        static let hairline = dynamic(dark: rgb(0xF7F7F5, alpha: 0.12), light: rgb(0x1A1A19, alpha: 0.08))
        /// Secondary-button border; a hairline that still reads as a control.
        static let hairlineStrong = dynamic(dark: rgb(0xF7F7F5, alpha: 0.22), light: rgb(0x1A1A19, alpha: 0.16))
        /// The one neutral fill: hover rows, raised cards, chips.
        static let fill = dynamic(dark: rgb(0xF7F7F5, alpha: 0.06), light: rgb(0x1A1A19, alpha: 0.045))
        /// Selected or pressed fill.
        static let fillStrong = dynamic(dark: rgb(0xF7F7F5, alpha: 0.12), light: rgb(0x1A1A19, alpha: 0.09))

        /// The root `.tint` for SwiftUI windows (switches, checkboxes, progress,
        /// focus): ink on light. On dark it steps down to a light grey so a
        /// switch's white knob still reads against its track.
        static let controlTint = dynamic(dark: rgb(0x9C9C99), light: rgb(0x1A1A19))

        /// Capture green. Live or just-worked only.
        static let live = dynamic(dark: liveOnDark, light: rgb(0x1F8A66))
        /// Capture green on an always-dark surface (the island, the Writing card).
        static let liveOnDark = rgb(0x2EBD8C)
        /// Failed or needs-action states.
        static let attention = dynamic(dark: rgb(0xE0A33E), light: rgb(0xB07E1F))
        /// Attention amber on an always-dark surface (the island).
        static let attentionOnDark = rgb(0xE0A33E)
        /// The truly destructive confirm, and nothing else. Recording is
        /// live, so its dot is `live` green.
        static let danger = NSColor.systemRed

        /// Stream marks: one hue per capture stream.
        static let dictationStream = dynamic(dark: rgb(0x7ABBA5), light: rgb(0x2F5D50))
        static let meetingsStream = dynamic(dark: rgb(0xB396DA), light: rgb(0x6B4C8A))
        static let writingStream = dynamic(dark: rgb(0xE0A86A), light: rgb(0x9E5F1E))

        private static func inkAlpha(_ alpha: CGFloat) -> NSColor {
            dynamic(dark: rgb(0xF7F7F5, alpha: alpha), light: rgb(0x1A1A19, alpha: alpha))
        }
    }

    // MARK: SwiftUI colors

    static let paper = Color(nsColor: NS.paper)
    static let paperSidebar = Color(nsColor: NS.paperSidebar)
    static let ink = Color(nsColor: NS.ink)
    static let ink2 = Color(nsColor: NS.ink2)
    static let ink3 = Color(nsColor: NS.ink3)
    static let hairline = Color(nsColor: NS.hairline)
    static let hairlineStrong = Color(nsColor: NS.hairlineStrong)
    static let fill = Color(nsColor: NS.fill)
    static let fillStrong = Color(nsColor: NS.fillStrong)
    static let controlTint = Color(nsColor: NS.controlTint)
    static let live = Color(nsColor: NS.live)
    static let attention = Color(nsColor: NS.attention)
    static let danger = Color(nsColor: NS.danger)
    static let dictationStream = Color(nsColor: NS.dictationStream)
    static let meetingsStream = Color(nsColor: NS.meetingsStream)
    static let writingStream = Color(nsColor: NS.writingStream)

    // MARK: Shape

    enum Radius {
        /// Buttons, rows, chips, inputs, popover cards.
        static let control: CGFloat = 6
        /// Cards, toasts, lists.
        static let surface: CGFloat = 12
        /// Capsules: half the height.
        static func pill(height: CGFloat) -> CGFloat { height / 2 }
    }

    static let minimumHitTarget: CGFloat = 40

    // MARK: Helpers

    static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    static func rgb(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

// MARK: - Type roles

/// The six text roles. Use `.textRole(.heading)` in SwiftUI (it applies
/// size, weight, tracking and the label's uppercase) or `role.nsFont` in AppKit.
enum TextRole: CaseIterable, Sendable {
    /// Page titles. 28 semibold, the system font.
    case display
    /// Card and sheet headings. 15 semibold.
    case heading
    /// Reading text, row titles (add `.medium`), settings rows. 13.
    case body
    /// Durations, counts, subtitles. 12.
    case meta
    /// Footnotes, captions, chips. 11.
    case small
    /// Section labels ("TODAY", "TRANSCRIPT"). JetBrains Mono 10.5 medium,
    /// uppercase, tracked; system monospaced when the font isn't bundled.
    case label

    var size: CGFloat {
        switch self {
        case .display: return 28
        case .heading: return 15
        case .body: return 13
        case .meta: return 12
        case .small: return 11
        case .label: return 10.5
        }
    }

    var defaultWeight: NSFont.Weight {
        switch self {
        case .display, .heading: return .semibold
        case .label: return .medium
        case .body, .meta, .small: return .regular
        }
    }

    /// Letter spacing in points.
    var tracking: CGFloat { self == .label ? 0.6 : 0 }

    var isUppercased: Bool { self == .label }

    /// The AppKit font. `weight` applies to the system roles; label keeps
    /// its face's own weight.
    func nsFont(weight: NSFont.Weight? = nil, size overrideSize: CGFloat? = nil) -> NSFont {
        let size = overrideSize ?? self.size
        switch self {
        case .label:
            _ = BundledFonts.registerOnce
            return BundledFonts.font(.jetBrainsMonoMedium, size: size)
                ?? NSFont.monospacedSystemFont(ofSize: size, weight: .medium)
        case .display, .heading, .body, .meta, .small:
            return NSFont.systemFont(ofSize: size, weight: weight ?? defaultWeight)
        }
    }

    /// The SwiftUI font (no tracking or case; use `.textRole(_:)` for those).
    func font(weight: Font.Weight? = nil) -> Font {
        switch self {
        case .label:
            return Font(nsFont() as CTFont)
        case .display, .heading, .body, .meta, .small:
            return .system(size: size, weight: weight ?? Self.swiftUIWeight(defaultWeight))
        }
    }

    private static func swiftUIWeight(_ weight: NSFont.Weight) -> Font.Weight {
        switch weight {
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        default: return .regular
        }
    }
}

extension View {
    /// Applies a text role: font, tracking and (for `.label`) uppercase.
    func textRole(_ role: TextRole, weight: Font.Weight? = nil) -> some View {
        self
            .font(role.font(weight: weight))
            .tracking(role.tracking)
            .textCase(role.isUppercased ? .uppercase : nil)
    }
}

extension View {
    /// The window-root tint: switches, checkboxes, progress and focus in ink
    /// instead of the Mac's accent color. Apply once at each SwiftUI root.
    func transcriptedRootTint() -> some View {
        tint(DesignTokens.controlTint)
    }
}
