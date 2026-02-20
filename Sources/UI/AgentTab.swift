// AgentTab.swift
// Third tab showing insight cards + free-form chat with the native analysis engine.
//
// Chat uses StreamingChatEngine (native Swift streaming) for direct Anthropic API
// access — no Python subprocess, no SSE relay hop, no cold start.
//
// Background analysis uses AnalysisEngine (native Swift, DispatchSource file watching)
// which replaces the Python orchestrator entirely. Insight cards from analysis
// appear in the Suggestions section the same as before.
//
// Layout: header → collapsible suggestions → chat thread → input bar.

import SwiftUI

struct AgentTab: View {
    @ObservedObject var orchestrator: AnalysisEngine
    @ObservedObject var chatEngine: StreamingChatEngine
    var auth: AuthCredential?

    @State private var chatInput = ""
    @State private var isInsightsExpanded = true
    @State private var expandedTools: Set<String> = []
    @FocusState private var isChatInputFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerView
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 12)

            // Insight cards section (collapsible, only if cards exist)
            let allInsights = orchestrator.insights
            if !allInsights.isEmpty {
                insightsSection(insights: allInsights)
                    .padding(.horizontal, 20)

                Divider()
                    .padding(.vertical, 8)
            }

            // Chat section (always visible)
            chatSection
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
        .transaction { $0.animation = nil }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("Agent")
                .font(.title2)
                .fontWeight(.semibold)

            Spacer()

            // Status indicators
            HStack(spacing: 12) {
                // Chat status
                if chatEngine.isResponding {
                    HStack(spacing: 4) {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 10, height: 10)
                        Text("Thinking...")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                // Background analysis status
                HStack(spacing: 6) {
                    if orchestrator.isAnalyzing {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 10, height: 10)
                    } else {
                        Circle()
                            .fill(orchestrator.isConnected ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                    }
                    Text(orchestrator.agentStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Suggestions (Collapsible)

    private func insightsSection(insights: [InsightCard]) -> some View {
        DisclosureGroup(isExpanded: $isInsightsExpanded) {
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(insights.reversed()) { card in
                        insightCardView(card)
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxHeight: 200)
        } label: {
            HStack(spacing: 4) {
                Text("Suggestions")
                    .font(.headline)
                Text("(\(insights.count))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Chat

    private var chatSection: some View {
        VStack(spacing: 8) {
            ZStack {
                if chatEngine.messages.isEmpty {
                    chatEmptyState
                }

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(chatEngine.messages) { msg in
                                chatBubble(msg)
                                    .id(msg.id)
                            }

                            // Typing indicator while waiting for first token
                            if chatEngine.isResponding,
                               !chatEngine.messages.contains(where: { $0.isStreaming && $0.role == .assistant }) {
                                typingIndicator
                                    .id("typing")
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .opacity(chatEngine.messages.isEmpty ? 0 : 1)
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

    private var chatEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 28))
                .foregroundColor(.secondary.opacity(0.5))
            Text("Ask about your drafts, style, or prompts")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 40)
    }

    private var typingIndicator: some View {
        HStack(spacing: 4) {
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 10, height: 10)
            Text("Thinking...")
                .font(.caption)
                .foregroundColor(.secondary)
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
            .foregroundColor(.purple)

            if !chatEngine.messages.isEmpty {
                Button(action: { chatEngine.clear() }) {
                    Image(systemName: "trash")
                        .font(.body)
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
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

                VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 2) {
                    messageText(message.text)
                        .font(.body)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            message.role == .user
                                ? Color.purple.opacity(0.15)
                                : Color.secondary.opacity(0.08)
                        )
                        .cornerRadius(12)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(
                                    message.role == .user
                                        ? Color.purple.opacity(0.2)
                                        : Color.gray.opacity(0.2),
                                    lineWidth: 1
                                )
                        )

                    if message.isStreaming {
                        ProgressView()
                            .scaleEffect(0.4)
                            .frame(width: 8, height: 8)
                    }
                }
                .frame(maxWidth: 400, alignment: message.role == .user ? .trailing : .leading)

                if message.role == .assistant { Spacer(minLength: 60) }
            }
        }
    }

    private func messageText(_ text: String) -> some View {
        Text(text)
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
                        .foregroundColor(.secondary)
                    Text(message.text)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if message.toolDetail != nil {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary.opacity(0.6))
                    }
                }
            }
            .buttonStyle(.plain)

            if isExpanded, let detail = message.toolDetail {
                Text(detail)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.secondary)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.gray.opacity(0.1))
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

    // MARK: - Insight Card

    @ViewBuilder
    private func insightCardView(_ card: InsightCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(card.promptKeyLabel)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.purple.opacity(0.15))
                    .cornerRadius(4)

                Spacer()

                switch card.status {
                case .applied:
                    Label("Applied", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundColor(.green)
                case .skipped:
                    Label("Skipped", systemImage: "xmark.circle")
                        .font(.caption)
                        .foregroundColor(.secondary)
                case .pending:
                    EmptyView()
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("SAW")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.orange)
                Text(card.saw)
                    .font(.caption)
                    .foregroundColor(.primary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("WHY")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.blue)
                Text(card.why)
                    .font(.caption)
                    .foregroundColor(.primary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("CHANGE")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.purple)
                Text(card.changeDescription)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.primary)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.purple.opacity(0.05))
                    .cornerRadius(6)
            }

            if card.status == .pending {
                HStack(spacing: 12) {
                    Button(action: { orchestrator.apply(card) }) {
                        HStack(spacing: 4) {
                            Image(systemName: "checkmark")
                            Text("Apply")
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 14)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .controlSize(.small)

                    Button(action: { orchestrator.skip(card) }) {
                        HStack(spacing: 4) {
                            Image(systemName: "forward")
                            Text("Skip")
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 14)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    card.status == .applied ? Color.green.opacity(0.3) :
                    card.status == .skipped ? Color.gray.opacity(0.2) :
                    Color.purple.opacity(0.2),
                    lineWidth: 1
                )
        )
        .opacity(card.status == .skipped ? 0.6 : 1.0)
    }
}
