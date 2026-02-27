// StyleProfileView.swift
// DEPRECATED: Style display is now inlined in MenuBarPanel.swift (single-pane layout).
// This file is kept for reference but no longer used.

import SwiftUI

struct StyleProfileView: View {
    @ObservedObject var styleEngine: StyleEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Your Writing Style")
                    .font(.title2)
                    .fontWeight(.semibold)

                Spacer()

                Text("\(styleEngine.exampleCount) examples")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.purple.opacity(0.1))
                    .cornerRadius(4)
            }

            if styleEngine.exampleCount == 0 {
                VStack(spacing: 8) {
                    Text("No examples yet")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Draft a message and hit Copy or Paste — each accepted message teaches Draft your style.")
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    Text(styleEngine.styleFileContents)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(20)
    }
}
