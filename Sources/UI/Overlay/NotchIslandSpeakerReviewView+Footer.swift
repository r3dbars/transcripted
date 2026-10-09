// NotchIslandSpeakerReviewView+Footer.swift
// The parts of the island's "Who spoke?" review around the rows: each
// person's color on this call (VoicePrintStyle.colorIndices in row order, so
// nobody shares one, and sticky for the review), recognized names that came
// without a clip, the footer's glowing dots with "N people named
// automatically", and the light tip under a hovered print.

import AppKit
import TranscriptedCore

@available(macOS 14.0, *)
extension NotchIslandSpeakerReviewView {
    // MARK: Recognized names without a clip

    /// The saved person behind a recognized name with no clip, when exactly
    /// one person in Speakers has that name.
    func savedID(forName name: String) -> UUID? {
        let key = SpeakerNameSelectionPolicy.normalizedSearchText(name)
        let matches = knownPeople.filter { SpeakerNameSelectionPolicy.normalizedSearchText($0.displayName) == key }
        return matches.count == 1 ? matches[0].id : nil
    }

    /// Their color on this call: deduplicated with the rows when the person
    /// is in Speakers, else their name's own color.
    func plainNameColor(_ name: String) -> Int {
        if let id = savedID(forName: name), let index = colorIndices[id] { return index }
        return VoicePrintStyle(seedString: SpeakerNameSelectionPolicy.normalizedSearchText(name)).preferredColorIndex
    }

    func plainNameNSColor(_ name: String) -> NSColor {
        NSColor(cgColor: VoicePrintInk.personColor(colorIndex: plainNameColor(name), tone: .dark).cgColor) ?? .white
    }

