import AppKit
import SwiftUI

/// Main-window names for the shared tokens in `DesignTokens.swift`.
///
/// The values live in `DesignTokens` (one source for the main window, the
/// popover and the island); these names stay so existing pages keep working.
/// New code can use either. Guide: `docs/ui-tokens.md`.
enum LibraryTokens {
    // MARK: Color

    /// Capture green: live or just-worked only (listening, recording, pasted,
    /// live progress, played audio). Never a button, never "starred",
    /// "copied", "saved", "You" or today's date.
    static let accent = DesignTokens.live

    /// Attention amber for failed / needs-action states only.
    static let attention = DesignTokens.attention

    /// Recording red. Recording, and nothing but recording.
    static let recording = DesignTokens.danger

    /// Stream colors: one hue per capture stream, used as small marks where
    /// meetings, dictation and writing sit side by side. Not a second accent;
    /// never used for selection, state or fills.
    static let meetingsStream = DesignTokens.meetingsStream
    static let dictationStream = DesignTokens.dictationStream
    static let writingStream = DesignTokens.writingStream

    /// Primary ink: text and the primary-button fill.
    static let ink = DesignTokens.ink

    /// Secondary ink for meta text (durations, counts, status lines).
    static let ink2 = DesignTokens.ink2

    /// Tertiary ink for whisper text (timestamps, labels, hints).
    static let ink3 = DesignTokens.ink3

    /// The only divider in the main window.
    static let hairline = DesignTokens.hairline

    /// Hover / selection fill for rows. No stroke.
    static let rowHover = DesignTokens.fill

    /// Raised surface fill for the inline expansion card and find bar.
    static let raisedFill = DesignTokens.fill
    static let raisedStroke = DesignTokens.hairline

    /// The two-tone window split: a solid darker sidebar against a solid
    /// lighter content pane (paper). No materials, no gradients.
    static let sidebarBackground = DesignTokens.paperSidebar
    static let contentBackground = DesignTokens.paper

    // MARK: Type

    /// Page titles (Meetings, Dictations, Speakers, …): the display serif.
    static var title: Font { TextRole.display.font() }
    /// Card and sheet headings.
    static var heading: Font { TextRole.heading.font() }
    /// Row titles.
    static let rowTitle = Font.system(size: 13, weight: .medium)
    /// Reading text: transcript, summaries, settings rows.
    static let body = Font.system(size: 13)
    /// Meta text: durations, counts, the header sentence.
    static let meta = Font.system(size: 12)
    /// Footnotes and captions.
    static let small = Font.system(size: 11)
    /// Whisper labels (TRANSCRIPT, NEEDS A NAME): the mono label. Apply
    /// `labelTracking` and uppercase, or use `.textRole(.label)`.
    static var label: Font { TextRole.label.font() }
    static let labelTracking: CGFloat = TextRole.label.tracking

    // MARK: Layout

    static let radiusControl: CGFloat = DesignTokens.Radius.control
    static let radiusRaised: CGFloat = DesignTokens.Radius.surface
    static let minimumHitTarget: CGFloat = DesignTokens.minimumHitTarget
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
