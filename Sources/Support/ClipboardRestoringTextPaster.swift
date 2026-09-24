// ClipboardRestoringTextPaster.swift
// Pastes text into the current target app by borrowing the clipboard briefly
// and restoring the prior clipboard contents after the target reads the text.

import AppKit
import ApplicationServices
import Carbon
import Foundation
#if canImport(TranscriptedCore)
import TranscriptedCore
#endif

private enum ClipboardPasteConfirmationWaitResult: Equatable {
    case confirmed
    case unconfirmed
    case focusChanged
    case cancelled
}

enum TextPasteCopyReason: Equatable {
    case accessibilityMissing
    case pasteEventCreationFailed
    case focusChanged
    case pasteNotConfirmed
}

enum TextPasteFailureReason: String, Equatable {
    case cancelled = "cancelled"
    case clipboardSnapshotIncomplete = "clipboard_snapshot_incomplete"
    case focusChangeClipboardWriteFailed = "focus_change_clipboard_write_failed"
    case accessibilityFallbackClipboardWriteFailed = "accessibility_fallback_clipboard_write_failed"
    case temporaryClipboardWriteFailed = "temporary_clipboard_write_failed"
    case pasteDispatchClipboardRecoveryFailed = "paste_dispatch_clipboard_recovery_failed"
    case fallbackClipboardRecoveryUnverified = "fallback_clipboard_recovery_unverified"
    case unknown
}

enum TextPasteOutcome: Equatable {
    case pasted
    /// Cmd+V went out, the target stayed frontmost, and the borrowed clipboard
    /// was read right after it, but no Accessibility signal proved the text
    /// landed. Electron apps, Chrome text areas, and GPU terminals expose no
    /// such signal, so this is what a normal paste into them looks like. The
    /// user's clipboard is restored as after `.pasted`. The read is not
    /// attributed to the target process, so this never authorizes Auto Enter.
    case likelyPasted
    case copied(String, reason: TextPasteCopyReason)
    case failed(String, reason: TextPasteFailureReason)

    var diagnosticName: String {
        switch self {
        case .pasted:
            return "pasted"
        case .likelyPasted:
            return "likely_pasted"
        case .copied:
            return "copied"
        case .failed:
            return "failed"
        }
    }

    var diagnosticMessage: String {
        switch self {
        case .pasted:
            return "Dictation pasted successfully"
        case .likelyPasted:
            return "Dictation most likely pasted: the target read the clipboard right after Cmd+V"
        case .copied(let message, reason: _), .failed(let message, reason: _):
            return message
        }
    }

    var copyReason: TextPasteCopyReason? {
        switch self {
        case .copied(_, reason: let reason):
            return reason
        case .pasted, .likelyPasted, .failed:
            return nil
        }
    }

    var failureReason: TextPasteFailureReason? {
        switch self {
        case .failed(_, reason: let reason):
            return reason
        case .pasted, .likelyPasted, .copied:
            return nil
        }
    }
}

struct ClipboardPasteConfirmationDiagnostic: Equatable {
    let event: String
    let context: [String: String]
}

struct ClipboardPasteTiming: Equatable {
    let startedAt: CFAbsoluteTime
    let dispatchStartedAt: CFAbsoluteTime?
    let dispatchFinishedAt: CFAbsoluteTime?
    let clipboardReadAt: CFAbsoluteTime?
    let confirmationStartedAt: CFAbsoluteTime?
    let confirmationFinishedAt: CFAbsoluteTime?
    var accessibilityCaptureMS: Int? = nil
    var clipboardSnapshotMS: Int? = nil

    func measurements() -> [String: Int] {
        var values: [String: Int] = [:]
        values["paste_ax_capture_ms"] = accessibilityCaptureMS
        values["paste_clipboard_snapshot_ms"] = clipboardSnapshotMS
        values["paste_prepare_ms"] = milliseconds(from: startedAt, to: dispatchStartedAt)
        values["paste_dispatch_ms"] = milliseconds(from: dispatchStartedAt, to: dispatchFinishedAt)
        if let dispatchStartedAt,
           let clipboardReadAt,
           clipboardReadAt >= dispatchStartedAt {
            values["paste_clipboard_read_ms"] = milliseconds(
                from: dispatchStartedAt,
                to: clipboardReadAt
            )
        }
        values["paste_confirmation_wait_ms"] = milliseconds(
            from: confirmationStartedAt,
            to: confirmationFinishedAt
        )
        return values
    }

    private func milliseconds(from start: CFAbsoluteTime?, to end: CFAbsoluteTime?) -> Int? {
        guard let start, let end else { return nil }
        return max(0, Int(((end - start) * 1_000).rounded()))
    }
}

enum DictationTargetConfirmationMode: String, Equatable {
    case textValue = "text_value"
    case selectionRange = "selection_range"
    case changeNotification = "change_notification"
    /// No Accessibility confirmation, but the target stayed frontmost and the
    /// borrowed clipboard was read right after Cmd+V (`.likelyPasted`).
    case clipboardRead = "clipboard_read"
    case none

    static func resolve(
        outcome: TextPasteOutcome,
        diagnostic: ClipboardPasteConfirmationDiagnostic?
    ) -> DictationTargetConfirmationMode {
        if outcome == .likelyPasted {
            return .clipboardRead
        }
        guard diagnostic?.event == "dictation_paste_confirmed" else {
            return .none
        }
        switch diagnostic?.context["confirmation_mode"] {
        case "text_value":
            return .textValue
        case "selection_range":
            return .selectionRange
        case "target_change_notification":
            return .changeNotification
        default:
            return .none
        }
    }
}

@MainActor
protocol ClipboardPasteboard: AnyObject {
    var changeCount: Int { get }
    var pasteboardItems: [NSPasteboardItem]? { get }

    @discardableResult
    func clearContents() -> Int

    @discardableResult
    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool

    func string(forType dataType: NSPasteboard.PasteboardType) -> String?

    @discardableResult
    func writePasteboardItems(_ items: [NSPasteboardItem]) -> Bool
}

extension NSPasteboard: ClipboardPasteboard {
    @discardableResult
    func writePasteboardItems(_ items: [NSPasteboardItem]) -> Bool {
        writeObjects(items)
    }
}

private func postClipboardPasteShortcut() -> Bool {
    let pasteKeyCode = currentPasteShortcutKeyCode()
    guard let vDown = CGEvent(keyboardEventSource: nil, virtualKey: pasteKeyCode, keyDown: true),
          let vUp = CGEvent(keyboardEventSource: nil, virtualKey: pasteKeyCode, keyDown: false) else {
        return false
    }

    vDown.flags = .maskCommand
    vDown.post(tap: .cghidEventTap)

    vUp.flags = .maskCommand
    vUp.post(tap: .cghidEventTap)

    return true
}

private func currentPasteShortcutKeyCode() -> CGKeyCode {
    resolveCurrentKeyboardLayoutKeyCode(for: "v") ?? CGKeyCode(kVK_ANSI_V)
}

