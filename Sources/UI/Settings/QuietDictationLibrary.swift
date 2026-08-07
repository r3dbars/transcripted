import AppKit
import SwiftUI

// Quiet-library Dictations components (2026-08 redesign).
//
// The daily `Dictations_YYYY-MM-DD.md` file stays the storage shape (see
// `Sources/Dictation/CLAUDE.md`), but the list is presented and interacted
// with per entry, not per file: one row per dictation, title-first, with the
// time right-aligned. Hover reveals Copy + an overflow menu; clicking a row
// opens a raised inline expansion with the full text — mirrors
// `Sources/UI/Settings/QuietHomeLibrary.swift`'s meeting row/expansion pair.

// MARK: - Formatting

/// Foundation-pure text helpers for the per-entry dictation rows. `SavedDictationEntry`
/// already carries per-entry text/timestamp/source-app data (parsed by
/// `DictationTranscriptStore` from the day file's entry grammar), so this only
/// derives small display strings from it — it does not re-parse Markdown.
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

enum QuietDictationLibraryFormatting {
    /// The first line of the dictated text, used as the collapsed row's title.
    /// Falls back to the entry's generated title if the body is empty.
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
        text.split(whereSeparator: \.isWhitespace).count
    }

    /// The paste-destination clause for an entry's meta line. Only claims a
    /// destination app when the entry's own `delivery`/`sourceAppName` say so
    /// — never invented for `.copied`/`.failed`/`.savedWithoutPaste`.
    static func deliveryDescription(delivery: DictationDelivery, sourceAppName: String) -> String {
        switch delivery {
        case .pasted:
            return "pasted into \(sourceAppName)"
        case .copied:
            return "copied to clipboard"
        case .failed, .savedWithoutPaste:
            return "saved only"
        }
    }

    static func metaLine(for entry: SavedDictationEntry, time: String) -> String {
        let words = wordCount(of: entry.text)
        let wordsText = words == 1 ? "1 word" : "\(words) words"
        let delivery = deliveryDescription(delivery: entry.delivery, sourceAppName: entry.sourceAppName)
        return [time, wordsText, delivery].joined(separator: "  \u{00B7}  ")
    }
}

// MARK: - Row

/// Title-first dictation row. The first line of the dictated text always
/// shows, truncated to one line, regular weight; the captured time stays
/// right-aligned and always visible. Copy + the overflow menu fade in only
/// on hover.
struct QuietDictationRow: View {
    let entry: SavedDictationEntry
    let isCopied: Bool
    let onOpen: () -> Void
    let onCopy: () -> Void
    let menuItems: [HomeRowMenuItem]

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Text(QuietDictationLibraryFormatting.firstLine(of: entry.text, fallback: entry.title))
                .font(LibraryTokens.body)
                .foregroundStyle(Color.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier("transcripted.dictations.row.title")

            Spacer(minLength: 12)

            // Always present so the row keeps one constant height; hover only
            // fades the actions in and tints the background — no size change.
            HomeRowActionButtons(
                isCopied: isCopied,
                onCopy: onCopy,
                onFlag: {},
                menuItems: menuItems,
                copyAutomationIdentifier: "transcripted.dictations.row.copy"
            )
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
            .accessibilityHidden(!isHovering)

            Text(timeString)
                .font(LibraryTokens.meta)
                .foregroundStyle(LibraryTokens.ink3)
                .fixedSize()
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusControl + 1, style: .continuous)
                .fill(isHovering ? LibraryTokens.rowHover : Color.clear)
        )
        .padding(.horizontal, -10)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovering = hovering }
        }
        .onTapGesture(perform: onOpen)
        .help("Open dictation")
        .accessibilityIdentifier("transcripted.dictations.row")
    }

    private var timeString: String {
        HomeActivityRowFormatting.timeFormatter.string(from: entry.createdAt)
    }
}

// MARK: - Inline expansion

/// The opened dictation: full text, a quiet meta line, and footer actions —
/// revealed in place within the list, raised on `LibraryTokens.raisedFill`.
struct QuietDictationExpansion: View {
    let entry: SavedDictationEntry
    let isCopied: Bool
    let onCopy: () -> Void
    let onOpenFile: () -> Void
    let onCollapse: () -> Void
    let menuItems: [HomeRowMenuItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(entry.text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(LibraryTokens.body)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier("transcripted.dictations.expansion.text")

            Text(metaLine)
                .font(.system(size: 11.5))
                .foregroundStyle(LibraryTokens.ink3)
                .padding(.top, 8)
                .contentShape(Rectangle())
                .onTapGesture(perform: onCollapse)
                .help("Collapse dictation")

            HStack(spacing: 16) {
                quietAction(
                    title: isCopied ? "Copied" : "Copy",
                    symbol: isCopied ? "checkmark" : "square.on.square",
                    tint: isCopied ? LibraryTokens.accent : LibraryTokens.ink2,
                    action: onCopy
                )
                .accessibilityIdentifier("transcripted.dictations.expansion.copy")

                quietAction(
                    title: "Open file",
                    symbol: "arrow.down.doc",
                    tint: LibraryTokens.ink2,
                    action: onOpenFile
                )
                .accessibilityIdentifier("transcripted.dictations.expansion.open")

                Spacer()

                if !menuItems.isEmpty {
                    HomeRowMoreMenuButton(
                        items: menuItems,
                        automationIdentifier: "transcripted.dictations.expansion.more"
                    )
                    .frame(width: 24, height: 24)
                }
            }
            .padding(.top, 12)
            .overlay(alignment: .top) {
                Rectangle().fill(LibraryTokens.hairline).frame(height: 1)
                    .padding(.top, 6)
            }

            // Hidden control so Esc collapses the expansion, matching
            // QuietMeetingExpansion's escape affordance.
            Button(action: onCollapse) { EmptyView() }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised, style: .continuous)
                .fill(LibraryTokens.raisedFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised, style: .continuous)
                .stroke(LibraryTokens.raisedStroke, lineWidth: 1)
        )
        .padding(.vertical, 6)
        .accessibilityIdentifier("transcripted.dictations.expansion")
    }

    private var metaLine: String {
        QuietDictationLibraryFormatting.metaLine(
            for: entry,
            time: HomeActivityRowFormatting.timeFormatter.string(from: entry.createdAt)
        )
    }

    private func quietAction(title: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(LibraryTokens.meta)
            }
            .foregroundStyle(tint)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
