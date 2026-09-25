import AppKit
import SwiftUI

/// Intro page 2's autocomplete demo, drawn in SwiftUI (not a video) so it
/// stays sharp in dark mode and costs nothing to download. It plays
/// `WritingDemoScript.allFrames` on a loop while it's on screen, and holds
/// still on `WritingDemoScript.stillFrame` when Reduce Motion is on.
struct WritingDemoView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var frameIndex = 0
    @State private var host = WindowHost()

    /// The hosting window, held weakly outside SwiftUI's state diffing.
    private final class WindowHost {
        weak var window: NSWindow?
    }

    private var frame: WritingDemoScript.Frame {
        reduceMotion ? WritingDemoScript.stillFrame : WritingDemoScript.allFrames[frameIndex]
    }

    private var scene: WritingDemoScript.Scene {
        WritingDemoScript.scenes[frame.sceneIndex]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: scene.symbolName)
                    .font(.system(size: 11, weight: .semibold))
                Text(scene.app)
                    .font(LibraryTokens.meta.weight(.semibold))
                Spacer(minLength: 0)
            }
            .foregroundStyle(LibraryTokens.ink2)

            field

            HStack(spacing: 8) {
                WritingKeyCap(key: "Tab", isPressed: frame.tabPressed)
                    .animation(.easeOut(duration: 0.1), value: frame.tabPressed)
                Spacer(minLength: 0)
                if let saved = frame.keystrokesSaved {
                    Label(WritingDemoScript.keystrokesSavedText(saved), systemImage: "checkmark.circle.fill")
                        .font(LibraryTokens.meta.weight(.semibold))
                        .foregroundStyle(LibraryTokens.accent)
                        .transition(.opacity)
                }
            }
            .frame(minHeight: 22)
            .animation(.easeInOut(duration: 0.25), value: frame.keystrokesSaved)
        }
        .padding(16)
        .frame(maxWidth: 560, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised, style: .continuous)
                .fill(LibraryTokens.raisedFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: LibraryTokens.radiusRaised, style: .continuous)
                .stroke(LibraryTokens.raisedStroke, lineWidth: 1)
        )
        .background(WritingWindowReader { [host] window in host.window = window })
        .task(id: reduceMotion) { await play() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Autocomplete demo: \(scene.typed)\(scene.suggestion)"))
        .accessibilityIdentifier("transcripted.settings.writing.intro.demo")
    }

    /// The field: typed text, then the suggestion underlined in grey. Two
    /// layers with the same text so the suggestion can fade in while the
    /// wrapping stays put.
    private var field: some View {
        ZStack(alignment: .topLeading) {
            Text("\(Text(verbatim: frame.fieldText))\(Text(verbatim: frame.ghostText).foregroundStyle(Color.clear))")
            Text("\(Text(verbatim: frame.fieldText).foregroundStyle(Color.clear))\(Text(verbatim: frame.ghostText).foregroundStyle(LibraryTokens.ink2).underline())")
                .opacity(ghostOpacity)
                .animation(.easeIn(duration: 0.35), value: ghostOpacity)
        }
        .font(.system(size: 14))
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var ghostOpacity: Double {
        frame.ghostText.isEmpty ? 0 : 1
    }

    private func play() async {
        guard !reduceMotion else { return }
        let frames = WritingDemoScript.allFrames
        while !Task.isCancelled {
            // A closed or covered Settings window keeps this view alive;
            // don't animate what nobody can see.
            if let window = host.window, !window.writingIsShowingContent {
                try? await Task.sleep(for: .seconds(1))
                continue
            }
            let duration = frames[frameIndex].duration
            try? await Task.sleep(for: .milliseconds(Int(duration * 1_000)))
            guard !Task.isCancelled else { return }
            frameIndex = (frameIndex + 1) % frames.count
        }
    }
}