private func resolveCurrentKeyboardLayoutKeyCode(for targetCharacter: Character) -> CGKeyCode? {
    guard let inputSource = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
          let layoutProperty = TISGetInputSourceProperty(inputSource, kTISPropertyUnicodeKeyLayoutData) else {
        return nil
    }

    let layoutData = unsafeBitCast(layoutProperty, to: CFData.self)
    guard let layoutBytes = CFDataGetBytePtr(layoutData) else { return nil }
    let keyboardLayout = UnsafeRawPointer(layoutBytes).assumingMemoryBound(to: UCKeyboardLayout.self)
    let target = String(targetCharacter).lowercased()

    for keyCode in UInt16(0)..<UInt16(128) {
        var deadKeyState: UInt32 = 0
        var actualLength = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(
            keyboardLayout,
            keyCode,
            UInt16(kUCKeyActionDown),
            0,
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            characters.count,
            &actualLength,
            &characters
        )
        guard status == noErr, actualLength > 0 else { continue }
        let produced = String(utf16CodeUnits: characters, count: actualLength).lowercased()
        if produced == target {
            return CGKeyCode(keyCode)
        }
    }

    return nil
}

enum ClipboardTargetActivationPolicy {
    /// Pure wait decision used by `waitForTargetActivation`: keep waiting only while the
    /// target is not yet frontmost AND the elapsed time has not reached the timeout.
    static func shouldWait(targetIsFrontmost: Bool, elapsed: TimeInterval, timeout: TimeInterval) -> Bool {
        guard !targetIsFrontmost else { return false }
        return elapsed < timeout
    }
}

struct DictationPasteTarget: Equatable {
    let processIdentifier: pid_t?
    let bundleIdentifier: String?

    static func capture(sourceApp: NSRunningApplication?) -> DictationPasteTarget? {
        guard let sourceApp else { return nil }
        return DictationPasteTarget(
            processIdentifier: sourceApp.processIdentifier,
            bundleIdentifier: sourceApp.bundleIdentifier
        )
    }

    static func preferredDestination(
        frontmostProcessIdentifier: pid_t?,
        frontmostBundleIdentifier: String?,
        transcriptedBundleIdentifier: String?,
        fallback: DictationPasteTarget?
    ) -> DictationPasteTarget? {
        guard let frontmostProcessIdentifier,
              let frontmostBundleIdentifier,
              frontmostBundleIdentifier != transcriptedBundleIdentifier else {
            return fallback
        }
        return DictationPasteTarget(
            processIdentifier: frontmostProcessIdentifier,
            bundleIdentifier: frontmostBundleIdentifier
        )
    }

    func matchesCurrentFrontmostApp() -> Bool {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication else {
            return false
        }
        return matches(
            processIdentifier: frontmostApp.processIdentifier,
            bundleIdentifier: frontmostApp.bundleIdentifier
        )
    }

    func matches(processIdentifier currentProcessIdentifier: pid_t?, bundleIdentifier currentBundleIdentifier: String?) -> Bool {
        if let processIdentifier, let currentProcessIdentifier {
            return processIdentifier == currentProcessIdentifier
        }
        if let bundleIdentifier, let currentBundleIdentifier {
            return bundleIdentifier == currentBundleIdentifier
        }
        return false
    }
}

enum FocusedTextPasteConfirmationPolicy {
    struct SelectionRange: Equatable {
        let location: Int
        let length: Int
    }

    static func observableString(from value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let attributedString = value as? NSAttributedString {
            return attributedString.string
        }
        return nil
    }

    static func didObservePaste(
        initialValue: String?,
        currentValue: String?,
        pastedText: String,
        replacedSelectionLength: Int = 0
    ) -> Bool {
        guard let initialValue,
              let currentValue,
              currentValue != initialValue,
              !pastedText.isEmpty else {
            return false
        }

        let normalizedInitial = normalizedForConfirmation(initialValue)
        let normalizedCurrent = normalizedForConfirmation(currentValue)
        let normalizedPaste = normalizedForConfirmation(pastedText)
        if !normalizedPaste.isEmpty,
           !normalizedInitial.contains(normalizedPaste),
           normalizedCurrent.contains(normalizedPaste) {
            return true
        }

        let expectedLengthChange = pastedText.utf16.count - max(0, replacedSelectionLength)
        let observedLengthChange = currentValue.utf16.count - initialValue.utf16.count
        let tolerance = max(2, pastedText.utf16.count / 20)
        return abs(observedLengthChange - expectedLengthChange) <= tolerance
    }

    static func didObserveSelectionPaste(
        initialRange: SelectionRange?,
        currentRange: SelectionRange?,
        pastedText: String,
        clipboardWasRead: Bool
    ) -> Bool {
        guard clipboardWasRead,
              let initialRange,
              let currentRange,
              !pastedText.isEmpty,
              currentRange.length == 0 else {
            return false
        }

        let expectedCursorLocation = initialRange.location + pastedText.utf16.count
        let tolerance = max(2, pastedText.utf16.count / 20)
        return abs(currentRange.location - expectedCursorLocation) <= tolerance
    }

    static func didObserveTargetChange(
        pasteDispatchedAt: CFAbsoluteTime,
        clipboardReadAt: CFAbsoluteTime?,
        targetChangedAt: CFAbsoluteTime?
    ) -> Bool {
        guard let clipboardReadAt,
              let targetChangedAt,
              clipboardReadAt >= pasteDispatchedAt,
              targetChangedAt >= clipboardReadAt else {
            return false
        }
        return targetChangedAt - clipboardReadAt <= 1.0
    }

    /// The borrowed clipboard is a lazy provider, so its first read after Cmd+V
    /// is almost always the frontmost target's own paste handler. That is not
    /// proof (the read is not tied to a process), but a frontmost target that
    /// reads within `window` most likely pasted. A read long after it looks
    /// like a clipboard manager and does not count. Reads from other apps are
    /// served (and stamped) on our main run loop, which does not spin between
    /// writing the clipboard and Cmd+V, so the "before Cmd+V" case mostly
    /// catches same-process reads; the TransientType marker is what keeps
    /// well-behaved clipboard managers from reading at all.
    static func didObserveLikelyPaste(
        pasteDispatchedAt: CFAbsoluteTime,
        clipboardReadAt: CFAbsoluteTime?,
        window: TimeInterval = TranscriptedConstants.clipboardLikelyPasteReadWindow
    ) -> Bool {
        guard let clipboardReadAt, clipboardReadAt >= pasteDispatchedAt else {
            return false
        }
        return clipboardReadAt - pasteDispatchedAt <= window
    }

    private static func normalizedForConfirmation(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
            .replacingOccurrences(of: "\u{2018}", with: "'")
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"")
            .replacingOccurrences(of: "\u{201D}", with: "\"")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

private func focusedTextChangeObserverCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let tracker = Unmanaged<FocusedTextChangeObserver>.fromOpaque(refcon).takeUnretainedValue()
    tracker.recordChange()
}

private final class FocusedTextChangeObserver {
    private let focusedElement: AXUIElement
    private let lock = NSLock()
    private var observer: AXObserver?
    private var monitoredNotifications: [CFString] = []
    private var latestChangeTimestamp: CFAbsoluteTime?

    var changedAt: CFAbsoluteTime? {
        lock.lock()
        let value = latestChangeTimestamp
        lock.unlock()
        return value
    }

    private init(focusedElement: AXUIElement) {
        self.focusedElement = focusedElement
    }

    static func start(for focusedElement: AXUIElement) -> FocusedTextChangeObserver? {
        let tracker = FocusedTextChangeObserver(focusedElement: focusedElement)
        return tracker.install() ? tracker : nil
    }

    fileprivate func recordChange() {
        lock.lock()
        latestChangeTimestamp = CFAbsoluteTimeGetCurrent()
        lock.unlock()
    }

