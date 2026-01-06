import SwiftUI
import AppKit

/// Help view with FAQ, keyboard shortcuts, and support links
@available(macOS 14.0, *)
struct HelpView: View {

    @State private var expandedFAQ: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                // Header
                headerSection

                // FAQ Section
                faqSection

                // Keyboard Shortcuts Section
                keyboardShortcutsSection

                // Support Section
                supportSection
            }
            .padding(Spacing.lg)
        }
        .background(Color.panelCharcoal)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Help")
                .font(.headingLarge)
                .foregroundColor(.panelTextPrimary)

            Text("Frequently asked questions and support")
                .font(.bodySmall)
                .foregroundColor(.panelTextSecondary)
        }
    }

    // MARK: - FAQ Section

    private var faqSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // Section header
            HStack(spacing: Spacing.sm) {
                Image(systemName: "questionmark.circle.fill")
                    .foregroundColor(.recordingCoral)
                Text("Frequently Asked Questions")
                    .font(.headingSmall)
                    .foregroundColor(.panelTextPrimary)
            }

            // FAQ items
            VStack(spacing: Spacing.sm) {
                ForEach(faqItems, id: \.question) { item in
                    FAQItemView(
                        item: item,
                        isExpanded: expandedFAQ.contains(item.question),
                        onToggle: {
                            withAnimation(.lawsStateChange) {
                                if expandedFAQ.contains(item.question) {
                                    expandedFAQ.remove(item.question)
                                } else {
                                    expandedFAQ.insert(item.question)
                                }
                            }
                        }
                    )
                }
            }
            .padding(Spacing.md)
            .background {
                RoundedRectangle(cornerRadius: Radius.lawsCard, style: .continuous)
                    .fill(Color.panelCharcoalElevated)
            }
        }
    }

    private var faqItems: [FAQItem] {
        [
            FAQItem(
                question: "How do I start a recording?",
                answer: "Click the floating pill near your dock, or use the keyboard shortcut ⌘R. The pill will expand to show recording controls."
            ),
            FAQItem(
                question: "Why isn't system audio being captured?",
                answer: "System audio capture requires Screen Recording permission. Go to System Settings → Privacy & Security → Screen Recording and enable Transcripted. You may need to restart the app after granting permission."
            ),
            FAQItem(
                question: "How do action items work?",
                answer: "After transcription, Gemini AI analyzes your transcript and extracts action items with owners and due dates. You can review and approve them before they're sent to Apple Reminders or Todoist."
            ),
            FAQItem(
                question: "Where are my transcripts saved?",
                answer: "By default, transcripts are saved to ~/Documents/Transcripted/ as markdown files. You can change this location in Preferences → Storage."
            ),
            FAQItem(
                question: "How do I get API keys?",
                answer: "Deepgram: Sign up at deepgram.com and get your key from the console.\n\nGemini: Go to aistudio.google.com and create an API key.\n\nTodoist (optional): Get your API key from the Todoist app settings under Integrations."
            ),
            FAQItem(
                question: "What's the Aurora Recording Indicator?",
                answer: "When enabled, the recording pill shows a flowing color animation that responds to audio levels - coral for your microphone and teal for system audio. It's a visual way to see that both audio sources are being captured."
            )
        ]
    }

    // MARK: - Keyboard Shortcuts Section

    private var keyboardShortcutsSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // Section header
            HStack(spacing: Spacing.sm) {
                Image(systemName: "keyboard.fill")
                    .foregroundColor(.recordingCoral)
                Text("Keyboard Shortcuts")
                    .font(.headingSmall)
                    .foregroundColor(.panelTextPrimary)
            }

            // Shortcuts
            VStack(spacing: Spacing.sm) {
                KeyboardShortcutRow(keys: "⌘ R", action: "Start/Stop Recording")
                KeyboardShortcutRow(keys: "⌘ ,", action: "Open Settings")
                KeyboardShortcutRow(keys: "⌘ Q", action: "Quit Transcripted")
            }
            .padding(Spacing.md)
            .background {
                RoundedRectangle(cornerRadius: Radius.lawsCard, style: .continuous)
                    .fill(Color.panelCharcoalElevated)
            }
        }
    }

    // MARK: - Support Section

    private var supportSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            // Section header
            HStack(spacing: Spacing.sm) {
                Image(systemName: "envelope.fill")
                    .foregroundColor(.recordingCoral)
                Text("Support")
                    .font(.headingSmall)
                    .foregroundColor(.panelTextPrimary)
            }

            // Support links
            VStack(spacing: Spacing.sm) {
                SupportLinkRow(
                    icon: "envelope",
                    title: "Send Feedback",
                    subtitle: "Let us know what you think",
                    action: { sendFeedbackEmail() }
                )

                Divider()
                    .background(Color.panelCharcoalSurface)

                SupportLinkRow(
                    icon: "book.closed",
                    title: "Documentation",
                    subtitle: "Learn more about Transcripted",
                    action: { openDocumentation() }
                )

                Divider()
                    .background(Color.panelCharcoalSurface)

                SupportLinkRow(
                    icon: "ant.fill",
                    title: "Report a Bug",
                    subtitle: "Help us improve",
                    action: { reportBug() }
                )
            }
            .padding(Spacing.md)
            .background {
                RoundedRectangle(cornerRadius: Radius.lawsCard, style: .continuous)
                    .fill(Color.panelCharcoalElevated)
            }

            // Version info
            HStack {
                Text("Transcripted v1.0.0")
                    .font(.caption)
                    .foregroundColor(.panelTextMuted)

                Spacer()

                Text("Made with ❤️")
                    .font(.caption)
                    .foregroundColor(.panelTextMuted)
            }
            .padding(.top, Spacing.md)
        }
    }

    // MARK: - Actions

    private func sendFeedbackEmail() {
        let email = "feedback@transcripted.app"
        let subject = "Transcripted Feedback"
        let urlString = "mailto:\(email)?subject=\(subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject)"

        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }

    private func openDocumentation() {
        // Placeholder - update with real documentation URL
        if let url = URL(string: "https://github.com/transcripted/docs") {
            NSWorkspace.shared.open(url)
        }
    }

    private func reportBug() {
        // Placeholder - update with real bug report URL
        if let url = URL(string: "https://github.com/transcripted/issues/new") {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - FAQ Item

struct FAQItem {
    let question: String
    let answer: String
}

@available(macOS 14.0, *)
struct FAQItemView: View {

    let item: FAQItem
    let isExpanded: Bool
    let onToggle: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Question button
            Button(action: onToggle) {
                HStack {
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundColor(.panelTextMuted)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))

                    Text(item.question)
                        .font(.bodyMedium)
                        .foregroundColor(.panelTextPrimary)
                        .multilineTextAlignment(.leading)

                    Spacer()
                }
                .padding(.vertical, Spacing.sm)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(isHovered ? Color.panelCharcoalSurface.opacity(0.5) : Color.clear)
            .onHover { hovering in
                isHovered = hovering
            }

            // Answer (expandable)
            if isExpanded {
                Text(item.answer)
                    .font(.bodySmall)
                    .foregroundColor(.panelTextSecondary)
                    .padding(.leading, Spacing.lg)
                    .padding(.bottom, Spacing.sm)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            Divider()
                .background(Color.panelCharcoalSurface)
        }
    }
}

