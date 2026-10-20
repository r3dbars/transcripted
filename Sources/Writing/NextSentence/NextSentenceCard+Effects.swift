import AppKit
import CoreImage
import QuartzCore

/// The card's livelier moments: listening, a tone change, a swapped word, a fresh take, and a tinted
/// word showing where it came from.
extension NextSentenceCard {
    // MARK: Listening: the card's edge glows with your voice

    /// While it listens, the edge is the only thing that moves: one clear signal.
    func startListeningEffects() {
        voiceGlow.start()
    }

    /// The microphone's loudness right now, 0...1.
    func setVoiceLevel(_ level: CGFloat) {
        voiceGlow.set(level: level)
    }

    /// With `flare` (they let go), the edge breathes bright once with the chime before it fades.
    func stopListeningEffects(flare: Bool) {
        voiceGlow.stop(flare: flare)
    }

    // MARK: A different version: shared words glide into place, new ones fade in marked

    typealias WordShot = (range: NSRange, rect: NSRect, image: NSImage)

    /// Pictures of the words on the card and where each one sits, taken just before the text changes.
    /// One picture of the text, cut up, so it costs the same however long the message is.
    func captureWords() -> [WordShot] {
        finishGlide()
        let bounds = textView.bounds
        guard !textView.string.isEmpty, bounds.width > 0, bounds.height > 0,
              let rep = textView.bitmapImageRepForCachingDisplay(in: bounds) else { return [] }
        textView.cacheDisplay(in: bounds, to: rep)
        guard let picture = rep.cgImage else { return [] }
        let scale = CGFloat(picture.width) / bounds.width
        return NextSentencePolicy.wordRanges(in: textView.string).compactMap { range in
            let rect = Self.shotRect(textView.rect(for: range)).intersection(bounds)
            guard rect.width > 0, rect.height > 0,
                  let piece = picture.cropping(to: CGRect(x: rect.minX * scale, y: rect.minY * scale,
                                                          width: rect.width * scale, height: rect.height * scale)) else { return nil }
            return (range, rect, NSImage(cgImage: piece, size: rect.size))
        }
    }

    /// A word's picture: its rect with a point to spare each side, on whole points.
    private static func shotRect(_ word: NSRect) -> NSRect { word.insetBy(dx: -1, dy: 0).integral }

    /// After a different version replaced `old`: words the two share glide from where they were to where
    /// they are now, words it dropped fade where they were, and new words fade in warm, then cool.
    func glide(from old: String, shots: [WordShot]) {
        let new = textView.string
        let pairs = NextSentencePolicy.matchedWords(from: old, to: new)
        let shared = Set(pairs.map { $0.new.location })
        mark.start(NextSentencePolicy.wordRanges(in: new).filter { !shared.contains($0.location) })
        applyMark()
        guard !shots.isEmpty, let layoutManager = textView.layoutManager else { return }
        glideView.frame = textView.bounds
        glideGeneration += 1
        let generation = glideGeneration
        let byLocation = Dictionary(shots.map { ($0.range.location, $0) }, uniquingKeysWith: { first, _ in first })
        var moving: [(NSView, NSPoint)] = []
        var kept = Set<Int>()
        for pair in pairs {
            guard let shot = byLocation[pair.old.location] else { continue }
            let to = Self.shotRect(textView.rect(for: pair.new))
            guard to.width > 0 else { continue }
            kept.insert(pair.old.location)
            // The real word hides until its picture lands on it.
            layoutManager.addTemporaryAttribute(.foregroundColor, value: NSColor.clear, forCharacterRange: pair.new)
            glideHidden.append(pair.new)
            moving.append((piece(shot), to.origin))
        }
        let leaving = shots.filter { !kept.contains($0.range.location) }.map(piece)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.26
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.25, 1)
            context.allowsImplicitAnimation = true
            for (view, origin) in moving { view.animator().setFrameOrigin(origin) }
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            for view in leaving { view.animator().alphaValue = 0 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, generation == self.glideGeneration else { return }
            self.finishGlide()
        }
    }

    private func piece(_ shot: WordShot) -> NSView {
        let view = NSImageView(frame: shot.rect)
        view.image = shot.image
        view.imageScaling = .scaleAxesIndependently
        view.wantsLayer = true
        glideView.addSubview(view)
        return view
    }

    /// Ends a glide at once: the pictures go and the real words show where they belong.
    func finishGlide() {
        glideGeneration += 1
        glideView.subviews.forEach { $0.removeFromSuperview() }
        let length = (textView.string as NSString).length
        for range in glideHidden where NSMaxRange(range) <= length {
            textView.layoutManager?.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        }
        glideHidden.removeAll()
    }

    /// Recolors the new words every frame until they've settled.
    func applyMark() {
        guard let storage = textView.textStorage, mark.isActive else { markTimer?.invalidate(); markTimer = nil; return }
        mark.apply(to: storage) { [content] location in
            content.marks.first { NSLocationInRange(location, $0.range) }?.color ?? NextSentenceCardStyle.body
        }
        guard markTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.applyMark() } }
        RunLoop.main.add(timer, forMode: .common)
        markTimer = timer
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