    private func install() -> Bool {
        var processIdentifier: pid_t = 0
        guard AXUIElementGetPid(focusedElement, &processIdentifier) == .success else {
            return false
        }

        var createdObserver: AXObserver?
        guard AXObserverCreate(
            processIdentifier,
            focusedTextChangeObserverCallback,
            &createdObserver
        ) == .success,
              let createdObserver else {
            return false
        }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in [kAXValueChangedNotification, kAXSelectedTextChangedNotification] {
            if AXObserverAddNotification(
                createdObserver,
                focusedElement,
                notification as CFString,
                refcon
            ) == .success {
                monitoredNotifications.append(notification as CFString)
            }
        }
        guard !monitoredNotifications.isEmpty else { return false }

        observer = createdObserver
        CFRunLoopAddSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(createdObserver),
            .commonModes
        )
        return true
    }

    deinit {
        guard let observer else { return }
        for notification in monitoredNotifications {
            AXObserverRemoveNotification(observer, focusedElement, notification)
        }
        CFRunLoopRemoveSource(
            CFRunLoopGetMain(),
            AXObserverGetRunLoopSource(observer),
            .commonModes
        )
    }
}

private struct FocusedTextPasteConfirmation {
    /// Accessibility clients can otherwise block for several seconds when an editor is
    /// briefly busy applying a paste (Notes is a common example). Confirmation is a
    /// best-effort signal and must never stall delivery or the target application.
    private static let messagingTimeout: Float = 0.05

    private let focusedElement: AXUIElement
    private let initialValue: String?
    private let replacedSelectionLength: Int
    private let initialSelectionRange: FocusedTextPasteConfirmationPolicy.SelectionRange?
    private let changeObserver: FocusedTextChangeObserver?

    var canObservePaste: Bool {
        initialValue != nil || initialSelectionRange != nil || changeObserver != nil
    }

    static func capture() -> FocusedTextPasteConfirmation? {
        let systemWideElement = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWideElement, messagingTimeout)
        var focusedElementValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElementValue
        ) == .success,
            let focusedElement = focusedElementValue else {
            return nil
        }

        // AXUIElement is a toll-free-bridged CF opaque type: Swift can't runtime-check
        // `as?`/`as!` against it (the compiler treats the downcast as unconditionally
        // successful), so CFGetTypeID is the actual safety net before we hand this
        // value to AX APIs that assume it really is an AXUIElement. This file is
        // compiled directly into the fast-test binary without the TranscriptedCore
        // module's search path (see APP_SOURCES in run-tests.sh), so importing that
        // module here isn't an option — this follows the same fputs(..., stderr)
        // idiom Sources/Observability/AppLogSink.swift itself falls back to for
        // internal diagnostics.
        guard CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else {
            fputs("⚠️ ClipboardRestoringTextPaster | focused UI element attribute returned an unexpected CF type (expected AXUIElement)\n", stderr)
            return nil
        }
        let element = focusedElement as! AXUIElement
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        return FocusedTextPasteConfirmation(
            focusedElement: element,
            initialValue: stringAttribute(kAXValueAttribute as CFString, from: element),
            replacedSelectionLength: stringAttribute(kAXSelectedTextAttribute as CFString, from: element)?.utf16.count ?? 0,
            initialSelectionRange: selectionRangeAttribute(from: element),
            changeObserver: FocusedTextChangeObserver.start(for: element)
        )
    }

    func confirmationMode(
        _ text: String,
        clipboardWasRead: Bool,
        clipboardReadAt: CFAbsoluteTime?,
        pasteDispatchedAt: CFAbsoluteTime
    ) -> String? {
        if FocusedTextPasteConfirmationPolicy.didObservePaste(
            initialValue: initialValue,
            currentValue: Self.stringAttribute(kAXValueAttribute as CFString, from: focusedElement),
            pastedText: text,
            replacedSelectionLength: replacedSelectionLength
        ) {
            return "text_value"
        }
        if FocusedTextPasteConfirmationPolicy.didObserveSelectionPaste(
            initialRange: initialSelectionRange,
            currentRange: Self.selectionRangeAttribute(from: focusedElement),
            pastedText: text,
            clipboardWasRead: clipboardWasRead
        ) {
            return "selection_range"
        }
        if FocusedTextPasteConfirmationPolicy.didObserveTargetChange(
            pasteDispatchedAt: pasteDispatchedAt,
            clipboardReadAt: clipboardReadAt,
            targetChangedAt: changeObserver?.changedAt
        ) {
            return "target_change_notification"
        }
        return nil
    }

    // Key names here must not contain any sensitive-key fragment from
    // PayloadSanitizationCore (e.g. "text", "name") or the local sanitizer
    // blanks the boolean to "[redacted-sensitive-value]" in events.jsonl.
    // "target_value_observable" reports whether kAXValueAttribute was readable.
    func diagnosticsContext(
        clipboardReadAt: CFAbsoluteTime?,
        pasteDispatchedAt: CFAbsoluteTime
    ) -> [String: String] {
        [
            "clipboard_read_after_dispatch": "\((clipboardReadAt ?? 0) >= pasteDispatchedAt)",
            "target_change_after_dispatch": "\((changeObserver?.changedAt ?? 0) >= pasteDispatchedAt)",
            "target_change_observer_available": "\(changeObserver != nil)",
            "target_selection_observable": "\(initialSelectionRange != nil)",
            "target_value_observable": "\(initialValue != nil)",
        ]
    }

    private static func stringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return FocusedTextPasteConfirmationPolicy.observableString(from: value)
    }

    private static func selectionRangeAttribute(
        from element: AXUIElement
    ) -> FocusedTextPasteConfirmationPolicy.SelectionRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let axValue = value as! AXValue
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range),
              range.location >= 0,
              range.length >= 0 else {
            return nil
        }
        return FocusedTextPasteConfirmationPolicy.SelectionRange(
            location: range.location,
            length: range.length
        )
    }
}

@MainActor
protocol ClipboardPasteConfirmationSource {
    var canObservePaste: Bool { get }

    func confirmationMode(
        _ text: String,
        clipboardWasRead: Bool,
        clipboardReadAt: CFAbsoluteTime?,
        pasteDispatchedAt: CFAbsoluteTime
    ) -> String?

    func diagnosticsContext(
        clipboardReadAt: CFAbsoluteTime?,
        pasteDispatchedAt: CFAbsoluteTime
    ) -> [String: String]
}

extension FocusedTextPasteConfirmation: ClipboardPasteConfirmationSource {}

