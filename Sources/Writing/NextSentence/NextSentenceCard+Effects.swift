import AppKit
import CoreImage
import QuartzCore

/// The card's livelier moments: listening, a tone change, a swapped word, a fresh take, and a tinted
/// word showing where it came from.
extension NextSentenceCard {
    // MARK: Listening: a breathing orb, an aurora edge, and the text rippling with your voice

    func startListeningEffects() {
        listenTimer?.invalidate()
        orb.frame = pad.frame
        orb.isHidden = false
        let start = Date()
        let words = wordRanges()
        let colors = [NSColor(srgbRed: 1, green: 0.27, blue: 0.23, alpha: 1), NSColor(srgbRed: 1, green: 0.62, blue: 0.04, alpha: 1),
                      NSColor(srgbRed: 0.62, green: 0.42, blue: 1, alpha: 1)]
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let t = Date().timeIntervalSince(start)
                let level = Self.voiceLevel(at: t)
                self.orb.set(level: level)
                // The edge glows in a slow aurora of red, amber and violet that swells as you speak.
                let phase = (t * 0.35).truncatingRemainder(dividingBy: 1) * Double(colors.count)
                let from = colors[Int(phase) % colors.count], to = colors[(Int(phase) + 1) % colors.count]
                let color = from.blended(withFraction: CGFloat(phase - floor(phase)), of: to) ?? from
                if let layer = self.front.layer {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    layer.shadowColor = color.cgColor
                    layer.shadowOpacity = 0.75
                    layer.shadowRadius = 14 + 20 * level
                    layer.shadowOffset = .zero
                    layer.borderColor = color.withAlphaComponent(0.25 + 0.3 * level).cgColor
                    CATransaction.commit()
                }
                // The words ripple gently, like the sentence is listening too.
                guard NextSentenceMotion.reduced == false, !self.isEditing, let storage = self.textView.textStorage else { return }
                storage.beginEditing()
                for (index, range) in words.enumerated() where NSMaxRange(range) <= storage.length {
                    let lift = 1.5 + 2.4 * Double(level) * sin(t * 6 - Double(index) * 0.7)
                    storage.addAttribute(.baselineOffset, value: lift, range: range)
                }
                storage.endEditing()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        listenTimer = timer
    }

    func stopListeningEffects() {
        listenTimer?.invalidate()
        listenTimer = nil
        orb.isHidden = true
        if let storage = textView.textStorage, storage.length > 0 {
            storage.addAttribute(.baselineOffset, value: 1.5, range: NSRange(location: 0, length: storage.length))
        }
        front.layer?.borderColor = NSColor(white: 1, alpha: 0.08).cgColor
        glow()
    }

    /// A stand-in for the microphone's loudness: a lively, uneven rise and fall.
    static func voiceLevel(at t: Double) -> CGFloat {
        let v = abs(sin(t * 7.3) * sin(t * 2.1 + 1)) * 0.7 + 0.3 * abs(sin(t * 13))
        return CGFloat(min(1, v))
    }