// MARK: - Keyboard Shortcut Row

@available(macOS 14.0, *)
struct KeyboardShortcutRow: View {

    let keys: String
    let action: String

    var body: some View {
        HStack {
            // Keys
            Text(keys)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(.panelTextPrimary)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .background {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.panelCharcoalSurface)
                }

            Spacer()

            // Action
            Text(action)
                .font(.bodySmall)
                .foregroundColor(.panelTextSecondary)
        }
    }
}

// MARK: - Support Link Row

@available(macOS 14.0, *)
struct SupportLinkRow: View {

    let icon: String
    let title: String
    let subtitle: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.ms) {
                // Icon
                Image(systemName: icon)
                    .font(.system(size: 16))
                    .foregroundColor(.panelTextSecondary)
                    .frame(width: 24)

                // Text
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.bodyMedium)
                        .foregroundColor(.panelTextPrimary)

                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.panelTextMuted)
                }

                Spacer()

                // Arrow
                Image(systemName: "arrow.right")
                    .font(.caption)
                    .foregroundColor(.panelTextMuted)
                    .opacity(isHovered ? 1 : 0.5)
            }
            .padding(.vertical, Spacing.xs)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Preview

@available(macOS 14.0, *)
#Preview {
    HelpView()
        .frame(width: 620, height: 700)
}