@MainActor
final class ClipboardRestoringTextPaster {
    struct PasteboardSnapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
        let isComplete: Bool
        /// True when any item carried an nspasteboard.org privacy marker
        /// (a password manager's concealed copy, a transient or auto-generated
        /// item). Such a clipboard is restored right after a paste as before,
        /// but never held on to for later.
        var containsPrivacyMarker = false
    }

    /// nspasteboard.org markers that say "don't keep this". Apps usually write
    /// them with empty data, so snapshots keep them even when empty.
    nonisolated static let privacyMarkerTypes: Set<NSPasteboard.PasteboardType> = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType"),
    ]

    private struct PendingClipboardRestore {
        let savedItems: PasteboardSnapshot
        let temporaryString: String
        let temporaryChangeCount: Int
        let pasteboard: any ClipboardPasteboard
    }

    private enum ClipboardFallbackState: String {
        case dictationPresent = "dictation_present"
        case clipboardChanged = "clipboard_changed"
        case clipboardEmpty = "clipboard_empty"
        case unavailable

        var hasVerifiedDictation: Bool {
            self == .dictationPresent
        }
    }

    private static let unverifiedClipboardRecoveryFailure =
        "Transcripted sent paste, but could not confirm it or place a recovery copy on the clipboard. Check your dictation history."

    /// Shown when nothing suggested the paste landed. A slow target can still
    /// paste after the wait (the text stays on the clipboard), so this must not
    /// claim the paste failed: pressing ⌘V after a paste that did land would
    /// paste the text twice.
    nonisolated static let pasteNotConfirmedMessage =
        "Couldn't confirm the paste. If the text isn't there, press ⌘V."

    /// nspasteboard.org marker for data an app puts on the clipboard only for a
    /// moment, like a paste done through Cmd+V. Clipboard managers skip items
    /// that carry it, so they neither record the dictation nor read it while it
    /// is borrowed (a read that would look like the target pasting).
    nonisolated static let transientPasteboardType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    private var clipboardRestoreTask: Task<Void, Never>?
    private var clipboardAutoEnterReadinessTask: Task<Void, Never>?
    private var clipboardAutoEnterReadyToken: SupersessionEpoch.Token?
    private var pendingClipboardRestore = ClaimSlot<PendingClipboardRestore>()
    private var retainedClipboardRestoreForPasteRetry: PendingClipboardRestore?
    /// The user's clipboard from before a paste that fell back to "press ⌘V".
    /// The fallback copy stays on the clipboard for the user; this puts their
    /// own clipboard back when the next paste starts, but only if the clipboard
    /// still holds exactly that fallback copy. Cancelling or dismissing a
    /// fallback never restores it on its own, so the recovery text stays put
    /// until the user starts another paste. Shared by every paster (dictation,
    /// Paste Last, the menu bar) because they all borrow the same clipboard:
    /// a Paste Last right after a fallback must still give it back.
    private static var clipboardSavedBeforeFallback: (restore: PendingClipboardRestore, savedAt: CFAbsoluteTime)?
    private var temporaryPasteboardDataProvider: TemporaryPasteboardStringProvider?
    /// Epoch — begun per paste attempt, invalidated whenever the pending restore
    /// is cleared, superseded when a scheduled restore completes
    private var pasteEpoch = SupersessionEpoch()
    private var operationEpoch = SupersessionEpoch()
    private var latestStartedOperation: SupersessionEpoch.Token?
    private(set) var lastConfirmationDiagnostic: ClipboardPasteConfirmationDiagnostic?
    private(set) var lastPasteTiming: ClipboardPasteTiming?

    deinit {
        clipboardRestoreTask?.cancel()
        clipboardAutoEnterReadinessTask?.cancel()
    }

    func cancelPendingClipboardRestore() {
        restorePendingClipboardNow()
        restoreRetainedClipboardNow()
    }

    func discardPasteRetry() {
        restoreRetainedClipboardNow()
    }

    func restorePendingClipboardNow() {
        operationEpoch.invalidate()
        restorePendingClipboard()
    }

    private func restorePendingClipboard() {
        guard let pending = clearPendingClipboardRestore() else { return }
        restorePasteboardItems(
            pending.savedItems,
            temporaryString: pending.temporaryString,
            temporaryChangeCount: pending.temporaryChangeCount,
            to: pending.pasteboard
        )
    }

    func waitForPendingClipboardRestore() async {
        while let clipboardRestoreTask {
            await clipboardRestoreTask.value
        }
    }

    func waitForClipboardReadyForAutoEnter() async {
        while let readinessTask = clipboardAutoEnterReadinessTask {
            await readinessTask.value
        }
        if let readyToken = clipboardAutoEnterReadyToken, pasteEpoch.isCurrent(readyToken) {
            return
        }
        await waitForPendingClipboardRestore()
    }

    func paste(
        _ text: String,
        target: DictationPasteTarget? = nil,
        activationWait: TimeInterval = TranscriptedConstants.clipboardTargetActivationWait,
        pasteboard: any ClipboardPasteboard = NSPasteboard.general,
        accessibilityTrusted: () -> Bool = { AXIsProcessTrusted() },
        requestAccessibilityTrust: () -> Void = {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        },
        pasteDispatcher: @MainActor () -> Bool = postClipboardPasteShortcut,
        confirmationSource: (@MainActor () -> (any ClipboardPasteConfirmationSource)?)? = nil,
        pasteConfirmed: (@MainActor () -> Bool)? = nil,
        targetIsFrontmost: (@MainActor () -> Bool)? = nil,
        retainClipboardForPasteRetry: Bool = true,
        restoreDelay: UInt64 = TranscriptedConstants.clipboardRestoreDelay,
        fallbackRestoreDelay: UInt64 = TranscriptedConstants.clipboardRestoreFallbackDelay,
        pasteConfirmationWait: TimeInterval = TranscriptedConstants.clipboardPasteConfirmationWait
    ) -> TextPasteOutcome {
        let operation = operationEpoch.begin()
        latestStartedOperation = operation
        let isCurrentOperation = { self.operationEpoch.isCurrent(operation) }
        let cancelledOutcome = TextPasteOutcome.failed("Paste was cancelled.", reason: .cancelled)
        lastConfirmationDiagnostic = nil
        lastPasteTiming = nil
        let timingStartedAt = CFAbsoluteTimeGetCurrent()
        var timingDispatchStartedAt: CFAbsoluteTime?
        var timingDispatchFinishedAt: CFAbsoluteTime?
        var timingConfirmationStartedAt: CFAbsoluteTime?
        var timingConfirmationFinishedAt: CFAbsoluteTime?
        var timingProvider: TemporaryPasteboardStringProvider?
        var accessibilityCaptureMS: Int?
        var clipboardSnapshotMS: Int?
        defer {
            if isCurrentOperation() {
                lastPasteTiming = ClipboardPasteTiming(
                    startedAt: timingStartedAt,
                    dispatchStartedAt: timingDispatchStartedAt,
                    dispatchFinishedAt: timingDispatchFinishedAt,
                    clipboardReadAt: timingProvider?.firstReadAt,
                    confirmationStartedAt: timingConfirmationStartedAt,
                    confirmationFinishedAt: timingConfirmationFinishedAt,
                    accessibilityCaptureMS: accessibilityCaptureMS,
                    clipboardSnapshotMS: clipboardSnapshotMS
                )
            }
        }
        discardPasteRetry()
        guard isCurrentOperation() else { return cancelledOutcome }
        restorePendingClipboard()
        guard isCurrentOperation() else { return cancelledOutcome }
        // Starting another paste means the user moved on from the last
        // fallback copy, so give them their own clipboard back first. This
        // paste then snapshots and restores it like any other clipboard. The
        // dictated text from the fallback stays in dictation history.
        restoreClipboardSavedBeforeFallback(on: pasteboard)
        guard isCurrentOperation() else { return cancelledOutcome }

        if let target,
           !target.matchesCurrentFrontmostApp(),
           !waitForTargetActivation(target, timeout: activationWait, isCurrentOperation: isCurrentOperation) {
            guard isCurrentOperation() else { return cancelledOutcome }
            let copied = copyTextForManualPaste(text, to: pasteboard, isCurrentOperation: isCurrentOperation)
            guard isCurrentOperation() else { return cancelledOutcome }
            guard copied else {
                return .failed(
                    "Focus moved, and Transcripted couldn't put the text on your clipboard. It's still saved in your dictation history.",
                    reason: .focusChangeClipboardWriteFailed
                )
            }
            guard isCurrentOperation() else { return cancelledOutcome }
            return .copied(
                "Focus moved before the text could paste. It's on your clipboard — press ⌘V to paste it.",
                reason: .focusChanged
            )
        }

        guard isCurrentOperation() else { return cancelledOutcome }
        let trusted = accessibilityTrusted()
        guard isCurrentOperation() else { return cancelledOutcome }
        guard trusted else {
            requestAccessibilityTrust()
            guard isCurrentOperation() else { return cancelledOutcome }
            let copied = copyTextForManualPaste(text, to: pasteboard, isCurrentOperation: isCurrentOperation)
            guard isCurrentOperation() else { return cancelledOutcome }
            guard copied else {
                return .failed(
                    "Accessibility is off, and Transcripted couldn't put the text on your clipboard. It's still saved in your dictation history.",
                    reason: .accessibilityFallbackClipboardWriteFailed
                )
            }
            guard isCurrentOperation() else { return cancelledOutcome }
            return .copied(
                "Accessibility is off, so Transcripted can't paste for you. Your text is on the clipboard — press ⌘V.",
                reason: .accessibilityMissing
            )
        }

        let accessibilityStartedAt = CFAbsoluteTimeGetCurrent()
        let accessibilityConfirmation = confirmationSource?() ?? FocusedTextPasteConfirmation.capture()
        accessibilityCaptureMS = max(0, Int(((CFAbsoluteTimeGetCurrent() - accessibilityStartedAt) * 1_000).rounded()))
        guard isCurrentOperation() else { return cancelledOutcome }
        let snapshotStartedAt = CFAbsoluteTimeGetCurrent()
        let snapshotChangeCount = pasteboard.changeCount
        let savedItems = snapshotPasteboardItems(from: pasteboard)
        clipboardSnapshotMS = max(0, Int(((CFAbsoluteTimeGetCurrent() - snapshotStartedAt) * 1_000).rounded()))
        // Lazy clipboard providers can run while materializing a snapshot. Do
        // not overwrite a newer clipboard with an older restore snapshot.
        guard isCurrentOperation() else { return cancelledOutcome }
        guard savedItems.isComplete, pasteboard.changeCount == snapshotChangeCount else {
            return .failed(
                "Couldn't paste automatically without risking your current clipboard. The dictation was saved, but paste-back did not run.",
                reason: .clipboardSnapshotIncomplete
            )
        }
        let pasteToken = pasteEpoch.begin()
        var temporaryChangeCount = 0
        var restoreInstalled = false
        var clearedChangeCount: Int?
        defer {
            // Cancellation can arrive from a provider while the initial write
            // is still in progress, before a pending restore can be installed.
            // Roll back that borrowed clipboard, never a newer paste attempt.
            if !restoreInstalled, latestStartedOperation == operation {
                let observedCount = pasteboard.changeCount
                let currentString = pasteboard.string(forType: .string)
                if currentString == text || (currentString == nil && observedCount == clearedChangeCount) {
                    restoreClipboardSnapshot(savedItems, matching: currentString,
                        changeCount: observedCount, to: pasteboard)
                }
                if latestStartedOperation == operation {
                    temporaryPasteboardDataProvider = nil
                }
            }
        }

        clearedChangeCount = pasteboard.clearContents()
        guard isCurrentOperation() else { return cancelledOutcome }
        let wroteTemporaryString = writeTemporaryString(text, to: pasteboard)
        guard isCurrentOperation() else { return cancelledOutcome }
        if !wroteTemporaryString {
            clearedChangeCount = pasteboard.clearContents()
            guard isCurrentOperation() else { return cancelledOutcome }
            let wroteFallback = pasteboard.setString(text, forType: .string)
            guard isCurrentOperation() else { return cancelledOutcome }
            guard wroteFallback, pasteboard.string(forType: .string) == text else {
                return .failed(
                    "Couldn't paste or copy the text automatically. It's still saved in your dictation history.",
                    reason: .temporaryClipboardWriteFailed
                )
            }
        }
        guard isCurrentOperation() else { return cancelledOutcome }
        temporaryChangeCount = pasteboard.changeCount
        let temporaryProvider = temporaryPasteboardDataProvider
        timingProvider = temporaryProvider

        scheduleClipboardRestore(
            savedItems,
            temporaryString: text,
            temporaryChangeCount: temporaryChangeCount,
            to: pasteboard,
            token: pasteToken,
            delay: fallbackRestoreDelay
        )
        restoreInstalled = true

        let pasteDispatchedAt = CFAbsoluteTimeGetCurrent()
        timingDispatchStartedAt = pasteDispatchedAt
        guard isCurrentOperation() else { return cancelledOutcome }
        let dispatched = pasteDispatcher()
        guard isCurrentOperation() else { return cancelledOutcome }
        guard dispatched else {
            timingDispatchFinishedAt = CFAbsoluteTimeGetCurrent()
            restorePendingClipboard()
            guard copyTextToClipboard(text, to: pasteboard) else {
                return .failed(
                    "Couldn't paste or copy the text automatically. It's still saved in your dictation history.",
                    reason: .pasteDispatchClipboardRecoveryFailed
                )
            }
            saveClipboardForNextPaste(savedItems, fallbackText: text, fallbackChangeCount: pasteboard.changeCount, pasteboard: pasteboard)
            guard isCurrentOperation() else { return cancelledOutcome }
            return .copied(
                "Couldn't paste automatically. Your text is on the clipboard — press ⌘V.",
                reason: .pasteEventCreationFailed
            )
        }
        timingDispatchFinishedAt = CFAbsoluteTimeGetCurrent()

        let confirmationUnavailable = pasteConfirmed == nil && accessibilityConfirmation?.canObservePaste != true
        let targetRemainsFrontmost = targetIsFrontmost ?? {
            target?.matchesCurrentFrontmostApp() != false
        }
        let confirmPasteReceived = pasteConfirmed ?? {
            if accessibilityConfirmation?.confirmationMode(
                text,
                clipboardWasRead: temporaryProvider?.didProvideData == true,
                clipboardReadAt: temporaryProvider?.firstReadAt,
                pasteDispatchedAt: pasteDispatchedAt
            ) != nil {
                return true
            }
            return false
        }
        // A target with no observable confirmation surface can never upgrade to a
        // confirmed paste inside this wait (no AX value, selection, or change
        // observer exists to fire), so once the target reads the borrowed
        // clipboard after Cmd+V the rest of the window is dead time. The read is
        // not process-attributed, so it may shorten the wait but can never prove
        // delivery or authorize Auto Enter.
        let stopWaitingAfterClipboardRead = {
            guard confirmationUnavailable,
                  let clipboardReadAt = temporaryProvider?.firstReadAt else {
                return false
            }
            return clipboardReadAt >= pasteDispatchedAt
        }

        timingConfirmationStartedAt = CFAbsoluteTimeGetCurrent()
        let pasteConfirmationResult = waitForPasteConfirmation(
            targetIsFrontmost: targetRemainsFrontmost,
            pasteConfirmed: confirmPasteReceived,
            stopWaitingUnconfirmed: stopWaitingAfterClipboardRead,
            isCurrentOperation: isCurrentOperation,
            timeout: pasteConfirmationWait
        )
        timingConfirmationFinishedAt = CFAbsoluteTimeGetCurrent()
        guard isCurrentOperation(), pasteConfirmationResult != .cancelled else { return cancelledOutcome }
        guard pasteConfirmationResult == .confirmed else {
            var diagnostics = accessibilityConfirmation?.diagnosticsContext(
                clipboardReadAt: temporaryProvider?.firstReadAt,
                pasteDispatchedAt: pasteDispatchedAt
            ) ?? [
                "clipboard_read_after_dispatch": "\((temporaryProvider?.firstReadAt ?? 0) >= pasteDispatchedAt)",
                "target_change_after_dispatch": "false",
                "target_change_observer_available": "false",
                "target_selection_observable": "false",
                "target_value_observable": "false",
            ]
            guard isCurrentOperation() else { return cancelledOutcome }
            let targetStillFrontmost = pasteConfirmationResult == .unconfirmed
            let clipboardReadSuggestsPaste = FocusedTextPasteConfirmationPolicy.didObserveLikelyPaste(
                pasteDispatchedAt: pasteDispatchedAt,
                clipboardReadAt: temporaryProvider?.firstReadAt
            )
            // Diagnostics only: the provider records just the first read, so a
            // read outside the window hides whether the target read it later.
            let clipboardReadOutsideWindow = !clipboardReadSuggestsPaste
                && temporaryProvider?.firstReadAt != nil
            diagnostics["target_still_frontmost"] = "\(targetStillFrontmost)"
            diagnostics["paste_evidence"] = targetStillFrontmost && clipboardReadSuggestsPaste
                ? "clipboard_read"
                : clipboardReadOutsideWindow ? "read_outside_window" : "none"
            lastConfirmationDiagnostic = ClipboardPasteConfirmationDiagnostic(
                event: "dictation_paste_confirmation_diagnostics",
                context: diagnostics
            )
            if !targetStillFrontmost {
                let clipboardFallbackState = leaveTemporaryClipboardAvailable(
                    savingClipboardForNextPaste: true
                )
                diagnostics["clipboard_fallback_state"] = clipboardFallbackState.rawValue
                lastConfirmationDiagnostic = ClipboardPasteConfirmationDiagnostic(
                    event: "dictation_paste_confirmation_diagnostics",
                    context: diagnostics
                )
                guard clipboardFallbackState.hasVerifiedDictation else {
                    return .failed(
                        Self.unverifiedClipboardRecoveryFailure,
                        reason: .fallbackClipboardRecoveryUnverified
                    )
                }
                guard isCurrentOperation() else { return cancelledOutcome }
                return .copied(
                    "Focus moved before Transcripted could confirm paste. The text is on your clipboard — press ⌘V.",
                    reason: .focusChanged
                )
            }

            // AX confirmation is positive-only, and Electron apps, Chrome text
            // areas, and GPU terminals never give it. When the target stayed in
            // front and the borrowed clipboard was read right after Cmd+V, the
            // paste almost certainly landed (#1703 measured 66 of 69 such
            // outcomes as real pastes), so treat it like one: no warning, and
            // the user's clipboard comes back. The read is not tied to a process,
            // so if something else read first, the target may still be reading:
            // wait the longer fallback delay, not the short one used after a
            // proven paste, before the old clipboard replaces the dictation.
            if clipboardReadSuggestsPaste {
                guard isCurrentOperation() else { return cancelledOutcome }
                scheduleClipboardRestore(
                    savedItems,
                    temporaryString: text,
                    temporaryChangeCount: temporaryChangeCount,
                    to: pasteboard,
                    token: pasteToken,
                    delay: fallbackRestoreDelay
                )
                return .likelyPasted
            }

            // No AX signal fired and nothing read the clipboard right after
            // Cmd+V. That is not proof either way: a slow target can still read
            // the plain copy after the wait. Keep the text copied for a manual
            // paste, word the notice so it doesn't invite a double paste, and
            // hold on to the user's clipboard so the next paste can put it back.
            let clipboardFallbackState = leaveTemporaryClipboardAvailable(
                savingClipboardForNextPaste: true
            )
            diagnostics["clipboard_fallback_state"] = clipboardFallbackState.rawValue
            lastConfirmationDiagnostic = ClipboardPasteConfirmationDiagnostic(
                event: "dictation_paste_confirmation_diagnostics",
                context: diagnostics
            )
            guard clipboardFallbackState.hasVerifiedDictation else {
                return .failed(
                    Self.unverifiedClipboardRecoveryFailure,
                    reason: .fallbackClipboardRecoveryUnverified
                )
            }
            guard isCurrentOperation() else { return cancelledOutcome }
            return .copied(Self.pasteNotConfirmedMessage, reason: .pasteNotConfirmed)
        }

        let confirmationMode: String
        if pasteConfirmed != nil {
            confirmationMode = "injected_confirmation"
        } else {
            confirmationMode = accessibilityConfirmation?.confirmationMode(
                text,
                clipboardWasRead: temporaryProvider?.didProvideData == true,
                clipboardReadAt: temporaryProvider?.firstReadAt,
                pasteDispatchedAt: pasteDispatchedAt
            ) ?? "unknown"
        }
        guard isCurrentOperation() else { return cancelledOutcome }
        lastConfirmationDiagnostic = ClipboardPasteConfirmationDiagnostic(
            event: "dictation_paste_confirmed",
            context: ["confirmation_mode": confirmationMode]
        )

        scheduleClipboardRestore(
            savedItems,
            temporaryString: text,
            temporaryChangeCount: temporaryChangeCount,
            to: pasteboard,
            token: pasteToken,
            delay: restoreDelay
        )
        return .pasted
    }

    /// Fences out every in-flight restore/readiness task, empties the pending
    /// slot, and returns whatever restore payload was stored so the caller can
    /// decide what to do with it.
    @discardableResult
    private func clearPendingClipboardRestore() -> PendingClipboardRestore? {
        pasteEpoch.invalidate()
        clipboardRestoreTask?.cancel()
        clipboardRestoreTask = nil
        clipboardAutoEnterReadinessTask?.cancel()
        clipboardAutoEnterReadinessTask = nil
        clipboardAutoEnterReadyToken = nil
        temporaryPasteboardDataProvider = nil
        return pendingClipboardRestore.clear()
    }

    private func leaveTemporaryClipboardAvailable(
        retainingRestoreForPasteRetry: Bool = false,
        savingClipboardForNextPaste: Bool = false
    ) -> ClipboardFallbackState {
        guard let pending = clearPendingClipboardRestore() else { return .unavailable }

        // A user copy with the same plain text can still carry rich data. Keep it
        // intact when the pasteboard changed after paste started, but only count
        // that as recovery when the dictation text is actually still present.
        // An unchanged pasteboard may still hold our lazy provider, so materialize
        // it before returning the text for manual recovery.
        if pending.pasteboard.changeCount != pending.temporaryChangeCount {
            let observedChangeCount = pending.pasteboard.changeCount
            let currentString = pending.pasteboard.string(forType: .string)
            // Clipboard managers may rewrite a lazy pasteboard while it is read.
            // Never classify text from one generation as belonging to another.
            guard pending.pasteboard.changeCount == observedChangeCount else {
                return .clipboardChanged
            }
            if let currentString {
                return currentString == pending.temporaryString
                    ? .dictationPresent
                    : .clipboardChanged
            }
            let currentItems = pending.pasteboard.pasteboardItems
            guard pending.pasteboard.changeCount == observedChangeCount else {
                return .clipboardChanged
            }
            guard currentItems?.isEmpty != false else {
                return .clipboardChanged
            }

            // A failed paste consumer can clear the temporary pasteboard without
            // replacing it. Recover only from that truly-empty state; never
            // overwrite a non-empty user or clipboard-manager change.
            guard copyTextToClipboard(pending.temporaryString, to: pending.pasteboard) else {
                return .clipboardEmpty
            }
            if savingClipboardForNextPaste {
                saveClipboardForNextPaste(pending)
            }
            return .dictationPresent
        }
        guard copyTextToClipboard(pending.temporaryString, to: pending.pasteboard) else {
            return .unavailable
        }
        if savingClipboardForNextPaste {
            saveClipboardForNextPaste(pending)
        }
        if retainingRestoreForPasteRetry {
            retainedClipboardRestoreForPasteRetry = PendingClipboardRestore(
                savedItems: pending.savedItems,
                temporaryString: pending.temporaryString,
                temporaryChangeCount: pending.pasteboard.changeCount,
                pasteboard: pending.pasteboard
            )
        }
        return .dictationPresent
    }

    /// Only called right after this paster itself wrote `pending.temporaryString`
    /// as a plain fallback copy. A same-text clipboard someone else wrote is a
    /// user or clipboard-manager copy and must never be restored over later.
    private func saveClipboardForNextPaste(_ pending: PendingClipboardRestore) {
        saveClipboardForNextPaste(
            pending.savedItems,
            fallbackText: pending.temporaryString,
            fallbackChangeCount: pending.pasteboard.changeCount,
            pasteboard: pending.pasteboard
        )
    }

    private func saveClipboardForNextPaste(
        _ savedItems: PasteboardSnapshot,
        fallbackText: String,
        fallbackChangeCount: Int,
        pasteboard: any ClipboardPasteboard
    ) {
        // A password manager's copy (or any item marked "don't keep") must not
        // come back later, so drop it here. Clearing also stops an older save
        // from outliving this newer fallback.
        guard savedItems.isComplete, !savedItems.containsPrivacyMarker else {
            Self.clipboardSavedBeforeFallback = nil
            return
        }
        Self.clipboardSavedBeforeFallback = (
            restore: PendingClipboardRestore(
                savedItems: savedItems,
                temporaryString: fallbackText,
                temporaryChangeCount: fallbackChangeCount,
                pasteboard: pasteboard
            ),
            savedAt: CFAbsoluteTimeGetCurrent()
        )
    }

    /// Puts back the clipboard saved before the last fallback copy, unless the
    /// clipboard changed since (the user copied something, or a clipboard
    /// manager rewrote it) or the save is too old to be what the user expects
    /// back. A changed clipboard is always left alone.
    private func restoreClipboardSavedBeforeFallback(on pasteboard: any ClipboardPasteboard) {
        guard let entry = Self.clipboardSavedBeforeFallback,
              Self.isSamePasteboard(entry.restore.pasteboard, pasteboard) else { return }
        Self.clipboardSavedBeforeFallback = nil
        guard CFAbsoluteTimeGetCurrent() - entry.savedAt
            <= TranscriptedConstants.clipboardSavedBeforeFallbackMaxAge else { return }
        let saved = entry.restore
        restoreClipboardSnapshot(
            saved.savedItems,
            matching: saved.temporaryString,
            changeCount: saved.temporaryChangeCount,
            to: saved.pasteboard
        )
    }

    /// NSPasteboard(name:) can hand back a new object for the same system
    /// pasteboard, so match real pasteboards by name.
    private static func isSamePasteboard(
        _ lhs: any ClipboardPasteboard,
        _ rhs: any ClipboardPasteboard
    ) -> Bool {
        if lhs === rhs { return true }
        guard let lhs = lhs as? NSPasteboard, let rhs = rhs as? NSPasteboard else { return false }
        return lhs.name == rhs.name
    }

    /// Copies text for a manual ⌘V on a path that never borrowed the clipboard
    /// (focus moved first, or Accessibility is off), saving the user's clipboard
    /// first so the next paste can put it back. When the clipboard can't be
    /// saved safely it still copies the text: recovery beats restore here.
    private func copyTextForManualPaste(
        _ text: String,
        to pasteboard: any ClipboardPasteboard,
        isCurrentOperation: () -> Bool
    ) -> Bool {
        let snapshotChangeCount = pasteboard.changeCount
        let savedItems = snapshotPasteboardItems(from: pasteboard)
        // Materializing a lazy clipboard can run other code; a cancelled or
        // changed clipboard is not the user's to overwrite on our behalf.
        guard isCurrentOperation() else { return false }
        let snapshotIsCurrent = pasteboard.changeCount == snapshotChangeCount
        guard copyTextToClipboard(text, to: pasteboard) else { return false }
        if snapshotIsCurrent {
            saveClipboardForNextPaste(
                savedItems,
                fallbackText: text,
                fallbackChangeCount: pasteboard.changeCount,
                pasteboard: pasteboard
            )
        }
        return true
    }

    private func restoreRetainedClipboardNow() {
        guard let retained = retainedClipboardRestoreForPasteRetry else { return }
        retainedClipboardRestoreForPasteRetry = nil
        let pasteboard = retained.pasteboard
        guard pasteboard.changeCount == retained.temporaryChangeCount,
              pasteboard.string(forType: .string) == retained.temporaryString else {
            return
        }
        restorePasteboardItems(
            retained.savedItems,
            temporaryString: retained.temporaryString,
            temporaryChangeCount: retained.temporaryChangeCount,
            to: pasteboard
        )
    }

    private func scheduleClipboardRestore(
        _ savedItems: PasteboardSnapshot,
        temporaryString: String,
        temporaryChangeCount: Int,
        to pasteboard: any ClipboardPasteboard,
        token: SupersessionEpoch.Token,
        delay: UInt64
    ) {
        guard pasteEpoch.isCurrent(token) else { return }
        clipboardRestoreTask?.cancel()
        pendingClipboardRestore.install(
            PendingClipboardRestore(
                savedItems: savedItems,
                temporaryString: temporaryString,
                temporaryChangeCount: temporaryChangeCount,
                pasteboard: pasteboard
            ),
            ownedBy: token
        )
        clipboardRestoreTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard let self,
                  !Task.isCancelled,
                  self.pasteEpoch.isCurrent(token) else { return }
            self.restorePasteboardItems(
                savedItems,
                temporaryString: temporaryString,
                temporaryChangeCount: temporaryChangeCount,
                to: pasteboard
            )
            self.temporaryPasteboardDataProvider = nil
            self.pendingClipboardRestore.clearIfOwned(by: token)
            self.clipboardRestoreTask = nil
            self.clipboardAutoEnterReadinessTask?.cancel()
            self.clipboardAutoEnterReadinessTask = nil
            // Deliberately fused: publish this attempt as the Auto Enter ready
            // marker, then close its epoch so no later restore/readiness work
            // can still act on the finished attempt.
            self.clipboardAutoEnterReadyToken = token
            self.pasteEpoch.supersedeIfCurrent(token)
        }
    }

    private func waitForTargetActivation(
        _ target: DictationPasteTarget, timeout: TimeInterval,
        isCurrentOperation: () -> Bool
    ) -> Bool {
        guard timeout > 0 else { return false }

        let start = Date()
        while ClipboardTargetActivationPolicy.shouldWait(
            targetIsFrontmost: false,
            elapsed: Date().timeIntervalSince(start),
            timeout: timeout
        ) {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            guard isCurrentOperation() else { return false }
            if target.matchesCurrentFrontmostApp() {
                return true
            }
        }
        return target.matchesCurrentFrontmostApp()
    }

    @discardableResult
    func copyTextToClipboard(_ text: String, to pasteboard: any ClipboardPasteboard = NSPasteboard.general) -> Bool {
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
            && pasteboard.string(forType: .string) == text
    }

    @discardableResult
    func writeTemporaryString(
        _ text: String,
        to pasteboard: any ClipboardPasteboard
    ) -> Bool {
        guard pasteboard is NSPasteboard else { return false }

        let provider = TemporaryPasteboardStringProvider(
            text: text,
            onTemporaryStringRead: {}
        )
        let item = NSPasteboardItem()
        guard item.setDataProvider(provider, forTypes: [.string]) else {
            return false
        }
        // Best effort: without the marker the paste still works, clipboard
        // managers just record the borrowed text as they always did.
        _ = item.setData(Data(), forType: Self.transientPasteboardType)

        guard pasteboard.writePasteboardItems([item]) else {
            temporaryPasteboardDataProvider = nil
            return false
        }

        temporaryPasteboardDataProvider = provider
        return true
    }

    private func waitForPasteConfirmation(
        targetIsFrontmost: @MainActor () -> Bool,
        pasteConfirmed: @MainActor () -> Bool,
        stopWaitingUnconfirmed: @MainActor () -> Bool,
        isCurrentOperation: @MainActor () -> Bool,
        timeout: TimeInterval
    ) -> ClipboardPasteConfirmationWaitResult {
        func check() -> ClipboardPasteConfirmationWaitResult? {
            guard isCurrentOperation() else { return .cancelled }
            let frontmost = targetIsFrontmost()
            guard isCurrentOperation() else { return .cancelled }
            guard frontmost else { return .focusChanged }
            let confirmed = pasteConfirmed()
            guard isCurrentOperation() else { return .cancelled }
            let stillFrontmost = targetIsFrontmost()
            guard isCurrentOperation() else { return .cancelled }
            guard stillFrontmost else { return .focusChanged }
            if confirmed { return .confirmed }
            let stop = stopWaitingUnconfirmed()
            guard isCurrentOperation() else { return .cancelled }
            return stop ? .unconfirmed : nil
        }
        if let result = check() { return result }
        guard timeout > 0 else { return .unconfirmed }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
            if let result = check() { return result }
        }
        return check() ?? .unconfirmed
    }

    func snapshotPasteboardItems(
        from pasteboard: any ClipboardPasteboard,
        readData: (NSPasteboardItem, NSPasteboard.PasteboardType) -> Data? = { $0.data(forType: $1) }
    ) -> PasteboardSnapshot {
        var isComplete = true
        // This runs synchronously on the stop-to-paste path, so bound the whole
        // snapshot as well as each representation: one pathological clipboard
        // must not turn the stop into a multi-hundred-megabyte copy.
        var totalBytes = 0
        var containsPrivacyMarker = false
        let items: [[NSPasteboard.PasteboardType: Data]] = pasteboard.pasteboardItems?.map { item in
            var typeData: [NSPasteboard.PasteboardType: Data] = [:]
            var skippedTypes = 0
            for type in item.types {
                if Self.privacyMarkerTypes.contains(type) {
                    // Checked from the type list, before any data read, so a
                    // marker with no readable data still counts.
                    containsPrivacyMarker = true
                }
                // Once full, avoid asking additional lazy providers to allocate
                // data that cannot be retained. Individual provider fetches can
                // still exceed the budget; NSPasteboard has no size preflight.
                guard totalBytes < TranscriptedConstants.clipboardSnapshotMaxTotalBytes,
                      let data = readData(item, type),
                      data.count <= TranscriptedConstants.clipboardSnapshotMaxTypeBytes,
                      totalBytes + data.count <= TranscriptedConstants.clipboardSnapshotMaxTotalBytes else {
                    skippedTypes += 1
                    continue
                }
                // Keep empty privacy markers so a restored password stays
                // marked as concealed for clipboard managers.
                if !data.isEmpty || Self.privacyMarkerTypes.contains(type) {
                    typeData[type] = data
                    totalBytes += data.count
                }
            }
            // Dropping one heavy or unreadable representation (a screenshot's
            // TIFF next to its PNG) still restores the item, so it does not
            // block paste-back. Only an item that lost every representation
            // makes the snapshot incomplete — restoring it would erase the
            // user's clipboard, and that is the case paste-back refuses.
            if typeData.isEmpty, skippedTypes > 0 {
                isComplete = false
            }
            return typeData
        } ?? []
        return PasteboardSnapshot(
            items: items,
            isComplete: isComplete,
            containsPrivacyMarker: containsPrivacyMarker
        )
    }

    func restorePasteboardItems(
        _ savedItems: PasteboardSnapshot,
        temporaryString: String,
        temporaryChangeCount: Int,
        to pasteboard: any ClipboardPasteboard
    ) {
        restoreClipboardSnapshot(savedItems, matching: temporaryString,
            changeCount: temporaryChangeCount, to: pasteboard)
    }

    private func restoreClipboardSnapshot(
        _ savedItems: PasteboardSnapshot, matching expectedString: String?,
        changeCount: Int, to pasteboard: any ClipboardPasteboard
    ) {
        guard savedItems.isComplete,
              pasteboard.changeCount == changeCount,
              pasteboard.string(forType: .string) == expectedString,
              pasteboard.changeCount == changeCount else { return }

        pasteboard.clearContents()
        let items = savedItems.items.map { typeData -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in typeData {
                item.setData(data, forType: type)
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writePasteboardItems(items)
        }
    }
}

