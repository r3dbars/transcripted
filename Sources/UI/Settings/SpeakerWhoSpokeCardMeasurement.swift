// SpeakerWhoSpokeCardMeasurement.swift
// When the Speakers page's "Who spoke?" card measures itself and what height
// it hands SwiftUI. The card is AppKit (`NotchIslandSpeakerReviewView`)
// inside the page's SwiftUI scroll view, so SwiftUI asks its size on every
// layout, scrolling included.

import CoreGraphics

struct SpeakerWhoSpokeCardMeasurement: Equatable {
    /// The last height the card measured, nil before its first measurement.
    private(set) var height: CGFloat?
    /// A measurement is scheduled and hasn't run yet.
    private(set) var isMeasurePending = false

    /// The height SwiftUI gets when it asks the card's size. Nil means the
    /// card must lay itself out to answer.
    var intrinsicHeight: CGFloat? { nil }

    /// A new card went up or a row changed size. True when a measurement
    /// should be scheduled.
    mutating func layoutChanged() -> Bool {
        isMeasurePending = true
        return true
    }

    /// The scheduled measurement ran. Returns the height to hand SwiftUI.
    mutating func measured(_ measured: CGFloat) -> CGFloat? {
        isMeasurePending = false
        height = measured
        return measured
    }
}
