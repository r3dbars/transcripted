import SwiftUI

// MARK: - MessageGroup

/// Groups consecutive transcript lines from the same speaker for iMessage-style rendering.
/// Presentation-only model — stays in this file, not in TranscriptStore.
struct MessageGroup: Identifiable {
    let id = UUID()
    let speaker: String?    // Raw: "Mic/You" or "System/Speaker 1"
    let isUser: Bool        // true if speaker starts with "Mic"
    let lines: [TranscriptLine]

    /// "You" → nil (iMessage convention: no label for self).
    /// "System/Speaker 1" → "Speaker 1".
    var displayName: String? {
        guard !isUser, let speaker else { return nil }
        let parts = speaker.split(separator: "/", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : speaker
    }

    var timestamp: String? { lines.first?.timestamp }

    /// O(n) single-pass grouping: merge consecutive lines with the same speaker.
    static func group(_ lines: [TranscriptLine]) -> [MessageGroup] {
        var groups: [MessageGroup] = []
        var currentSpeaker: String?
        var currentLines: [TranscriptLine] = []

        for line in lines {
            if line.speaker == currentSpeaker {
                currentLines.append(line)
            } else {
                if !currentLines.isEmpty {
                    let isUser = currentSpeaker?.lowercased().hasPrefix("mic") ?? false
                    groups.append(MessageGroup(speaker: currentSpeaker, isUser: isUser, lines: currentLines))
                }
                currentSpeaker = line.speaker
                currentLines = [line]
            }
        }
        // Flush last group
        if !currentLines.isEmpty {
            let isUser = currentSpeaker?.lowercased().hasPrefix("mic") ?? false
            groups.append(MessageGroup(speaker: currentSpeaker, isUser: isUser, lines: currentLines))
        }

        return groups
    }
}

// MARK: - TranscriptDetailView

/// Scrollable chat-bubble view showing a transcript as an iMessage-style conversation.
/// "You" (mic) messages are right-aligned with a blue tint; other speakers are left-aligned.
@available(macOS 14.0, *)
struct TranscriptDetailView: View {
    let lines: [TranscriptLine]

    private var groups: [MessageGroup] {
        MessageGroup.group(lines)
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 10) {
                ForEach(groups) { group in
                    MessageGroupView(group: group)
                }
            }
            .padding(.horizontal, Spacing.ms)
            .padding(.vertical, Spacing.sm)
        }
        .frame(maxHeight: 280)
    }
}

// MARK: - MessageGroupView

/// Renders a group of consecutive messages from the same speaker.
/// Right-aligned for user, left-aligned for others, with a spacer on the opposite side.
@available(macOS 14.0, *)
private struct MessageGroupView: View {
    let group: MessageGroup

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if group.isUser { Spacer(minLength: 48) }

            VStack(alignment: group.isUser ? .trailing : .leading, spacing: 2) {
                // Speaker label (only for non-user groups)
                if let name = group.displayName {
                    Text(name)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.panelTextMuted)
                        .padding(.horizontal, 4)
                }

                // Timestamp
                if let ts = group.timestamp {
                    Text(ts)
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.panelTextMuted.opacity(0.7))
                        .padding(.horizontal, 4)
                }

                // Bubbles
                ForEach(group.lines) { line in
                    ChatBubbleView(text: line.text, isUser: group.isUser)
                }
            }

            if !group.isUser { Spacer(minLength: 48) }
        }
    }
}

// MARK: - ChatBubbleView

/// A single chat bubble with rounded corners and tinted background.
@available(macOS 14.0, *)
private struct ChatBubbleView: View {
    let text: String
    let isUser: Bool

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(.panelTextPrimary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: Radius.sm, style: .continuous)
                    .fill(isUser ? Color.chatBubbleUser : Color.panelCharcoalSurface)
            )
    }
}
