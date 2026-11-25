import SwiftUI

/// The pitch at the top of setup screen 1, first setup only: Writing's small
/// amber mark, the headline, one line of body, the autocomplete demo and its
/// keys. It asks for nothing; the two questions follow it on the same screen
/// (docs/writing-plan.md, "Setup, screen 1 of 2").
struct WritingIntroView: View {
    typealias Copy = WritingSetupPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                Text(Copy.Intro.smallTitle)
                    .textRole(.label)
                    .foregroundStyle(LibraryTokens.writingStream)
                Text(Copy.Intro.headline)
                    .font(LibraryTokens.title)
                    .fixedSize(horizontal: false, vertical: true)
                Text(Copy.Intro.body)
                    .font(LibraryTokens.body)
                    .foregroundStyle(LibraryTokens.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            WritingDemoView()

            WritingFlowLayout(spacing: 16, lineSpacing: 6) {
                ForEach(Copy.Intro.keyHints, id: \.text) { hint in
                    HStack(spacing: 6) {
                        if let key = hint.key {
                            WritingKeyCap(key: key)
                        }
                        Text(hint.text)
                            .font(LibraryTokens.meta)
                            .foregroundStyle(LibraryTokens.ink2)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("transcripted.settings.writing.intro.key-hints")
        }
    }
}

/// "Stays on your Mac.": the privacy point under setup's questions.
struct WritingPrivacyPoint: View {
    let point: WritingSetupPresentation.Point

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: point.symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(LibraryTokens.ink3)
                .frame(width: 16)
                .padding(.top, 1)
            Text("\(Text(point.title).fontWeight(.medium).foregroundStyle(LibraryTokens.ink2)) \(Text(point.line).foregroundStyle(LibraryTokens.ink3))")
                .font(LibraryTokens.meta)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("transcripted.settings.writing.setup.privacy")
    }
}
