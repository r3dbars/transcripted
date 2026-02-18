// AgentTab.swift
// Third tab showing streamed insight cards from the orchestrator agent.
//
// Cards arrive via SSE as the agent analyzes feedback patterns. Each card
// shows SAW (evidence), WHY (reasoning), CHANGE (proposed edit) with
// Apply/Skip buttons. Newest cards appear at the top.

import SwiftUI

struct AgentTab: View {
    @ObservedObject var orchestrator: OrchestratorBridge

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerView

            if orchestrator.insights.isEmpty {
                emptyStateView
            } else {
                cardListView
            }
        }
        .padding(20)
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Text("Agent")
                .font(.title2)
                .fontWeight(.semibold)

            Spacer()

            // Status indicator
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

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "brain.head.profile")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("Watching for feedback...")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("The agent analyzes your accepted drafts and suggests\nprompt improvements to match your writing style.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Card List

    private var cardListView: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                ForEach(orchestrator.insights.reversed()) { card in
                    insightCardView(card)
                }
            }
        }
    }

    // MARK: - Single Card

    @ViewBuilder
    private func insightCardView(_ card: InsightCard) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Card header — prompt key label + status badge
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

            // SAW section
            VStack(alignment: .leading, spacing: 4) {
                Text("SAW")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.orange)
                Text(card.saw)
                    .font(.caption)
                    .foregroundColor(.primary)
            }

            // WHY section
            VStack(alignment: .leading, spacing: 4) {
                Text("WHY")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundColor(.blue)
                Text(card.why)
                    .font(.caption)
                    .foregroundColor(.primary)
            }

            // CHANGE section — diff view
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

            // Action buttons (only for pending cards)
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
        .background(Color(nsColor: .textBackgroundColor))
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
