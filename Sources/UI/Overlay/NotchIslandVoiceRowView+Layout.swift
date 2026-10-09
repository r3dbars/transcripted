// NotchIslandVoiceRowView+Layout.swift
// How one voice row lays out (Prints.dc.html): print, title column and
// buttons on one line; under it, while the name field is open, the invitee
// chips (only while it has the keyboard) or the autocomplete list. Rows have
// no card behind them, and nothing here clips, so the print's match animation
// can spill past the row.

import AppKit
import TranscriptedCore

@available(macOS 14.0, *)
extension NotchIslandVoiceRowView {
    // MARK: Skeleton

    func buildSkeleton() {
        translatesAutoresizingMaskIntoConstraints = false
        clipsToBounds = false
        widthAnchor.constraint(equalToConstant: NotchIslandSpeakerReviewView.contentWidth).isActive = true

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = 3
        textColumn.translatesAutoresizingMaskIntoConstraints = false
        textColumn.setHuggingPriority(.defaultLow, for: .horizontal)
        // Keep the title block its own height, centered on the print.
        textColumn.setHuggingPriority(.required, for: .vertical)
        textColumn.setClippingResistancePriority(.defaultLow, for: .horizontal)

        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 8
        controls.setHuggingPriority(.required, for: .horizontal)
        controls.setClippingResistancePriority(.required, for: .horizontal)

        topLine.orientation = .horizontal
        topLine.alignment = .centerY
        topLine.spacing = Self.printGap
        topLine.distribution = .fill
        topLine.translatesAutoresizingMaskIntoConstraints = false
        topLine.addArrangedSubview(printSlot)
        topLine.addArrangedSubview(textColumn)
        topLine.addArrangedSubview(controls)
        stack.addArrangedSubview(topLine)
        NSLayoutConstraint.activate([
            topLine.widthAnchor.constraint(equalToConstant: NotchIslandSpeakerReviewView.contentWidth),
            topLine.heightAnchor.constraint(greaterThanOrEqualToConstant: Self.printDiameter),
        ])
    }