    /// A name Transcripted gave on its own but with no clip to play or
    /// correct from: the person's full, glowing print (with nothing to play)
    /// when the name is one person in Speakers, else a glowing dot in the
    /// print's place.
    func recognizedRow(_ name: String) -> NSView {
        let side = NotchIslandVoiceRowView.printDiameter
        let slot: NSView
        if let id = savedID(forName: name) {
            let print = VoicePrintView(
                diameter: side,
                model: VoicePrintView.Model(
                    style: VoicePrintStyle(id: id),
                    colorIndex: plainNameColor(name),
                    litRings: VoicePrintGeometry.ringCount,
                    surface: .island
                )
            )
            print.isPlayable = false
            slot = print
        } else {
            slot = NSView()
            let dot = NotchIslandGlowDot(color: plainNameNSColor(name))
            slot.addSubview(dot)
            NSLayoutConstraint.activate([
                dot.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
                dot.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
            ])
        }
        slot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            slot.widthAnchor.constraint(equalToConstant: side),
            slot.heightAnchor.constraint(equalToConstant: side),
        ])
        let nameLabel = NotchIslandPalette.label(name, font: NotchIslandNameField.titleFont, color: NotchIslandPalette.primaryText)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = NSStackView(views: [slot, nameLabel])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = NotchIslandVoiceRowView.printGap
        row.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        row.translatesAutoresizingMaskIntoConstraints = false
        row.widthAnchor.constraint(equalToConstant: Self.contentWidth).isActive = true
        row.setAccessibilityElement(true)
        row.setAccessibilityLabel(NotchIslandSpeakerReviewPolicy.rowAccessibilityLabel(.recognized, name: name, hint: nil))
        return row
    }

    // MARK: Colors and the footer

    /// Rows in the order they show.
    var displayedRows: [NotchIslandVoiceRowView] { recognizedRows + rows }

    /// Colors go out in row order the first time, and stick: answering one
    /// row never recolors another (which would also cut its animation).
    func assignColors() {
        var claims = recognizedRows.compactMap(\.claimedPersonID)
        claims += plainRecognizedNames.compactMap(savedID(forName:))
        claims += rows.compactMap(\.claimedPersonID)
        colorOrder = NotchIslandSpeakerReviewPolicy.colorOrder(existing: colorOrder, claims: claims)
        colorIndices = VoicePrintStyle.colorIndices(for: colorOrder)
        for row in displayedRows {
            if let id = row.claimedPersonID, let index = colorIndices[id] {
                row.setColorIndex(index)
            }
        }
    }

    /// Glowing dots for the people named automatically on this call, then
    /// "N people named automatically". Dots already showing stay as they
    /// are. A print a ✓ just completed sends its dot in once the print has
    /// settled (`VoicePrintCascadePlan.FooterLanding`), one beat at a time:
    /// the dot pops in, its sparkle follows, then the count ticks up in the
    /// person's color. Reduce Motion fades both in, with no sparkle.
    func refreshFooterSummary(animated: Bool, landing: String? = nil) {
        var wanted: [(key: String, color: NSColor, lands: Bool)] = []
        for row in recognizedRows where row.isNamedAutomatically {
            wanted.append((footerKey(row), row.personColor, false))
        }
        for name in plainRecognizedNames {
            let key = NotchIslandSpeakerReviewPolicy.footerPersonKey(personID: savedID(forName: name), name: name, fallback: "")
            wanted.append((key, plainNameNSColor(name), false))
        }
        for row in rows where row.isNamedAutomatically {
            wanted.append((footerKey(row), row.personColor, row.rowState == .confirmed))
        }
        wanted = NotchIslandSpeakerReviewPolicy.uniqueFooterPeople(wanted, key: { $0.key })
        let wantedKeys = Set(wanted.map(\.key))
        for (key, task) in footerLandings where !wantedKeys.contains(key) {
            task.cancel()
            footerLandings[key] = nil
        }
        for dot in footerDots where !wantedKeys.contains(dot.key) {
            dot.view.removeFromSuperview()
        }
        let reduceMotion = NotchIslandPalette.reduceMotion
        var shown: [(key: String, view: NotchIslandGlowDot)] = []
        var tickColor: NSColor?
        for dot in wanted {
            if let existing = footerDots.first(where: { $0.key == dot.key }) {
                existing.view.setColor(dot.color)
                shown.append(existing)
            } else if dot.key == landing, footerLandings[dot.key] != nil {
                footerLandings[dot.key] = nil
                let view = NotchIslandGlowDot(color: dot.color)
                view.popIn(after: 0, reduceMotion: reduceMotion)
                if !reduceMotion { view.sparkle(after: VoicePrintCascadePlan.FooterLanding.sparkleDelay) }
                shown.append((dot.key, view))
                tickColor = dot.color
            } else if footerLandings[dot.key] != nil {
                continue
            } else if animated, dot.lands {
                footerLandings[dot.key] = landFooterDot(dot.key, after: reduceMotion ? 0 : VoicePrintCascadePlan.FooterLanding.dotDelay)
            } else {
                shown.append((dot.key, NotchIslandGlowDot(color: dot.color)))
            }
        }
        footerDots = shown
        // Only add, move or drop what changed, so a dot mid-pop keeps going.
        let views: [NSView] = shown.map(\.view) + [footerCount, footerSpacer]
        for (index, view) in views.enumerated() {
            let arranged = footerSummary.arrangedSubviews
            if index < arranged.count, arranged[index] === view { continue }
            footerSummary.insertArrangedSubview(view, at: index)
        }
        while footerSummary.arrangedSubviews.count > views.count {
            footerSummary.arrangedSubviews.last?.removeFromSuperview()
        }
        footerCount.setText(
            SpeakerNamingTierPresentation.autoNamedFooter(count: shown.count),
            tickColor: tickColor,
            tickDelay: VoicePrintCascadePlan.FooterLanding.countDelay,
            reduceMotion: reduceMotion
        )
    }

    private func footerKey(_ row: NotchIslandVoiceRowView) -> String {
        NotchIslandSpeakerReviewPolicy.footerPersonKey(
            personID: row.claimedPersonID, fallback: "row-\(ObjectIdentifier(row).hashValue)"
        )
    }

    /// Lands a waiting dot after `delay`, unless it was undone meanwhile.
    private func landFooterDot(_ key: String, after delay: Double) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self, !self.isFinished else { return }
            self.refreshFooterSummary(animated: true, landing: key)
        }
    }

    // MARK: The print tip

    /// Shows the tip under a print after a short rest, like a system tooltip,
    /// so passing over it is quiet; nil hides it.
    func showPrintTip(_ text: String?, under anchor: NSView) {
        tipTask?.cancel()
        guard let text else {
            hidePrintTip()
            return
        }
        tipTask = Task { @MainActor [weak self, weak anchor] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled, let self, let anchor, anchor.window != nil, !self.isFinished else { return }
            let frame = anchor.convert(anchor.bounds, to: self)
            self.printTip.text = text
            self.tipLeading?.constant = frame.minX - 2
            self.tipTop?.constant = frame.maxY + 8
            self.printTip.isHidden = false
        }
    }

    func hidePrintTip() {
        tipTask?.cancel()
        tipTask = nil
        printTip.isHidden = true
    }
}
