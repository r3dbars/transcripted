import SwiftUI
import AppKit

// MARK: - Window shell

struct OnboardingWindowShell<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let canGoBack: Bool
    let primaryTitle: String
    let primaryDisabled: Bool
    let secondaryTitle: String?
    let onBack: () -> Void
    let onNext: () -> Void
    let onSecondary: () -> Void
    let content: Content

    init(
        canGoBack: Bool,
        primaryTitle: String,
        primaryDisabled: Bool,
        secondaryTitle: String?,
        onBack: @escaping () -> Void,
        onNext: @escaping () -> Void,
        onSecondary: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.canGoBack = canGoBack
        self.primaryTitle = primaryTitle
        self.primaryDisabled = primaryDisabled
        self.secondaryTitle = secondaryTitle
        self.onBack = onBack
        self.onNext = onNext
        self.onSecondary = onSecondary
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                content
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .trailing)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            NavBar(
                canGoBack: canGoBack,
                primaryTitle: primaryTitle,
                primaryDisabled: primaryDisabled,
                secondaryTitle: secondaryTitle,
                onBack: onBack,
                onNext: onNext,
                onSecondary: onSecondary
            )
        }
        .background(LibraryTokens.contentBackground)
    }
}

struct NavBar: View {
    let canGoBack: Bool
    let primaryTitle: String
    let primaryDisabled: Bool
    let secondaryTitle: String?
    let onBack: () -> Void
    let onNext: () -> Void
    let onSecondary: () -> Void

    var body: some View {
        HStack {
            Button {
                onBack()
            } label: {
                Text("Back")
                    .font(LibraryTokens.meta)
                    .foregroundStyle(LibraryTokens.ink2)
                    .frame(minWidth: LibraryTokens.minimumHitTarget, minHeight: LibraryTokens.minimumHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(canGoBack ? 1 : 0)
            .disabled(!canGoBack)
            .accessibilityIdentifier("transcripted.onboarding.nav.back")

            Spacer()

            if let secondaryTitle {
                Button {
                    onSecondary()
                } label: {
                    Text(secondaryTitle)
                        .font(LibraryTokens.meta)
                        .foregroundStyle(LibraryTokens.ink2)
                        .padding(.horizontal, 12)
                        .frame(minHeight: LibraryTokens.minimumHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("transcripted.onboarding.nav.secondary")
            }

            Button {
                onNext()
            } label: {
                Text(primaryTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 22)
                    .frame(minHeight: LibraryTokens.minimumHitTarget)
                    .background(
                        RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous)
                            .fill(primaryDisabled ? LibraryTokens.ink3 : LibraryTokens.accent)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: LibraryTokens.radiusControl, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(primaryDisabled)
            .accessibilityIdentifier("transcripted.onboarding.nav.primary")
        }
        .padding(.horizontal, 32)
        .frame(height: 76)
        .overlay(Rectangle().fill(LibraryTokens.hairline).frame(height: 1), alignment: .top)
    }
}

