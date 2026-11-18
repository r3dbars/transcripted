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

/// The Agent page's Folders disclosure: where the Markdown files live, for
/// pointing an agent at them by hand.
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
                HStack(spacing: 6) {
                    Text("Folders")
                        .font(LibraryTokens.rowTitle)
                        .foregroundStyle(LibraryTokens.ink)
                    Image(systemName: "chevron.right")
                        .font(TextRole.small.font(weight: .semibold))
                        .foregroundStyle(LibraryTokens.ink3)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: LibraryTokens.minimumHitTarget, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Folders"))
            .accessibilityValue(Text(isExpanded ? "Expanded" : "Collapsed"))
            .accessibilityHint(Text(isExpanded ? "Hide the capture folders" : "Show the capture folders"))

            if isExpanded {
                VStack(alignment: .leading, spacing: 14) {
                    content()
                }
                .padding(.top, 6)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: 620, alignment: .leading)
    }
}

struct AgentFolderRow: View {
    let name: String
    let path: String
    let isAvailable: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(name)
                        .font(LibraryTokens.rowTitle)

                    if !isAvailable {
                        Text("Not written yet")
                            .font(LibraryTokens.small)
                            .foregroundStyle(LibraryTokens.ink3)
                    }
                }

                // Home-relative, so it reads as a place, not a file path dump.
                Text((path as NSString).abbreviatingWithTildeInPath)
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(path)
            }

            Spacer(minLength: 12)

            SettingsInlineActionButton(title: "Show in Finder", action: action)
                .disabled(!isAvailable)
                .help(isAvailable ? "" : "This folder hasn't been created yet.")
        }
    }
}
