// AgentTab.swift → AgentSection
// Agent section for the single-pane menubar panel.
// Shows insight cards (pending only) + chat thread + input bar.
//
// Chat uses StreamingChatEngine (native Swift streaming) for direct Anthropic API
// access. Background analysis uses AnalysisEngine (native Swift, DispatchSource).

import SwiftUI

struct AgentSection: View {
    @ObservedObject var orchestrator: AnalysisEngine
    @ObservedObject var chatEngine: StreamingChatEngine
    var auth: AuthCredential?

    @State private var chatInput = ""
    @State private var expandedTools: Set<String> = []
    @FocusState private var isChatInputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            agentHeader

            // Pending insight cards (inline, no DisclosureGroup)
            let pending = orchestrator.insights.filter { $0.status == .pending }
            if !pending.isEmpty {
                ForEach(pending) { card in
                    insightCardView(card)
                }
            }

            chatSection
        }
        .transaction { $0.animation = nil }
    }

    // MARK: - Header

    private var agentHeader: some View {
        HStack {
            Text("Agent")
                .font(.headline)

            Spacer()

            HStack(spacing: 6) {
                if chatEngine.isResponding {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 10, height: 10)
                    Text("Thinking...")
                        .font(.caption)
                        .foregroundColor(MenuTokens.textSecondary)
                } else if orchestrator.isAnalyzing {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 10, height: 10)
                    Text("Analyzing...")
                        .font(.caption)
                        .foregroundColor(MenuTokens.textSecondary)
                } else {
                    Circle()
                        .fill(orchestrator.isConnected ? MenuTokens.statusGreen : MenuTokens.statusOrange)
                        .frame(width: MenuTokens.statusDotSize, height: MenuTokens.statusDotSize)
                    Text(orchestrator.agentStatus)
                        .font(.caption)
                        .foregroundColor(MenuTokens.textSecondary)
                }
            }
        }
    }

    // MARK: - Simplified Insight Card

    @ViewBuilder
    private func insightCardView(_ card: InsightCard) -> some View {
        // Capture card ID (value type) instead of the full card object to prevent
        // stale closure captures when the insights array mutates during button dispatch.
        let cardId = card.id
        VStack(alignment: .leading, spacing: 8) {
            Text(card.promptKeyLabel)
                .font(.caption)
                .foregroundColor(MenuTokens.textSecondary)

            Text(card.changeDescription)
                .font(.callout)

            HStack(spacing: 10) {
                Spacer()

                Button("Skip") {
                    guard let live = orchestrator.insights.first(where: { $0.id == cardId }) else { return }
                    orchestrator.skip(live)
                }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .foregroundColor(MenuTokens.textSecondary)

                Button(action: {
                    guard let live = orchestrator.insights.first(where: { $0.id == cardId }) else { return }
                    orchestrator.apply(live)
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "checkmark")
                        Text("Apply")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(MenuTokens.statusGreen)
                .controlSize(.small)
            }
        }
        .padding(MenuTokens.cardPadding)
        .background(MenuTokens.cardBackground)
        .cornerRadius(MenuTokens.cardCornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: MenuTokens.cardCornerRadius)
                .stroke(MenuTokens.cardBorder, lineWidth: 1)
        )
    }

    // MARK: - Chat

    private var chatSection: some View {
        VStack(spacing: 8) {
            if !chatEngine.messages.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(chatEngine.messages) { msg in
                                chatBubble(msg)
                                    .id(msg.id)
                            }

                            if chatEngine.isResponding,
                               !chatEngine.messages.contains(where: { $0.isStreaming && $0.role == .assistant }) {
                                typingIndicator
                                    .id("typing")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 160)
                    .onChange(of: chatEngine.messages.count) { _, _ in
                        if let last = chatEngine.messages.last {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }

            chatInputBar
        }
        .animation(nil, value: chatEngine.messages.count)
        .animation(nil, value: chatEngine.isResponding)
    }

    private var typingIndicator: some View {
        HStack(spacing: 4) {
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 10, height: 10)
            Text("Thinking...")
                .font(.caption)
                .foregroundColor(MenuTokens.textSecondary)
        }
        .padding(.leading, 4)
    }

    private var chatInputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask the agent...", text: $chatInput)
                .textFieldStyle(.roundedBorder)
                .focused($isChatInputFocused)
                .onSubmit { sendChat() }
                .disabled(chatEngine.isResponding || auth == nil)

            Button(action: { sendChat() }) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(chatInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      || chatEngine.isResponding
                      || auth == nil)
            .buttonStyle(.plain)
            .foregroundColor(MenuTokens.sendButton)

            if !chatEngine.messages.isEmpty {
                Button(action: { chatEngine.clear() }) {
                    Image(systemName: "trash")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(MenuTokens.textSecondary)
            }
        }
    }

    // MARK: - Chat Bubble

    @ViewBuilder
    private func chatBubble(_ message: ChatMessage) -> some View {
        if message.role == .tool {
            toolIndicator(message)
        } else {
            HStack {
                if message.role == .user { Spacer(minLength: 60) }

                Text(message.text)
                    .font(.callout)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(
                        message.role == .user
                            ? MenuTokens.userBubbleBg
                            : MenuTokens.assistantBubbleBg
                    )
                    .cornerRadius(MenuTokens.bubbleCornerRadius)
                    .overlay(
                        RoundedRectangle(cornerRadius: MenuTokens.bubbleCornerRadius)
                            .stroke(MenuTokens.cardBorder, lineWidth: 0.5)
                    )

                if message.role == .assistant { Spacer(minLength: 60) }
            }
        }
    }

    // MARK: - Tool Indicator

    @ViewBuilder
    private func toolIndicator(_ message: ChatMessage) -> some View {
        let isExpanded = expandedTools.contains(message.id)

        VStack(alignment: .leading, spacing: 2) {
            Button(action: {
                if message.toolDetail != nil {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if expandedTools.contains(message.id) {
                            expandedTools.remove(message.id)
                        } else {
                            expandedTools.insert(message.id)
                        }
                    }
                }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.caption2)
                        .foregroundColor(MenuTokens.textSecondary)
                    Text(message.text)
                        .font(.caption)
                        .foregroundColor(MenuTokens.textSecondary)
                    if message.toolDetail != nil {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8))
                            .foregroundColor(MenuTokens.textSecondary.opacity(0.6))
                    }
                }
            }
            .buttonStyle(.plain)

            if isExpanded, let detail = message.toolDetail {
                Text(detail)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(MenuTokens.textSecondary)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(MenuTokens.cardBackground)
                    .cornerRadius(4)
            }
        }
        .padding(.leading, 4)
        .padding(.vertical, 1)
    }

    // MARK: - Chat Actions

    private func sendChat() {
        let text = chatInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let auth = auth else { return }
        chatInput = ""
        Task {
            await chatEngine.send(text: text, auth: auth)
        }
    }
}
