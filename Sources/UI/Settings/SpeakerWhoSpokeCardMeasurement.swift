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

    /// The height SwiftUI gets when it asks the card's size: the last one
    /// measured, never a fresh layout. Nil before the first measurement.
    var intrinsicHeight: CGFloat? { height }

    /// A new card went up or a row changed size. True when a measurement
    /// should be scheduled; false when one already waits and will see this
    /// change too.
    mutating func layoutChanged() -> Bool {
        guard !isMeasurePending else { return false }
        isMeasurePending = true
        return true
    }

    /// The scheduled measurement ran. Returns the height to hand SwiftUI,
    /// or nil when it hasn't changed, so the page isn't updated for nothing.
    mutating func measured(_ measured: CGFloat) -> CGFloat? {
        isMeasurePending = false
        guard measured != height else { return nil }
        height = measured
        return measured
    }
}
