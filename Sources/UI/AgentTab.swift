// AgentTab.swift → AgentSection
// Agent section for the single-pane menubar panel.
// Shows insight cards (pending only) from AnalysisEngine.
// Chat removed — low value relative to complexity for local inference.

import SwiftUI

struct AgentSection: View {
    @ObservedObject var orchestrator: AnalysisEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            agentHeader

            // Pending insight cards
            let pending = orchestrator.insights.filter { $0.status == .pending }
            if !pending.isEmpty {
                ForEach(pending) { card in
                    insightCardView(card)
                }
            }
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
                if orchestrator.isAnalyzing {
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
}
