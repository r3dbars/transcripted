// VoicePrintSwiftUIView.swift
// VoicePrintView for SwiftUI hosts (Settings › Speakers). It wraps the AppKit
// view; nothing here hosts SwiftUI inside the island. Change `celebrateToken`
// to play the match animation up to `model.litRings`; any other model change
// redraws without animation. The diameter is fixed when the view is made.
// Leave VoicePrintView.cascadeOutset(diameter:) unclipped around it.

import SwiftUI

struct VoicePrintRepresentable: NSViewRepresentable {
    var model: VoicePrintView.Model
    var diameter: CGFloat = 42
    var isPlaying = false
    /// First name (or full name) for VoiceOver: "Play Priya's clip".
    var accessibilityName: String?
    /// Bump it (any new value) to celebrate up to `model.litRings`.
    var celebrateToken = 0
    /// Nil when there's no clip: the print is then only a picture
    /// (`VoicePrintView.isPlayable` false), and clicks fall through to the host.
    var onPlay: (() -> Void)?
    /// Set on the print itself, so automation finds the button. A SwiftUI
    /// `.accessibilityIdentifier` on the representable doesn't reach the NSView.
    var accessibilityIdentifier: String?

    final class Coordinator {
        var celebrateToken: Int

        init(celebrateToken: Int) {
            self.celebrateToken = celebrateToken
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(celebrateToken: celebrateToken)
    }

    func makeNSView(context: Context) -> VoicePrintView {
        let view = VoicePrintView(diameter: diameter, model: model)
        view.isPlaying = isPlaying
        view.accessibilityName = accessibilityName
        view.onPlay = onPlay
        view.isPlayable = onPlay != nil
        view.setAccessibilityIdentifier(accessibilityIdentifier)
        return view
    }

    func updateNSView(_ view: VoicePrintView, context: Context) {
        view.onPlay = onPlay
        view.isPlayable = onPlay != nil
        view.accessibilityName = accessibilityName
        view.setAccessibilityIdentifier(accessibilityIdentifier)
        if context.coordinator.celebrateToken != celebrateToken {
            context.coordinator.celebrateToken = celebrateToken
            // Everything but the ring count lands first, then the rings animate.
            var before = model
            before.litRings = view.model.litRings
            view.model = before
            view.celebrate(toLitRings: model.litRings)
        } else {
            view.model = model
        }
        view.isPlaying = isPlaying
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: VoicePrintView, context: Context) -> CGSize? {
        CGSize(width: diameter, height: diameter)
    }
}