private final class TemporaryPasteboardStringProvider: NSObject, NSPasteboardItemDataProvider {
    private let text: String
    private let onTemporaryStringRead: () -> Void
    private let lock = NSLock()
    private var didNotifyRead = false
    private var firstReadTimestamp: CFAbsoluteTime?

    var didProvideData: Bool {
        lock.lock()
        let value = didNotifyRead
        lock.unlock()
        return value
    }

    var firstReadAt: CFAbsoluteTime? {
        lock.lock()
        let value = firstReadTimestamp
        lock.unlock()
        return value
    }

    init(text: String, onTemporaryStringRead: @escaping () -> Void) {
        self.text = text
        self.onTemporaryStringRead = onTemporaryStringRead
    }

    func pasteboard(
        _ pasteboard: NSPasteboard?,
        item: NSPasteboardItem,
        provideDataForType type: NSPasteboard.PasteboardType
    ) {
        guard type == .string else { return }
        item.setString(text, forType: .string)
        notifyReadOnce()
    }

    private func notifyReadOnce() {
        lock.lock()
        let shouldNotify = !didNotifyRead
        didNotifyRead = true
        if firstReadTimestamp == nil {
            firstReadTimestamp = CFAbsoluteTimeGetCurrent()
        }
        lock.unlock()

        if shouldNotify {
            onTemporaryStringRead()
        }
    }
}
