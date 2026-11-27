// NotchIslandDropView+Meeting.swift
// The recording drop-down, in one of two quiet shapes:
// - Live meeting words on: the rolling transcript straight on the black
//   island (no card, soft top fade), then a footer with round Copy and Mute
//   icons, an amber pill only when something is wrong, and the translucent Stop.
// - Off (the default): one compact strip, "● You · ● Others" and the amber
//   pill on the left, Mute and Stop on the right. The wing already says it's
//   recording and draws the levels, so there's no title or second waveform.

import AppKit

extension NotchIslandDropView {
    func buildMeetingControls(showsTranscript: Bool, live: NotchIslandLiveValues) {
        let specs = NotchIslandDropButtons.buttons(for: drop, callSecondsLeft: live.callSecondsLeft)
        let (leading, trailing) = buttonViews(specs, targetIcon: { nil })
        let warning = NotchIslandDropButtons.meetingWarning(for: drop).map { warningPill($0) }
        if showsTranscript, let liveTranscriptView {
            liveTranscriptView.removeFromSuperview()
            stack.addArrangedSubview(liveTranscriptView) // not add(): it pins its own size
            readableText.append(liveTranscriptView)
            DispatchQueue.main.async { [weak liveTranscriptView] in liveTranscriptView?.scrollToNewest() }
            add(buttonRow(leading: leading + [warning].compactMap { $0 }, trailing: trailing))
        } else {
            var micMuted = false
            if case .meetingControls(_, _, _, _, .meetingMicUnmute?) = drop { micMuted = true }
            add(buttonRow(leading: [sidesLabel(micMuted: micMuted)] + leading + [warning].compactMap { $0 }, trailing: trailing))
        }
    }

    /// Copy, which shows a checkmark for a beat.
    func copyTranscriptButton(_ spec: NotchIslandDropButton) -> NotchIslandButton {
        let button = self.button(spec.title, Self.style(for: spec), spec.action, symbol: spec.symbol,
                                 accessibilityLabel: spec.accessibilityLabel)
        let symbol = spec.symbol ?? "doc.on.doc"
        let label = spec.accessibilityLabel ?? spec.title
        button.onPress = { [weak self, weak button] in
            self?.onAction?(.meetingCopyTranscript)
            button?.replaceSymbol("checkmark")
            button?.setAccessibilityLabel("Copied")
            Task { @MainActor [weak button] in
                try? await Task.sleep(for: .seconds(1.4))
                button?.replaceSymbol(symbol)
                button?.setAccessibilityLabel(label)
            }
        }
        return button
    }

    /// "● You · ● Others": who the recording hears, each dot lit by its
    /// side's level. A muted mic greys your dot.
    private func sidesLabel(micMuted: Bool) -> NSView {
        let you = Self.dot(micMuted ? NSColor(white: 1, alpha: 0.3) : NotchIslandPalette.accent)
        let others = Self.dot(NSColor(white: 1, alpha: 0.78))
        meetingDots = (you, others)
        func word(_ text: String) -> NSTextField {
            NotchIslandPalette.label(text, font: TextRole.meta.nsFont(weight: .medium), color: NotchIslandPalette.secondaryText)
        }
        let separator = NotchIslandPalette.label("·", font: TextRole.meta.nsFont(weight: .regular),
                                                 color: NSColor(white: 1, alpha: 0.28))
        let views: [NSView] = [you, word("You"), separator, others, word(NotchIslandMeetingCopy.otherSideLane)]
        let strip = self.row(views)
        strip.spacing = 6
        strip.setCustomSpacing(10, after: views[1])
        strip.setCustomSpacing(10, after: separator)
        strip.setAccessibilityElement(true)
        strip.setAccessibilityRole(.staticText)
        strip.setAccessibilityLabel(micMuted
            ? "Recording others, \(NotchIslandMeetingCopy.micMuted.lowercased())"
            : "Recording: \(NotchIslandMeetingCopy.bothSides)")
        return strip
    }

    private static func dot(_ color: NSColor) -> NSView {
        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
        ])
        dot.alphaValue = restingDotAlpha
        return dot
    }

    private static let restingDotAlpha: CGFloat = 0.55

    /// Brightens a strip dot with its side's level (0...1).
    static func glow(_ dot: NSView, level: Float) {
        let clamped = CGFloat(min(1, max(0, level.isFinite ? level : 0)))
        dot.alphaValue = restingDotAlpha + (1 - restingDotAlpha) * min(1, clamped * 2.5)
    }

    /// The amber pill: a button when it can fix the problem ("Call audio is
    /// off" turns it on), else a quiet label.
    private func warningPill(_ warning: NotchIslandMeetingWarning) -> NSView {
        if let action = warning.action {
            let pill = NotchIslandButton(title: warning.text, style: .warning, height: 24, fontSize: 11.5)
            pill.onPress = { [weak self] in self?.onAction?(action) }
            pill.toolTip = warning.toolTip
            if let tip = warning.toolTip { pill.setAccessibilityLabel("\(warning.text). \(tip)") }
            pill.setContentHuggingPriority(.required, for: .horizontal)
            pill.setContentCompressionResistancePriority(.required, for: .horizontal)
            return pill
        }
        let label = NotchIslandPalette.label(warning.text, font: .systemFont(ofSize: 11.5, weight: .semibold),
                                             color: NotchIslandPalette.warning)
        label.translatesAutoresizingMaskIntoConstraints = false
        let pill = NSView()
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NotchIslandPalette.warning.withAlphaComponent(0.18).cgColor
        pill.layer?.cornerRadius = 12
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)
        NSLayoutConstraint.activate([
            pill.heightAnchor.constraint(equalToConstant: 24),
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -9),
            label.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
        ])
        pill.setContentHuggingPriority(.required, for: .horizontal)
        pill.setContentCompressionResistancePriority(.required, for: .horizontal)
        pill.setAccessibilityElement(true)
        pill.setAccessibilityRole(.staticText)
        pill.setAccessibilityLabel(warning.text)
        return pill
    }
}
