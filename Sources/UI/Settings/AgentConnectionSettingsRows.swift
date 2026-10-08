import SwiftUI

/// The one divider in this page: a hairline on the bottom edge of a row.
struct LibraryRowDivider: ViewModifier {
    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            Rectangle()
                .fill(LibraryTokens.hairline)
                .frame(height: 1)
        }
    }
}

extension View {
    func libraryRowDivider() -> some View {
        modifier(LibraryRowDivider())
    }
}

struct AgentSetupDetailsDisclosure<Content: View>: View {
    @Binding var isExpanded: Bool
    // Stored as a closure so collapsed renders never build the content (its
    // folder details stat the filesystem on every evaluation).
    let content: () -> Content

    init(
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self._isExpanded = isExpanded
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.18)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: 16, height: 16)

                    Text("Show setup details")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Spacer(minLength: 12)

                    Text(isExpanded ? "Hide" : "Show")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(SettingsHoverButtonStyle(
                tone: .neutral,
                cornerRadius: 8,
                normalFill: Color.primary.opacity(0.018),
                normalStroke: Color.primary.opacity(0.07),
                hoverFill: Color.primary.opacity(0.04),
                pressedFill: Color.primary.opacity(0.06),
                hoverStroke: Color.primary.opacity(0.12)
            ))
            .accessibilityLabel(Text("Show setup details"))
            .accessibilityValue(Text(isExpanded ? "Expanded" : "Collapsed"))
            .accessibilityHint(Text(isExpanded ? "Hide advanced agent setup details" : "Show advanced agent setup details"))

            if isExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    content()
                }
                .padding(.top, 14)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

struct AgentFolderRow: View {
    let name: String
    let detail: String
    let path: String
    let isAvailable: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(name)
                        .font(.subheadline.weight(.semibold))

                    if !isAvailable {
                        Text("Not written yet")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(LibraryTokens.attention)
                    }
                }

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(path)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 12)

            SettingsInlineActionButton(title: "Reveal", action: action)
                .disabled(!isAvailable)
                .help(isAvailable ? "" : "This location hasn't been created yet.")
        }
    }
}
