#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Cocoa
import InputMethodKit

/// Lightweight capture-only IMKit keyboard for opt-in "Save my writing".
/// Never draws marked text, never intercepts or alters keystrokes (always
/// returns `false` so the host app handles every key natively), and forwards
/// typed text + tracked Backspaces to Transcripted's local Markdown day-file
/// writer over the authenticated unix socket when the user has opted in.
@objc(GhostInputController)
final class GhostInputController: IMKInputController {
    private struct InsertionObservation {
        let bundle: String
        let selection: NSRange
    }

    var historySegmentIdentifier = UUID().uuidString
    var historyDeletions = PersonalHistoryDeletionTracker()
    var historyContinuity = PersonalHistoryCaretContinuity()
    var defaults: UserDefaults = .standard
    var capture: PersonalHistoryCapture = .shared
    var isSecureEventInputEnabled: () -> Bool = { IsSecureEventInputEnabled() }
    var now: () -> Date = { Date() }

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event, event.type == .keyDown, let client = sender as? IMKTextInput else {
            return false
        }

        // Fast-path consent check BEFORE any cross-process IMKTextInput IPC
        // (`client.bundleIdentifier()` / `selectedRange()`) so a disabled
        // keyboard adds zero IPC overhead on every keystroke.
        guard defaults.bool(forKey: PersonalHistorySettingsContract.enabledKey) else {
            breakHistorySegment()
            return false
        }

        let secureInput = isSecureEventInputEnabled()
        if secureInput {
            capture.sensitiveInputBegan()
            breakHistorySegment()
            return false
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if modifiers.contains(.command)
            || modifiers.contains(.control)
            || modifiers.contains(.function)
            || modifiers.contains(.option) {
            breakHistorySegment()
            return false
        }

        let paused = PersonalHistorySettingsContract.isPaused(
            pausedUntil: defaults.double(forKey: PersonalHistorySettingsContract.pausedUntilKey),
            now: now()
        )
        if paused {
            breakHistorySegment()
            return false
        }

        if let typedGrapheme = Self.printableGrapheme(from: event) {
            captureWriting(typedGrapheme, client: client, secureInput: secureInput)
        } else if event.keyCode == 51 {
            noteHistoryBackspace(client, secureInput: secureInput)
        } else {
            breakHistorySegment()
        }

        return false
    }

    override func commitComposition(_ sender: Any!) {
        breakHistorySegment()
    }

    override func deactivateServer(_ sender: Any!) {
        capture.flush()
        breakHistorySegment()
        super.deactivateServer(sender)
    }

    // MARK: - Capture helpers

    static func printableGrapheme(from event: NSEvent) -> String? {
        guard let characters = event.characters, characters.count == 1 else { return nil }
        guard characters.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else {
            return nil
        }
        return characters
    }

    private func captureWriting(
        _ text: String,
        client: IMKTextInput,
        secureInput: Bool
    ) {
        let bundle = client.bundleIdentifier()
        guard let permit = capture.permit(
            appBundleIdentifier: bundle,
            secureInput: secureInput
        ) else {
            breakHistorySegment()
            return
        }
        let observation = InsertionObservation(
            bundle: permit.appBundleIdentifier,
            selection: client.selectedRange()
        )
        guard prepareHistoryInsertion(text, observation: observation) else { return }
        capture.record(
            text: text,
            source: .typed,
            sessionIdentifier: historySegmentIdentifier,
            permit: permit
        )
        historyDeletions.inserted(text)
    }

    private func prepareHistoryInsertion(
        _ text: String,
        observation: InsertionObservation
    ) -> Bool {
        switch historyContinuity.insertion(
            bundle: observation.bundle,
            selection: observation.selection,
            utf16Length: text.utf16.count
        ) {
        case .continues:
            return true
        case .breaks:
            let kept = historyContinuity
            breakHistorySegment()
            historyContinuity = kept
            return true
        case .unusable:
            breakHistorySegment()
            return false
        }
    }

    private func noteHistoryBackspace(
        _ client: IMKTextInput,
        secureInput: Bool
    ) {
        guard historyContinuity.isTracking, historyDeletions.hasTrackedText else {
            breakHistorySegment()
            return
        }
        let observation = InsertionObservation(
            bundle: client.bundleIdentifier() ?? "",
            selection: client.selectedRange()
        )
        guard historyContinuity.isAtOwnTextEnd(bundle: observation.bundle, selection: observation.selection),
              let permit = capture.permit(
                appBundleIdentifier: observation.bundle,
                secureInput: secureInput
              ),
              let backspace = historyDeletions.backspace() else {
            breakHistorySegment()
            return
        }
        if backspace.rotatesSegment {
            historySegmentIdentifier = PersonalHistorySegmentChain.continuation(
                of: historySegmentIdentifier
            )
        }
        historyContinuity.backspaced(utf16Length: backspace.utf16Length, caret: observation.selection.location)
        capture.recordDeletion(
            utf16Length: backspace.utf16Length,
            sessionIdentifier: historySegmentIdentifier,
            permit: permit
        )
    }

    private func breakHistorySegment() {
        historySegmentIdentifier = UUID().uuidString
        historyDeletions.reset()
        historyContinuity.reset()
    }
}
