import AppKit

// Promises for keeping the "Who spoke?" card as tall as the review it holds.
// User report on 1.1.74: with more than two meetings to confirm, after
// confirming every voice, neither Skip nor "Done, next meeting" did anything.
// The card host takes clicks only inside the height SwiftUI gave it, so any
// change in the review's height has to reach the page, including the ones the
// review doesn't announce (a footer dot landing after a ✓, for one).
@MainActor
func testSpeakerWhoSpokeHeightWatch() {
    func hosted(height: CGFloat) -> (host: NSView, review: NSView, height: NSLayoutConstraint) {
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 1_000))
        let review = NSView()
        review.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(review)
        let heightConstraint = review.heightAnchor.constraint(equalToConstant: height)
        NSLayoutConstraint.activate([
            review.topAnchor.constraint(equalTo: host.topAnchor),
            review.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            review.widthAnchor.constraint(equalToConstant: 600),
            heightConstraint,
        ])
        host.layoutSubtreeIfNeeded()
        return (host, review, heightConstraint)
    }

    runSuite("A review that grows without saying so still tells the page") {
        let card = hosted(height: 300)
        var reports = 0
        let watch = SpeakerWhoSpokeHeightWatch(watching: card.review) { reports += 1 }
        card.height.constant = 360
        card.host.layoutSubtreeIfNeeded()
        assertEqual(card.review.frame.height, 360, "the review laid itself out taller")
        assertEqual(reports, 1, "the page hears the new height, so Skip and Done stay inside the card")
        withExtendedLifetime(watch) {}
    }

    runSuite("A review that shrinks tells the page too") {
        let card = hosted(height: 300)
        var reports = 0
        let watch = SpeakerWhoSpokeHeightWatch(watching: card.review) { reports += 1 }
        card.height.constant = 240
        card.host.layoutSubtreeIfNeeded()
        assertEqual(reports, 1, "a shorter review leaves no empty card under it")
        withExtendedLifetime(watch) {}
    }

    runSuite("A layout pass that keeps the height tells the page nothing") {
        let card = hosted(height: 300)
        var reports = 0
        let watch = SpeakerWhoSpokeHeightWatch(watching: card.review) { reports += 1 }
        card.host.needsLayout = true
        card.host.layoutSubtreeIfNeeded()
        card.host.setFrameSize(NSSize(width: 640, height: 1_000))
        card.host.layoutSubtreeIfNeeded()
        assertEqual(reports, 0, "the same height again is not news, so scrolling stays quiet")
        withExtendedLifetime(watch) {}
    }

    runSuite("The review's own layout-change call still tells the page") {
        let card = hosted(height: 300)
        var reports = 0
        let watch = SpeakerWhoSpokeHeightWatch(watching: card.review) { reports += 1 }
        watch.layoutChanged()
        assertEqual(reports, 1, "a row that says it changed is measured as before")
    }
}
