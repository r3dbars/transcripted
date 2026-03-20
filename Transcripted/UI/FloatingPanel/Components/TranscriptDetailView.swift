import SwiftUI

// MARK: - MessageGroup

/// Groups consecutive transcript lines from the same speaker for rendering.
/// Presentation-only model — stays in this file, not in TranscriptStore.
struct MessageGroup: Identifiable {
    /// Deterministic ID derived from content so SwiftUI doesn't re-render unchanged groups
    let id: String
    let speaker: String?    // Raw: "Mic/You" or "System/Speaker 1"
    let isUser: Bool        // true if speaker starts with "Mic"
    let lines: [TranscriptLine]

    /// "You" → nil (iMessage convention: no label for self).
    /// "System/Speaker 1" → "Speaker 1".
    var displayName: String? {
        guard let speaker else { return nil }
        let parts = speaker.split(separator: "/", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : speaker
    }

    var timestamp: String? { lines.first?.timestamp }

    /// O(n) single-pass grouping: merge consecutive lines with the same speaker.
    static func group(_ lines: [TranscriptLine]) -> [MessageGroup] {
        var groups: [MessageGroup] = []
        var currentSpeaker: String?
        var currentLines: [TranscriptLine] = []
        var groupIndex = 0

        for line in lines {
            if line.speaker == currentSpeaker {
                currentLines.append(line)
            } else {
                if !currentLines.isEmpty {
                    let isUser = currentSpeaker?.lowercased().hasPrefix("mic") ?? false
                    let stableId = "\(groupIndex)_\(currentSpeaker ?? "nil")_\(currentLines.first?.timestamp ?? "")"
                    groups.append(MessageGroup(id: stableId, speaker: currentSpeaker, isUser: isUser, lines: currentLines))
                    groupIndex += 1
                }
                currentSpeaker = line.speaker
                currentLines = [line]
            }
        }
        // Flush last group
        if !currentLines.isEmpty {
            let isUser = currentSpeaker?.lowercased().hasPrefix("mic") ?? false
            let stableId = "\(groupIndex)_\(currentSpeaker ?? "nil")_\(currentLines.first?.timestamp ?? "")"
            groups.append(MessageGroup(id: stableId, speaker: currentSpeaker, isUser: isUser, lines: currentLines))
        }

        return groups
    }
}

// MARK: - TranscriptDetailView

/// Scrollable dialogue view showing a transcript in a compact, full-width block format.
/// Each speaker block has a colored left border, speaker name + timestamp header, and full-width text.
@available(macOS 14.0, *)
struct TranscriptDetailView: View {
    let lines: [TranscriptLine]

    private var groups: [MessageGroup] {
        MessageGroup.group(lines)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 10) {
                    ForEach(groups) { group in
                        DialogueBlockView(group: group)
                    }
                    // Invisible anchor at the top
                    Color.clear.frame(height: 1).id("top")
                }
                .padding(.horizontal, Spacing.ms)
                .padding(.vertical, Spacing.sm)
            }
            .frame(maxHeight: 280)
            .onAppear {
                // Scroll to top — transcripts are read chronologically
                proxy.scrollTo(groups.first?.id, anchor: .top)
            }
        }
    }
}

// MARK: - DialogueBlockView

/// A compact dialogue block: speaker name + timestamp on one line, full-width text below.
/// Uses a 3px colored left border per speaker for visual differentiation.
@available(macOS 14.0, *)
private struct DialogueBlockView: View {
    let group: MessageGroup

    /// Stable color per speaker name using hash
    private var speakerColor: Color {
        guard let name = group.displayName ?? group.speaker else {
            return group.isUser ? .accentBlue : .panelTextMuted
        }
        let speakerColors: [Color] = [
            Color(hue: 0.55, saturation: 0.35, brightness: 0.55),  // muted blue
            Color(hue: 0.75, saturation: 0.30, brightness: 0.55),  // muted purple
            Color(hue: 0.45, saturation: 0.35, brightness: 0.50),  // muted teal
            Color(hue: 0.10, saturation: 0.35, brightness: 0.55),  // muted amber
            Color(hue: 0.90, saturation: 0.30, brightness: 0.55),  // muted rose
        ]
        if group.isUser { return .accentBlue }
        let index = abs(name.hashValue) % speakerColors.count
        return speakerColors[index]
    }

    var body: some View {
        HStack(spacing: 0) {
            // Colored left border
            RoundedRectangle(cornerRadius: 1.5)
                .fill(speakerColor)
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 3) {
                // Header: speaker name + timestamp
                HStack {
                    Text(group.displayName ?? (group.isUser ? "You" : "Speaker"))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(speakerColor)

                    Spacer()

                    if let ts = group.timestamp {
                        Text(ts)
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundColor(.panelTextMuted.opacity(0.7))
                    }
                }

                // Full-width text content
                ForEach(group.lines) { line in
                    Text(line.text)
                        .font(.system(size: 12))
                        .foregroundColor(.panelTextPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.leading, 8)
        }
    }
}