    private func wordRanges() -> [NSRange] {
        let ns = textView.string as NSString
        var ranges: [NSRange] = []
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length), options: .byWords) { _, range, _, _ in ranges.append(range) }
        return ranges
    }

    // MARK: Tone change: words morph, and the new tone's glow washes around the edge

    /// After a different version replaced the text: shared words stay, new ones bloom in.
    func morph(from old: String) {
        let old = old.replacingOccurrences(of: " ▍", with: "")
        guard !old.isEmpty, !NextSentenceMotion.reduced else {
            return NextSentenceMotion.textChanged(textView.layer, direction: 0)
        }
        bloom.start(from: old, to: textView.string)
        applyBloom()
    }

    func applyBloom() {
        guard let storage = textView.textStorage, bloom.isActive else { bloomTimer?.invalidate(); bloomTimer = nil; return }
        bloom.apply(to: storage) { [content] location in
            content.marks.first { NSLocationInRange(location, $0.range) }?.color ?? NextSentenceCardStyle.body
        }
        guard bloomTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.applyBloom() } }
        RunLoop.main.add(timer, forMode: .common)
        bloomTimer = timer
    }

    func washTone(_ tone: Int) {
        let color = tone == 1 ? NSColor(white: 1, alpha: 0.55) : NextSentenceCardStyle.toneColors[tone]
        ring.wash(color: color)
    }

    // MARK: Swap a word: the old word melts into the new one

    func animateWordIn(_ range: NSRange, replacing old: String) {
        let text = textView.string as NSString
        guard NSMaxRange(range) <= text.length, !NextSentenceMotion.reduced, let layoutManager = textView.layoutManager else { return }
        let rect = textView.rect(for: range)
        let attributes = textView.textStorage?.attributes(at: range.location, effectiveRange: nil) ?? bodyAttributes
        func place(_ label: NSTextField, _ string: String) -> Bool {
            label.attributedStringValue = NSAttributedString(string: string, attributes: attributes)
            let size = label.intrinsicContentSize
            guard size.width <= max(rect.width, 40) + 60 else { return false }
            label.frame = NSRect(x: rect.minX - 2, y: rect.minY + (rect.height - size.height) / 2, width: size.width + 4, height: size.height)
            label.wantsLayer = true
            label.layerUsesCoreImageFilters = true
            let blur = CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 0])
            blur?.name = "blur"
            label.layer?.filters = blur.map { [$0] }
            label.isHidden = false
            return true
        }
        guard place(rollOverlay, text.substring(with: range)), place(meltOverlay, old) else { return }
        layoutManager.addTemporaryAttribute(.foregroundColor, value: NSColor.clear, forCharacterRange: range)
        func melt(_ label: NSTextField, blur: (Double, Double), opacity: (Float, Float)) {
            let radius = CABasicAnimation(keyPath: "filters.blur.inputRadius")
            radius.fromValue = blur.0
            radius.toValue = blur.1
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = opacity.0
            fade.toValue = opacity.1
            let group = CAAnimationGroup()
            group.animations = [radius, fade]
            group.duration = 0.26
            group.timingFunction = CAMediaTimingFunction(controlPoints: 0.4, 0, 0.2, 1)
            group.fillMode = .forwards
            group.isRemovedOnCompletion = false
            label.layer?.add(group, forKey: "melt")
        }
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                [self.rollOverlay, self.meltOverlay].forEach { $0.isHidden = true; $0.layer?.removeAllAnimations() }
                if NSMaxRange(range) <= (self.textView.string as NSString).length {
                    self.textView.layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
                }
            }
        }
        melt(meltOverlay, blur: (0, 6), opacity: (1, 0))
        melt(rollOverlay, blur: (6, 0), opacity: (0, 1))
        CATransaction.commit()
    }

    // MARK: Fresh take: the message bursts into particles, and the new one streams in

    func burstText() {
        guard !textView.string.isEmpty, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        var rects: [CGRect] = []
        layoutManager.enumerateLineFragments(forGlyphRange: layoutManager.glyphRange(for: container)) { _, used, _, _, _ in
            rects.append(self.textView.convert(used.offsetBy(dx: self.textView.textContainerOrigin.x, dy: self.textView.textContainerOrigin.y), to: self.front))
        }
        NextSentenceDust.burst(in: front, rects: rects, color: NextSentenceCardStyle.body, density: 0.6)
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            textView.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The new take streams into an empty box, so it inks in word by word.
                self.textView.textStorage?.setAttributedString(NSAttributedString(string: "", attributes: self.bodyAttributes))
                self.shownText = ""
                self.shownSignature = "burst"
                self.textView.alphaValue = 1
            }
        })
    }

    // MARK: Where a word came from: it lifts with a glow and the source unfurls from it

    func liftSource(_ mark: Mark) {
        guard hoveredMark != mark.range else { return }
        settleSource()
        guard let storage = textView.textStorage, NSMaxRange(mark.range) <= storage.length else { return }
        let glow = NSShadow()
        glow.shadowColor = mark.color.withAlphaComponent(0.9)
        glow.shadowBlurRadius = 9
        glow.shadowOffset = .zero
        storage.addAttribute(.shadow, value: glow, range: mark.range)
        hoveredMark = mark.range
        guard !NextSentenceMotion.reduced, let layer = tip.layer else { return }
        let bottom = CGPoint(x: tip.bounds.minX + 14, y: tip.bounds.maxY)
        let unfurl = CASpringAnimation(keyPath: "transform")
        unfurl.fromValue = NSValue(caTransform3D: CATransform3DConcat(
            CATransform3DConcat(CATransform3DMakeTranslation(-bottom.x, -bottom.y, 0), CATransform3DMakeScale(0.6, 0.15, 1)),
            CATransform3DMakeTranslation(bottom.x, bottom.y, 0)))
        unfurl.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        unfurl.stiffness = 340
        unfurl.damping = 22
        unfurl.duration = unfurl.settlingDuration
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = 0.16
        layer.add(unfurl, forKey: "unfurl")
        layer.add(fade, forKey: "unfurlFade")
    }

    func settleSource() {
        if let range = hoveredMark, let storage = textView.textStorage, NSMaxRange(range) <= storage.length {
            storage.removeAttribute(.shadow, range: range)
        }
        hoveredMark = nil
    }
}
