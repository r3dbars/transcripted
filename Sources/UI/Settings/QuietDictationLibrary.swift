import AppKit
import SwiftUI

// Dictations page cards (2026-11 unified matte editorial pass).
//
// The daily `Dictations_YYYY-MM-DD.md` file stays the storage shape (see
// `Sources/Dictation/AGENTS.md`); the page shows one borderless matte card per
// entry, sharing `HomeMeetingCardSurface` and `HomeMeetingRowLayout` with
// Meetings. The dictated words sit on top in clean upright ink (clamped to four
// lines with Show more); the quiet metadata, Copy / ⋯ (on hover), and neutral
// play button sit below, expanding a recessed milled mini rail while playing
// (`DictationPlaybackBar.swift`).

/// Stable `CaptureUndoManager` ids for dictation entries. The prefix keeps
/// dictation offers distinguishable from meeting offers (whose ids are raw
/// transcript paths) so each surface renders only its own orphaned offers.
enum DictationUndoID {
    private static let prefix = "dictation:"

    static func id(for entry: SavedDictationEntry) -> String {
        prefix + entry.id
    }

    static func isDictationUndoID(_ id: String) -> Bool {
        id.hasPrefix(prefix)
    }
}

/// Small display strings derived from a saved entry (it does not re-parse
/// Markdown). The card's metadata line is `DictationCardFormatting`.
enum QuietDictationLibraryFormatting {
    /// The first line of the dictated text, used for undo previews and the
    /// Writing page's rows. Falls back to the entry's generated title if the
    /// body is empty.
    static func firstLine(of text: String, fallback: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? fallback : trimmed
        if let newlineIndex = candidate.firstIndex(where: { $0.isNewline }) {
            return String(candidate[..<newlineIndex])
        }
        return candidate
    }

    static func truncated(_ text: String, maxLength: Int) -> String {
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength)).trimmingCharacters(in: .whitespaces) + "\u{2026}"
    }

    static func wordCount(of text: String) -> Int {
        DictationCardFormatting.wordCount(of: text)
    }
}

// MARK: - Card

/// One saved dictation on the same borderless matte card surface as Meetings:
/// upright dictated words on top (clamped to four lines with Show more), quiet
/// metadata and neutral controls below, and a recessed milled mini rail while
/// playing.
struct QuietDictationCard: View {
    let entry: SavedDictationEntry
    let isCopied: Bool
    /// Kept-audio facts once loaded; nil while unknown.
    let audioInfo: DictationAudioInfoStore.Info?
    let isTranscribingAgain: Bool
    @ObservedObject var playback: DictationPlaybackController
    let menuItems: [HomeRowMenuItem]
    let onTogglePlayback: () -> Void
    let onCopy: () -> Void
    let onLoadAudioInfo: () async -> Void
    let onShowMore: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @State private var isExpanded = false
    @State private var clampedHeight: CGFloat = 0
    @State private var fullHeight: CGFloat = 0

    private var text: String {
        entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isLong: Bool {
        fullHeight > clampedHeight + 1
    }

    private var isActivePlayback: Bool {
        playback.isActive(entry.id)
    }

    private var metadata: [DictationCardFormatting.MetadataItem] {
        DictationCardFormatting.metadata(
            time: HomeActivityRowFormatting.timeFormatter.string(from: entry.createdAt),
            length: audioInfo?.duration,
            wordCount: DictationCardFormatting.wordCount(of: entry.text),
            appName: entry.sourceAppName,
            delivery: entry.delivery
        )
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: HomeMeetingRowLayout.cardRadius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            if !text.isEmpty {
                bodyText
            }

            if isLong || isExpanded {
                showMoreButton
                    .padding(.top, 6)
            }

            DictationCardBar(
                entryID: entry.id,
                metadata: metadata,
                hasAudio: audioInfo?.isAvailable == true,
                isCheckingAudio: entry.audioRelativePath != nil && audioInfo == nil,
                isTranscribingAgain: isTranscribingAgain,
                showsActions: isHovering || isActivePlayback,
                isCopied: isCopied,
                menuItems: menuItems,
                playback: playback,
                onTogglePlayback: onTogglePlayback,
                onCopy: onCopy
            )
            .padding(.top, text.isEmpty ? 0 : 10)

            if isActivePlayback {
                DictationInlinePlayer(entryID: entry.id, playback: playback)
                    .padding(.top, 10)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(HomeMeetingRowLayout.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .background(
            shape
                .fill(isHovering || isActivePlayback ? HomeMeetingCardSurface.liftedFill : HomeMeetingCardSurface.fill)
                .shadow(
                    color: isActivePlayback ? HomeMeetingCardSurface.openShadow : HomeMeetingCardSurface.shadow,
                    radius: isActivePlayback ? 12 : 1,
                    y: isActivePlayback ? 6 : 1
                )
        )
        .padding(.bottom, HomeMeetingRowLayout.cardSpacing)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isHovering)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: isActivePlayback)
        .onHover { isHovering = $0 }
        .task(id: entry.id) {
            await onLoadAudioInfo()
        }
        .accessibilityElement(children: .contain)
        // The hover-only buttons, reachable from the card itself too.
        .accessibilityAction(named: Text("Copy"), onCopy)
        .modifier(DictationMenuAccessibilityActions(items: menuItems))
        .accessibilityIdentifier("transcripted.dictations.row")
    }

    private var bodyText: some View {
        styledText
            .lineLimit(isExpanded ? nil : 4)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                if !isExpanded { clampedHeight = height }
            }
            // An unclamped copy, never shown, says whether four lines cut
            // anything off.
            .background(alignment: .topLeading) {
                styledText
                    .fixedSize(horizontal: false, vertical: true)
                    .hidden()
                    .accessibilityHidden(true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                        fullHeight = height
                    }
            }
            .accessibilityIdentifier("transcripted.dictations.row.text")
    }

    private var styledText: some View {
        Text(text)
            .font(LibraryTokens.body)
            .foregroundStyle(LibraryTokens.ink)
            .lineSpacing(4.5)
    }

    private var showMoreButton: some View {
        Button {
            let expanding = !isExpanded
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                isExpanded = expanding
            }
            if expanding { onShowMore() }
        } label: {
            HStack(spacing: 3) {
                Text(isExpanded ? "Show less" : "Show more")
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
            }
            .font(.system(size: 11))
            .foregroundStyle(LibraryTokens.ink3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("transcripted.dictations.row.showMore")
    }
}

/// Each ⋯ menu item as a named VoiceOver action on the card.
private struct DictationMenuAccessibilityActions: ViewModifier {
    let items: [HomeRowMenuItem]

    func body(content: Content) -> some View {
        items.filter(\.isEnabled).reduce(AnyView(content)) { view, item in
            AnyView(view.accessibilityAction(named: Text(item.title), item.action))
        }
    }
}
