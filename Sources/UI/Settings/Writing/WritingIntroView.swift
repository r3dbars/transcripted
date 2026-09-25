import SwiftUI

/// The Writing tab until setup is done: two intro pages that ask for nothing
/// (docs/writing-plan.md, "Intro, page 1 of 2" and "page 2 of 2").
struct WritingIntroView: View {
    typealias Copy = WritingSetupPresentation

    let page: Int
    let onNext: () -> Void
    let onBack: () -> Void
    let onSetUp: () -> Void
    /// Leaves Writing off and clears the sidebar's "New" badge.
    let onNotNow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if page == 1 {
                pageOne
            } else {
                pageTwo
            }
            footer
        }
        .frame(maxWidth: 620, alignment: .leading)
    }

    // MARK: Page 1

    private var pageOne: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text(Copy.IntroPage1.smallTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LibraryTokens.accent)
                Text(Copy.IntroPage1.headline)
                    .font(LibraryTokens.title)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Copy.IntroPage1.body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                LibrarySectionLabel(text: Copy.IntroPage1.contextLabel)
                HStack(spacing: 8) {
                    ForEach(Copy.IntroPage1.contextItems, id: \.title) { item in
                        contextChip(item)
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("transcripted.settings.writing.intro.context")

            VStack(alignment: .leading, spacing: 14) {
                ForEach(Copy.IntroPage1.points, id: \.title) { point in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: point.symbolName)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(LibraryTokens.accent)
                            .frame(width: 20)
                            .padding(.top, 1)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(point.title)
                                .font(LibraryTokens.rowTitle.weight(.semibold))
                            Text(point.line)
                                .font(LibraryTokens.body)
                                .foregroundStyle(LibraryTokens.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func contextChip(_ item: WritingSetupPresentation.ContextItem) -> some View {
        HStack(spacing: 6) {
            Text(item.title)
                .font(LibraryTokens.rowTitle)
            Image(systemName: item.isAdded ? "plus" : "checkmark")
                .font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(item.isAdded ? LibraryTokens.accent : LibraryTokens.ink2)
        .padding(.horizontal, 12)
        .frame(minHeight: 32)
        .background(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusControl + 2, style: .continuous)
                .fill(item.isAdded ? LibraryTokens.accent.opacity(0.12) : LibraryTokens.raisedFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusControl + 2, style: .continuous)
                .stroke(item.isAdded ? LibraryTokens.accent.opacity(0.5) : LibraryTokens.raisedStroke, lineWidth: 1)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(item.isAdded ? "\(item.title), add" : "\(item.title), saved"))
    }

    // MARK: Page 2

    private var pageTwo: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text(Copy.IntroPage2.headline)
                    .font(LibraryTokens.title)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Copy.IntroPage2.body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            WritingDemoView()

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Copy.IntroPage2.keyHints, id: \.text) { hint in
                    HStack(spacing: 8) {
                        if let key = hint.key {
                            WritingKeyCap(key: key)
                        }
                        Text(hint.text)
                            .font(LibraryTokens.body)
                            .foregroundStyle(hint.key == nil ? LibraryTokens.ink2 : Color.primary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .accessibilityIdentifier("transcripted.settings.writing.intro.key-hints")
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            WritingPageDots(count: Copy.introPageCount, current: page)
            Spacer()
            Button(Copy.notNow, action: onNotNow)
                .buttonStyle(.plain)
                .font(LibraryTokens.meta)
                .foregroundStyle(LibraryTokens.ink2)
                .accessibilityIdentifier("transcripted.settings.writing.intro.not-now")
            if page == 1 {
                WritingPrimaryButton(
                    title: Copy.IntroPage1.next,
                    automationIdentifier: "transcripted.settings.writing.intro.next",
                    action: onNext
                )
            } else {
                WritingSecondaryButton(
                    title: Copy.IntroPage2.back,
                    automationIdentifier: "transcripted.settings.writing.intro.back",
                    action: onBack
                )
                WritingPrimaryButton(
                    title: Copy.IntroPage2.setUp,
                    automationIdentifier: "transcripted.settings.writing.intro.set-up",
                    action: onSetUp
                )
            }
        }
        .padding(.top, 4)
    }
}
