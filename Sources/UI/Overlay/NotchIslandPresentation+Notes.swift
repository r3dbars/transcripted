// NotchIslandPresentation+Notes.swift
// The island's two tiers of dictation message, its one countdown look, and a
// few shared wing words. Foundation-pure like NotchIslandPresentation, so the
// fast tests cover them.

import Foundation

/// A dictation message that needs nothing from anyone: no words to rescue,
/// no button to press. It stays in the wing as a few words for the same few
/// seconds and never opens the drop-down; a hover shows the full sentence
/// when there is more to read. Everything else (words that didn't land, an
/// error, a choice) is the second tier and opens the drop-down by itself.
struct NotchIslandPassingNote: Equatable {
    var symbol: NotchIslandSymbol
    var tint: NotchIslandTint
    var label: String
    /// A second word or two on the right wing ("Press Return").
    var trailing: String?
    /// The sentence a hover shows; nil when the wing already says it all.
    var hoverText: String?

    static func make(_ message: NotchIslandDictationContent.Message) -> NotchIslandPassingNote? {
        guard message.actionTitle == nil, message.preview == nil else { return nil }
        switch message.tone {
        case .noSpeech:
            guard let label = DictationNoSpeechPresentationPolicy.passingLabel(for: message.text) else { return nil }
            return NotchIslandPassingNote(symbol: .warning, tint: .warning, label: label, trailing: nil, hoverText: message.text)
        case .notice:
            // The paste almost certainly landed and Auto Enter waits for a
            // proof it didn't get: the words are in, Return is up to you.
            guard message.text == DictationDeliveryPresentation.likelyPastedAutoSendNotice else { return nil }
            return NotchIslandPassingNote(symbol: .check, tint: .accent, label: "Pasted", trailing: "Press Return", hoverText: nil)
        case .error, .saved:
            return nil
        }
    }
}

/// The left wing's two words for a dictation error: the cause, the way
/// "No speech" and "Not pasted" name theirs. Read from the message's own
/// words, so a message nobody listed here still reads "Dictation".
enum NotchIslandErrorWingLabel {
    static let fallback = "Dictation"

    static func make(_ text: String) -> String {
        let text = text.lowercased()
        func has(_ words: String...) -> Bool { words.contains { text.contains($0) } }
        if has("quit paused") { return "Quit paused" }
        if has("microphone access", "mic access", "allow microphone") { return "Mic off" }
        if has("couldn't start", "didn't start") { return "Didn't start" }
        if has("microphone", "mic unavailable") { return "Mic problem" }
        if has("try again in a moment", "warming up") { return "Not ready" }
        if has("didn't load") { return "Model failed" }
        if has("couldn't save", "couldn't be saved", "only in memory", "couldn't be moved", "retry saving") {
            return "Not saved"
        }
        if has("no longer available") { return "Audio gone" }
        if has("couldn't copy", "clipboard") { return "Not copied" }
        if has("paste") { return "Not pasted" }
        return fallback
    }
}

/// The one countdown look: a ring on the button that fires when time runs
/// out (Dismiss, Skip, Stop, Keep). Nothing else on the island counts down.
struct NotchIslandCountdownRing: Equatable {
    var button: MeetingIslandPromptButton
    var secondsLeft: Double
    var totalSeconds: Double
    /// The timer behind it stops while the pointer rests on the island, so
    /// the ring does too.
    var holdsWhileHovered: Bool

    /// How much of the ring is left, 0...1.
    var fraction: Double {
        guard totalSeconds > 0 else { return 1 }
        return min(1, max(0, secondsLeft / totalSeconds))
    }
}

/// Meeting words shared by the wing and the drop-down, so they say the same
/// thing in both places.
enum NotchIslandMeetingCopy {
    static let callAudioNextMeeting = "Call audio: next meeting"
    static let callAudioOff = "Call audio is off"
    static let cantConfirmCallAudio = "Can't confirm call audio"
    static let micMuted = "Mic muted"
    static let bothSides = "You and others"
    static let otherSideLane = "Others"
}

// MARK: - Live transcript while the drop-down is closed

extension NotchIslandPresentation {
    /// How often a closed drop-down's live transcript catches up.
    static let hiddenTranscriptFlushInterval: TimeInterval = 5

    /// Whether a closed drop-down's live transcript applies this update now.
    /// At most every 5 s, so opening lays out at most 5 s of text. A trim
    /// rebuilds the whole text, so that one still waits for the open.
    static func flushesHiddenTranscript(
        now: TimeInterval,
        lastFlush: TimeInterval?,
        trimGeneration: Int,
        renderedTrimGeneration: Int
    ) -> Bool {
        guard trimGeneration == renderedTrimGeneration else { return false }
        guard let lastFlush else { return true }
        return now - lastFlush >= hiddenTranscriptFlushInterval
    }
}
