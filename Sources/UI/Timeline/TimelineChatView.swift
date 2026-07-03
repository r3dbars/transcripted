import SwiftUI

struct TimelineChatView: View {
    var messages: [TimelineChatMessage]
    var privacyMode: TimelineChatPrivacyMode
    var isThinking: Bool
    var onSubmit: (String) -> Void
    var onAcceptCloudNotice: (() -> Void)?

    @State private var draft = ""

    init(
        messages: [TimelineChatMessage] = [],
        privacyMode: TimelineChatPrivacyMode = .localOnly,
        isThinking: Bool = false,
        onSubmit: @escaping (String) -> Void = { _ in },
        onAcceptCloudNotice: (() -> Void)? = nil
    ) {
        self.messages = messages
        self.privacyMode = privacyMode
        self.isThinking = isThinking
        self.onSubmit = onSubmit
        self.onAcceptCloudNotice = onAcceptCloudNotice
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if shouldShowCloudNotice {
                cloudNotice
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if messages.isEmpty {
                        emptyState
                    } else {
                        ForEach(messages) { message in
                            messageRow(message)
                        }
                    }
                    if isThinking {
                        statusRow("Thinking...")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            composer
        }
        .padding(14)
        .frame(minWidth: 320, minHeight: 360)
        .accessibilityIdentifier("transcripted.timeline.chat")
    }

    private var header: some View {
        HStack {
            Label("Chat", systemImage: "bubble.left.and.bubble.right")
                .font(.headline)
            Spacer()
            Text(privacyLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        Text("Ask what happened today, what changed, or what needs a follow-up.")
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 24)
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Ask about this day", text: $draft)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            Button {
                submit()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
            }
            .buttonStyle(.plain)
            .font(.title3)
            .help("Send")
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var shouldShowCloudNotice: Bool {
        if case .cloudProvider(_, false) = privacyMode {
            return true
        }
        return false
    }

    private var cloudNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ChatPromptBuilder.cloudNoticeText(providerName: cloudProviderName))
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Allow for this provider") {
                onAcceptCloudNotice?()
            }
            .buttonStyle(.bordered)
        }
        .padding(10)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var privacyLabel: String {
        switch privacyMode {
        case .localOnly:
            return "Local"
        case .cloudProvider(let name, let accepted):
            return accepted ? name : "\(name) needs notice"
        }
    }

    private var cloudProviderName: String {
        if case .cloudProvider(let name, _) = privacyMode {
            return name
        }
        return "the configured provider"
    }

    private func messageRow(_ message: TimelineChatMessage) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message.role.rawValue.capitalized)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(message.content)
                .font(.callout)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(message.role == .user ? Color.accentColor.opacity(0.12) : Color.secondary.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func statusRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        onSubmit(text)
    }
}
