// SpeakerWhoSpokeHeightWatch.swift
// Tells the Speakers page's "Who spoke?" card host that the review it holds
// changed height, so SwiftUI sizes the card to match. The host only takes
// clicks inside the height SwiftUI gave it: a review that grew without the
// page hearing about it draws its footer (Skip, "Done, next meeting") below
// that height, where clicks never reach it.

import AppKit

@MainActor
final class SpeakerWhoSpokeHeightWatch: NSObject {
    private let onChange: () -> Void

    init(watching view: NSView, onChange: @escaping () -> Void) {
        self.onChange = onChange
        super.init()
    }

    /// The review said its layout changed.
    func layoutChanged() {
        onChange()
    }
}
