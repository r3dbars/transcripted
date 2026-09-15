# Speaker review light appearance

`speaker-review-light-macos27.png` is a native AppKit rendering of the real
`SpeakerNamingSheet` source on macOS 27 with two synthetic remote-speaker rows.
The fixture sets the drawing thread to dark while the review window uses Aqua,
matching the color-resolution mismatch in the support report. The light card
resolved to an opaque white fill and its labels stayed readable. A second
synthetic check switched the window to Dark Aqua and confirmed the card kept
its translucent white fill (`alpha = 0.055`).

The image contains fixture names and text only. It does not prove behavior in a
customer install, with a real meeting, or after a published update.
