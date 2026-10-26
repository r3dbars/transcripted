import Foundation
import Testing
@testable import TranscriptedWritingCore
@testable import TranscriptedWritingRuntime

/// Save my writing: typing a word in one go saves it as that word, whatever
/// caret the host app reports while it goes in. Keys go through the
/// keyboard's caret continuity and segment chain into the app's entry
/// composer, and the saved entry text comes out.
@Suite("Save my writing caret continuity")
struct PersonalHistoryCaretContinuityTests {
    private static let start: Int64 = 1_790_350_931_387
    private static let app = "com.example.Browser"

    /// How a host reports its caret for the key about to go in, given where
    /// the text really ends and the carets it really had before each key.
    enum Host {
        /// Reports the real caret.
        case keepsUp
        /// Reports `{0, 0}` whenever nothing is selected (a terminal).
        case frozen
        /// Reports the caret from `keys` keys ago.
        case behind(keys: Int)
        /// Reports the real caret with an inline completion selected after it.
        case selectsCompletion

        func selection(history: [Int]) -> NSRange {
            let caret = history.last ?? 0
            switch self {
            case .keepsUp: return NSRange(location: caret, length: 0)
            case .frozen: return NSRange(location: 0, length: 0)
            case let .behind(keys):
                return NSRange(location: history[max(0, history.count - 1 - keys)], length: 0)
            case .selectsCompletion:
                return NSRange(location: caret, length: history.count > 1 ? 9 : 0)
            }
        }
    }

    /// The keyboard side: what `GhostInputController` does per key with the
    /// continuity, the deletion tracker and the segment identifier.
    struct Keyboard {
        var continuity = PersonalHistoryCaretContinuity()
        var deletions = PersonalHistoryDeletionTracker()
        var segment = "chain"
        var chains = 0
        var events: [PersonalHistoryEvent] = []
        var clock = PersonalHistoryCaretContinuityTests.start

        mutating func breakSegment() {
            chains += 1
            segment = "chain\(chains)"
            continuity.reset()
            deletions.reset()
        }

        mutating func type(_ text: String, at selection: NSRange) {
            clock += 120
            switch continuity.insertion(bundle: app, selection: selection, utf16Length: text.utf16.count) {
            case .unusable:
                breakSegment()
                return
            case .breaks:
                let kept = continuity
                breakSegment()
                continuity = kept
            case .continues:
                break
            }
            events.append(PersonalHistoryEvent(
                id: "event-\(events.count)",
                timestampMilliseconds: clock,
                historyIdentifier: "history",
                sessionIdentifier: segment,
                appBundleIdentifier: app,
                source: .typed,
                text: text
            )!)
            deletions.inserted(text)
        }

        mutating func backspace(at selection: NSRange) {
            clock += 120
            guard continuity.isAtOwnTextEnd(bundle: app, selection: selection),
                  let backspace = deletions.backspace() else {
                breakSegment()
                return
            }
            if backspace.rotatesSegment {
                segment = PersonalHistorySegmentChain.continuation(of: segment)
            }
            continuity.backspaced(utf16Length: backspace.utf16Length, caret: selection.location)
            events.append(PersonalHistoryEvent(
                deletionID: "event-\(events.count)",
                timestampMilliseconds: clock,
                historyIdentifier: "history",
                sessionIdentifier: segment,
                appBundleIdentifier: app,
                deletedCharacters: backspace.utf16Length
            )!)
        }

        func savedText() -> String? {
            var composer = WritingEntryComposer(makeEntryID: { "entry-\($0)" })
            _ = composer.ingest(events, receivedAt: Date(timeIntervalSince1970: Double(clock) / 1_000))
            return composer.closeAll().first?.text
        }
    }

    /// Types `keys` one at a time into `host`, starting in a field that
    /// already holds `existing` UTF-16 units before the caret. `⌫` is a
    /// plain Backspace.
    private static func typeInOneGo(_ keys: String, into host: Host, existing: Int = 0) -> Keyboard {
        var keyboard = Keyboard()
        var history = [existing]
        for key in keys {
            let selection = host.selection(history: history)
            if key == "⌫" {
                keyboard.backspace(at: selection)
                history.append(history.last! - 1)
            } else {
                keyboard.type(String(key), at: selection)
                history.append(history.last! + String(key).utf16.count)
            }
        }
        return keyboard
    }

    @Test(
        "Typing a word in one go saves it as that word, whatever caret the host reports",
        arguments: [Host.keepsUp, .frozen, .behind(keys: 1), .behind(keys: 3), .selectsCompletion]
    )
    func wordSavedWhole(host: Host) {
        let keyboard = Self.typeInOneGo("nightjar", into: host, existing: 14)
        #expect(keyboard.savedText() == "nightjar")
        #expect(keyboard.chains == 0)
    }

    @Test("A sentence typed in one go into a frozen caret stays one line")
    func sentenceInFrozenHost() {
        let keyboard = Self.typeInOneGo("git push origin feature-otter", into: .frozen)
        #expect(keyboard.savedText() == "git push origin feature-otter")
    }

    @Test(
        "Fixing a typo with Backspace mid-word saves the fixed word, whatever caret the host reports",
        // Not `.selectsCompletion`: there a Backspace takes out the host's
        // selected completion, not the keyboard's text, and breaks the chain.
        arguments: [Host.keepsUp, .frozen, .behind(keys: 1), .behind(keys: 2)]
    )
    func backspaceFixSavedWhole(host: Host) {
        #expect(Self.typeInOneGo("lanterm⌫n", into: host, existing: 5).savedText() == "lantern")
        #expect(Self.typeInOneGo("teh⌫⌫he otter", into: host).savedText() == "the otter")
    }

    @Test("A click back into earlier text in a host that keeps up still starts a new segment")
    func caretJumpStillBreaks() {
        var keyboard = Self.typeInOneGo("pebble harbor", into: .keepsUp)
        keyboard.type("x", at: NSRange(location: 3, length: 0))
        #expect(keyboard.chains == 1)
        #expect(keyboard.savedText() == "pebble harbor\nx")
    }

    @Test("A caret past the keyboard's own text, or another app, starts a new segment")
    func caretAheadOrOtherAppBreaks() {
        var continuity = PersonalHistoryCaretContinuity()
        #expect(continuity.insertion(bundle: Self.app, selection: NSRange(location: 4, length: 0), utf16Length: 1) == .continues)
        #expect(continuity.insertion(bundle: Self.app, selection: NSRange(location: 9, length: 0), utf16Length: 1) == .breaks)
        #expect(continuity.insertion(bundle: "com.example.Other", selection: NSRange(location: 10, length: 0), utf16Length: 1) == .breaks)
        #expect(continuity.insertion(bundle: "com.example.Other", selection: NSRange(location: NSNotFound, length: 0), utf16Length: 1) == .unusable)
        #expect(!continuity.isTracking)
    }
}
