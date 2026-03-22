// TrainingToastView.swift
// Brief floating toast shown after accepting an edited draft.
// Displays training feedback like "Draft learned: you shortened the greeting"

import SwiftUI

struct TrainingToastView: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "brain.fill")
                .font(.system(size: 12))
                .foregroundColor(OverlayTokens.accentGreen)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(OverlayTokens.textPrimary)
                .lineLimit(2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OverlayTokens.panelBg)
    }
}
