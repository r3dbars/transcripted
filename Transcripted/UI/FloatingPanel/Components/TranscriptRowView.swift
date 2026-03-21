import SwiftUI
import AppKit

// MARK: - TranscriptRowView

/// A single row in the transcript tray.
/// Shows title, relative date, duration on the left; Copy button on the right.
@available(macOS 14.0, *)
struct TranscriptRowView: View {
    let transcript: TranscriptSummary
    let isCopied: Bool
    var copyFailed: Bool = false
    let onCopy: () -> Void
    var onSelect: (() -> Void)?

    @State private var isHovered = false

    /// Whether the transcript has a meaningful Qwen-generated title (not just "Meeting")
    private var hasSmartTitle: Bool {
        transcript.title != "Meeting"
    }

    /// Primary title: prefer smart title, fall back to speaker names, then generic
    private var primaryTitle: String {
        if hasSmartTitle { return transcript.title }
        let names = transcript.speakerNames
        if names.isEmpty {
            if transcript.speakerCount > 0 {
                return "Meeting \u{00B7} \(transcript.speakerCount) speaker\(transcript.speakerCount == 1 ? "" : "s")"
            }
            return "Meeting"
        }
        if names.count <= 2 {
            return names.joined(separator: ", ")
        }
        let firstNames = names.prefix(2).map { firstName($0) }
        let overflow = names.count - 2
        return "\(firstNames.joined(separator: ", ")), +\(overflow) more"
    }

    /// Speaker subtitle shown below smart titles (e.g. "Dwarkesh Patel, Terence Tao")
    private var speakerSubtitle: String? {
        guard hasSmartTitle else { return nil }
        let names = transcript.speakerNames
        if !names.isEmpty {
            if names.count <= 2 {
                return names.joined(separator: ", ")
            }
            return "\(names.count) speakers"
        }
        if transcript.speakerCount > 0 {
            return "\(transcript.speakerCount) speaker\(transcript.speakerCount == 1 ? "" : "s")"
        }
        return nil
    }

    private func firstName(_ fullName: String) -> String {
        let parts = fullName.split(separator: " ")
        return parts.first.map(String.init) ?? fullName
    }

    var body: some View {
        HStack(spacing: Spacing.sm) {
            // Left: title + optional speaker subtitle + metadata
            VStack(alignment: .leading, spacing: 2) {
                Text(primaryTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.panelTextPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                if let subtitle = speakerSubtitle {
                    Text(subtitle)
                        .font(.system(size: 10))
                        .foregroundColor(.panelTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                HStack(spacing: 4) {
                    Text(relativeDate)
                        .font(.system(size: 10))
                        .foregroundColor(.panelTextMuted)

                    if !transcript.duration.isEmpty {
                        Text("\u{00B7}")
                            .font(.system(size: 8))
                            .foregroundColor(.panelTextMuted.opacity(0.6))

                        Text(transcript.duration)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.panelTextMuted)
                    }
                }
            }

            Spacer(minLength: Spacing.xs)

            // Right: Copy button (icon-only, minimal)
            copyButton
        }
        .padding(.horizontal, Spacing.ms)
        .padding(.vertical, Spacing.sm)
        .background(isHovered ? Color.panelCharcoalSurface.opacity(0.5) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { onSelect?() }
        .onHover { hovering in
            withAnimation(.snappy(duration: 0.1)) { isHovered = hovering }
        }
        .animation(.snappy(duration: 0.1), value: isHovered)
    }

    // MARK: - Copy Button

    @State private var isCopyHovered = false

    private var copyButton: some View {
        Button(action: onCopy) {
            ZStack {
                Circle()
                    .fill(
                        copyFailed
                            ? Color.recordingCoral.opacity(0.15)
                            : isCopied
                                ? Color.statusSuccessMuted.opacity(0.15)
                                : ((isCopyHovered || isHovered) ? Color.panelCharcoalSurface : Color.clear)
                    )
                    .frame(width: 24, height: 24)

                if copyFailed {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.recordingCoral)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                } else if isCopied {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundColor(.statusSuccessMuted)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                } else {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundColor(isCopyHovered ? .panelTextPrimary : .panelTextMuted)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
            .animation(.snappy(duration: 0.15), value: isCopied)
            .animation(.snappy(duration: 0.15), value: copyFailed)
            .animation(.snappy(duration: 0.1), value: isCopyHovered)
        }
        .buttonStyle(PlainButtonStyle())
        .onHover { hovering in isCopyHovered = hovering }
        .help(copyFailed ? "Could not read transcript" : isCopied ? "Copied to clipboard" : "Copy transcript for AI")
    }

    // MARK: - Relative Date

    private var relativeDate: String {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute], from: transcript.date)
        let hasTime = !((comps.hour ?? 0) == 0 && (comps.minute ?? 0) == 0)

        let tf = DateFormatter()
        tf.dateFormat = "h:mm a"
        let timeStr = tf.string(from: transcript.date)

        if cal.isDateInToday(transcript.date) {
            return hasTime ? "Today at \(timeStr)" : "Today"
        }
        if cal.isDateInYesterday(transcript.date) {
            return hasTime ? "Yesterday at \(timeStr)" : "Yesterday"
        }
        let df = DateFormatter()
        df.dateFormat = "MMM d"
        let dateStr = df.string(from: transcript.date)
        return hasTime ? "\(dateStr) at \(timeStr)" : dateStr
    }
}
