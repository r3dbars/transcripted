import AppKit
import SwiftUI

/// Shared design tokens for the quiet-library main-window redesign.
///
/// One accent, four ink levels, one hairline, two radii, five type roles.
/// Main-window surfaces (Home, Dictations, Speakers, Agent, Settings, menu
/// bar popover) should draw from here instead of inlining sizes and colors.
/// The overlays (`Sources/UI/Overlay/`) intentionally keep their own tokens
/// and are out of scope for this pass.
enum LibraryTokens {
    // MARK: Color

    /// The single brand accent: a tamed capture-green. Selection, links,
    /// live progress, played audio. Never used to say "everything is fine".
    static let accent = Color(nsColor: dynamicColor(
        dark: NSColor(red: 0.180, green: 0.741, blue: 0.549, alpha: 1),
        light: NSColor(red: 0.122, green: 0.541, blue: 0.400, alpha: 1)
    ))

    /// Attention amber for failed / needs-action states only.
    static let attention = Color(nsColor: dynamicColor(
        dark: NSColor(red: 0.878, green: 0.639, blue: 0.243, alpha: 1),
        light: NSColor(red: 0.690, green: 0.494, blue: 0.122, alpha: 1)
    ))

    /// Recording red. Recording, and nothing but recording.
    static let recording = Color(nsColor: .systemRed)

    /// Secondary ink for meta text (durations, counts, status lines).
    static let ink2 = Color.primary.opacity(0.55)

    /// Tertiary ink for whisper text (timestamps, labels, hints).
    static let ink3 = Color.primary.opacity(0.34)

    /// The only divider in the main window.
    static let hairline = Color.primary.opacity(0.08)

    /// Hover / selection fill for rows. No stroke.
    static let rowHover = Color.primary.opacity(0.045)

    /// Raised surface fill for the inline expansion card and find bar.
    static let raisedFill = Color.primary.opacity(0.035)
    static let raisedStroke = Color.primary.opacity(0.08)

    /// The two-tone window split (Things-style): a solid darker sidebar
    /// against a solid lighter content pane. No materials, no gradients,
    /// no border boxes — the tone change IS the boundary.
    static let sidebarBackground = Color(nsColor: dynamicColor(
        dark: NSColor(red: 0.100, green: 0.100, blue: 0.106, alpha: 1),
        light: NSColor(red: 0.922, green: 0.922, blue: 0.914, alpha: 1)
    ))
    static let contentBackground = Color(nsColor: dynamicColor(
        dark: NSColor(red: 0.137, green: 0.137, blue: 0.145, alpha: 1),
        light: NSColor(red: 0.969, green: 0.969, blue: 0.961, alpha: 1)
    ))

    // MARK: Type

    /// Window headers and the greeting.
    static let title = Font.system(size: 20, weight: .semibold)
    /// Day-group numerals — the one expressive type moment.
    static let numeral = Font.system(size: 26, weight: .light)
    /// Row titles.
    static let rowTitle = Font.system(size: 13, weight: .medium)
    /// Reading text: transcript, summaries, settings rows.
    static let body = Font.system(size: 13)
    /// Meta text: durations, counts, the header sentence.
    static let meta = Font.system(size: 12)
    /// Whisper labels (TRANSCRIPT, NEEDS A NAME). Apply `labelTracking`.
    static let label = Font.system(size: 10.5, weight: .semibold)
    static let labelTracking: CGFloat = 1.1

    // MARK: Layout

    static let radiusControl: CGFloat = 6
    static let radiusRaised: CGFloat = 10
    static let minimumHitTarget: CGFloat = 40

    // MARK: Helpers

    private static func dynamicColor(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.darkAqua, .aqua])
            return match == .darkAqua ? dark : light
        }
    }
}

/// Whisper section label ("TRANSCRIPT", "NEEDS A NAME", "EVERYONE").
struct LibrarySectionLabel: View {
    let text: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text.uppercased())
                .font(LibraryTokens.label)
                .tracking(LibraryTokens.labelTracking)
                .foregroundStyle(LibraryTokens.ink3)
            if let trailing {
                Spacer(minLength: 8)
                Text(trailing)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink3)
            }
        }
    }
}