    /// The name field sits where the title would, its text on the title's
    /// line and its highlight reaching a little to the left.
    func makeTitleFieldHolder() -> NSView {
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.clipsToBounds = false
        holder.addSubview(titleField)
        NSLayoutConstraint.activate([
            holder.heightAnchor.constraint(equalToConstant: NotchIslandTitleField.height),
            titleField.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: -NotchIslandTitleField.leadingBleed),
            titleField.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
            titleField.topAnchor.constraint(equalTo: holder.topAnchor),
            titleField.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
        ])
        return holder
    }

    // MARK: Rebuilding

    func rebuild(animated: Bool = true) {
        // A voice kept as You or discarded is dimmed, like the window's.
        alphaValue = lock == nil ? 1 : 0.62
        rebuildTextColumn(animated: animated)
        rebuildControls()
        rebuildBelow()
        refreshAccessibility()
        needsLayout = true
    }

    func refreshAccessibility() {
        let hint = Policy.rowHint(rowState, progress: progress, prefilledUntouched: prefilledUntouched)
        setAccessibilityLabel(Policy.rowAccessibilityLabel(rowState, name: shownName, hint: hint?.text, corrected: isRecognized))
        setAccessibilityHelp(printExplanation)
    }

    func rebuildTextColumn(animated: Bool) {
        let state = rowState
        let title = Policy.rowTitle(state, name: shownName)
        // The name field stays put while it's the title, so typing keeps
        // the keyboard and the caret through a rebuild.
        let keepsField = title == nil && titleFieldHolder.superview === textColumn
        for view in textColumn.arrangedSubviews where !(keepsField && view === titleFieldHolder) {
            view.removeFromSuperview()
        }
        if let title {
            let color = Policy.titleIsUnanswered(state) ? NSColor(white: 1, alpha: 0.85) : NotchIslandPalette.primaryText
            let label = NotchIslandPalette.label(title, font: NotchIslandNameField.titleFont, color: color)
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            textColumn.addArrangedSubview(label)
        } else if !keepsField {
            textColumn.addArrangedSubview(titleFieldHolder)
            titleFieldHolder.widthAnchor.constraint(equalTo: textColumn.widthAnchor).isActive = true
        }
        hintLabel = nil
        let hint = Policy.rowHint(state, progress: progress, prefilledUntouched: prefilledUntouched)
        if let hint {
            let label = NotchIslandPalette.label(hint.text, font: .systemFont(ofSize: 12, weight: .medium), color: NSColor(white: 1, alpha: 0.45))
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            textColumn.addArrangedSubview(label)
            hintLabel = label
            hintUsesPersonColor = hint.usesPersonColor
            updateHintColor()
            if animated, hint.text != shownHint, !NotchIslandPalette.reduceMotion {
                riseIn(label)
            }
        }
        shownHint = hint?.text
    }

    func updateHintColor() {
        guard let hintLabel else { return }
        hintLabel.textColor = hintUsesPersonColor ? personColor : NSColor(white: 1, alpha: 0.45)
    }

    /// The mockup's `rise`: fade in while sliding up 4 pt.
    private func riseIn(_ view: NSView) {
        view.wantsLayer = true
        guard let layer = view.layer else { return }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        slide.fromValue = layer.contentsAreFlipped() ? 4 : -4
        slide.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [fade, slide]
        group.duration = 0.25
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(group, forKey: "rise")
    }

    func rebuildControls() {
        controls.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for control in Policy.rowControls(rowState, hovered: isPointerInside) {
            controls.addArrangedSubview(view(for: control))
        }
        controls.isHidden = controls.arrangedSubviews.isEmpty
    }

    private func view(for control: Policy.RowControl) -> NSView {
        let first = (entry.currentName ?? "").split(whereSeparator: { $0.isWhitespace }).first.map(String.init) ?? ""
        switch control {
        case .no:
            let button = NotchIslandRoundIconButton(kind: .no, accessibilityLabel: "No, not \(first)")
            button.onPress = { [weak self] in self?.reject() }
            return button
        case .yes:
            let button = NotchIslandRoundIconButton(kind: .yes, accessibilityLabel: "Yes, this is \(entry.currentName ?? first)")
            button.onPress = { [weak self] in self?.confirm() }
            return button
        case .undo:
            let button = NotchIslandTextButton(title: "Undo")
            button.setAccessibilityHelp("Take back this answer.")
            button.onPress = { [weak self] in self?.undo() }
            return button
        case .correct:
            let button = NotchIslandTextButton(title: Policy.correctionPrompt(name: entry.currentName ?? ""), restAlpha: 0.6)
            button.setAccessibilityHelp("Correct the name Transcripted gave this voice.")
            button.onPress = { [weak self] in self?.reject() }
            return button
        case .keep:
            let button = NotchIslandTextButton(title: "Undo")
            button.setAccessibilityLabel("Keep \(first)")
            button.setAccessibilityHelp("It was \(entry.currentName ?? first) after all.")
            button.onPress = { [weak self] in self?.keepRecognized() }
            return button
        case .discard:
            return NotchIslandDiscardControl { [weak self] in self?.toggleDiscard() }
        case .undoDiscard:
            let button = NotchIslandTextButton(title: Policy.discardTitle(discarded: true))
            button.setAccessibilityLabel(Policy.undoDiscardAccessibilityLabel)
            button.setAccessibilityHelp("Save this voice to People after all.")
            button.onPress = { [weak self] in self?.toggleDiscard() }
            return button
        }
    }

    /// Chips (focused, empty field) or the list (something typed) under the
    /// title. The top line stays, so the field keeps the keyboard and caret.
    func rebuildBelow() {
        while stack.arrangedSubviews.count > 1 {
            stack.arrangedSubviews.last?.removeFromSuperview()
        }
        showsChips = false
        guard isEditing, lock == nil else { return }
        if let chips = inviteeLine() {
            stack.addArrangedSubview(chips)
            showsChips = true
            if !NotchIslandPalette.reduceMotion { riseIn(chips) }
        }
        if let list = suggestionList() { stack.addArrangedSubview(list) }
    }

    private func indented(_ view: NSView) -> NSView {
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.widthAnchor.constraint(equalToConstant: Self.belowIndent - 6).isActive = true
        let line = NSStackView(views: [spacer, view])
        line.orientation = .horizontal
        line.alignment = .top
        line.spacing = 6
        return line
    }

    private func inviteeLine() -> NSView? {
        guard Policy.showsInviteeChips(typed: nameField.stringValue, focused: titleField.isFocused) else { return nil }
        var names = Policy.inviteeChips(invitees: invitees, alreadyUsed: usedNames, showAll: showAllInvitees)
        if isMic {
            // Your own mic: "Me" is always one tap away.
            names.shown.insert(SpeakerNameSelectionPolicy.ownerLabel, at: 0)
        }
        guard !names.shown.isEmpty else { return nil }
        var views: [NSView] = []
        for name in names.shown {
            let isOwner = name == SpeakerNameSelectionPolicy.ownerLabel
            let chip = NotchIslandChipButton(title: isOwner ? "Me" : name)
            chip.onPress = { [weak self] in self?.pick(name) }
            chip.setAccessibilityHelp(isOwner ? "This is your own voice." : "\(name) was on the calendar invite.")
            views.append(chip)
        }
        if names.hidden > 0 {
            let more = NotchIslandChipButton(title: "\u{203A}")
            more.onPress = { [weak self] in
                guard let self else { return }
                self.showAllInvitees = true
                self.rebuildBelow()
                self.onChange?()
            }
            more.setAccessibilityLabel("Show \(names.hidden) more invitees")
            views.append(more)
        }
        let chips = NSStackView(views: views)
        chips.orientation = .horizontal
        chips.spacing = 6
        return indented(chips)
    }

    private func suggestionList() -> NSView? {
        let typed = nameField.stringValue
        let suggestions = currentSuggestions
        let rows = Policy.nameBoxRows(typed: typed, suggestions: suggestions)
        guard !rows.isEmpty else { return nil }
        let highlighted = highlightedRow ?? Policy.defaultHighlight(typed: typed, suggestions: suggestions)
        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 2
        list.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        list.wantsLayer = true
        list.layer?.backgroundColor = NotchIslandPalette.buttonSubtle.cgColor
        list.layer?.cornerRadius = 10
        let width = NotchIslandSpeakerReviewView.contentWidth - Self.belowIndent
        let details = Dictionary(suggestions.map { ($0.label, $0.detail) }, uniquingKeysWith: { first, _ in first })
        for (index, row) in rows.enumerated() {
            let detail: String
            switch row {
            case .saved(let label): detail = details[label] ?? ""
            case .newPerson: detail = "new person"
            }
            let button = NotchIslandSuggestionButton(title: row.displayTitle, detail: detail, width: width - 8)
            button.isHighlightedRow = index == highlighted
            button.onPress = { [weak self] in self?.pick(row.label) }
            list.addArrangedSubview(button)
        }
        list.translatesAutoresizingMaskIntoConstraints = false
        list.widthAnchor.constraint(equalToConstant: width).isActive = true
        return indented(list)
    }

    // MARK: Hover (recognized voices)

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        guard isRecognized else { return }
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        setPointerInside(true)
    }

    override func mouseExited(with event: NSEvent) {
        setPointerInside(false)
    }

    private func setPointerInside(_ inside: Bool) {
        guard isRecognized, inside != isPointerInside else { return }
        isPointerInside = inside
        // Only a resting recognized row changes on hover ("Not Priya?").
        guard rowState == .recognized else { return }
        rebuildControls()
    }
}
