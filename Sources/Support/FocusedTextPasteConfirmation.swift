// FocusedTextPasteConfirmation.swift
// Accessibility checks that tell whether a paste landed in the focused text
// element: the confirmation policy, the AX change observer, and the capture
// the paster reads before and after Cmd+V. Split out of
// ClipboardRestoringTextPaster.swift.

import AppKit
import ApplicationServices
import Foundation

enum FocusedTextPasteConfirmationPolicy {
    /// Accessibility clients can otherwise block for several seconds when an editor is
    /// briefly busy applying a paste (Notes is a common example). Confirmation is a
    /// best-effort signal and must never stall delivery or the target application.
    private static let messagingTimeout: Float = 0.05

    /// The focused UI element, with every AX read on it and on the system-wide
    /// element bounded by `messagingTimeout`. Returns nil when the focused-element
    /// attribute isn't an AXUIElement: AXUIElement is a toll-free-bridged CF opaque
    /// type, so Swift can't runtime-check `as?`/`as!` against it (the compiler treats
    /// the downcast as unconditionally successful), and CFGetTypeID is the actual
    /// safety net before the value goes to AX APIs that assume its type.
    static func boundedFocusedElement(
        systemWide: AXUIElement,
        setMessagingTimeout: (AXUIElement, Float) -> Void = { element, timeout in
            AXUIElementSetMessagingTimeout(element, timeout)
        },
        copyFocusedElement: (AXUIElement) -> CFTypeRef? = { systemWide in
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                systemWide,
                kAXFocusedUIElementAttribute as CFString,
                &value
            ) == .success else { return nil }
            return value
        }
    ) -> AXUIElement? {
        setMessagingTimeout(systemWide, messagingTimeout)
        guard let focusedElement = copyFocusedElement(systemWide) else { return nil }
        // This file is compiled directly into the fast-test binary without the
        // TranscriptedCore module's search path (see APP_SOURCES in run-tests.sh),
        // so the app logger isn't available here; this follows the same
        // fputs(..., stderr) idiom Sources/Observability/AppLogSink.swift falls back to.
        guard CFGetTypeID(focusedElement) == AXUIElementGetTypeID() else {
            fputs("⚠️ ClipboardRestoringTextPaster | focused UI element attribute returned an unexpected CF type (expected AXUIElement)\n", stderr)
            return nil
        }
        let element = focusedElement as! AXUIElement
        setMessagingTimeout(element, messagingTimeout)
        return element
    }

    /// Roles where a paste can't land: a web page body, plain text, links,
    /// images, and controls like buttons and menus. Any of them still counts
    /// as text entry when its value is settable or it sits inside an editable
    /// region. A selection range is no signal: web pages report one on plain,
    /// uneditable text.
    ///
    /// Containers stay out on purpose. A selected spreadsheet cell (Numbers,
    /// Excel, Sheets) reports AXCell, AXRow or AXTable, and GPU terminals
    /// (kitty, Alacritty, Ghostty, Warp) report their window or a group, yet
    /// all of them take a paste. Refuting those told people "Not pasted" after
    /// the text landed.
    private static let nonTextEntryRoles: Set<String> = [
        "AXWebArea", "AXStaticText", "AXLink", "AXImage",
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXDisclosureTriangle", "AXSlider",
        "AXMenu", "AXMenuItem", "AXMenuBar", "AXMenuBarItem", "AXToolbar",
    ]

    /// True only when the focus plainly can't take text. An unknown role
    /// never counts, so an app that exposes little to Accessibility keeps
    /// today's likely-paste behavior.
    static func isClearlyNotTextEntry(role: String?, valueIsSettable: Bool, hasEditableAncestor: Bool) -> Bool {
        guard let role, nonTextEntryRoles.contains(role) else { return false }
        return !valueIsSettable && !hasEditableAncestor
    }

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

    /// Whether a target that can confirm over Accessibility may still end the
    /// confirmation wait on its quick clipboard read. Only when the caller says
    /// nothing after the paste needs a confirmed one (a dictation with Auto
    /// Enter not expected), and only for a read that makes the paste a likely
    /// one anyway: right after Cmd+V, into a focus that could take text.
    static func endsWaitOnLikelyPaste(
        callerAllows: Bool,
        focusRefutesPaste: Bool,
        pasteDispatchedAt: CFAbsoluteTime,
        clipboardReadAt: CFAbsoluteTime?
    ) -> Bool {
        guard callerAllows, !focusRefutesPaste else { return false }
        return didObserveLikelyPaste(pasteDispatchedAt: pasteDispatchedAt, clipboardReadAt: clipboardReadAt)
    }

    /// The restore delay after a likely paste. When the wait ended early on the
    /// read, the part of the wait it skipped is added back, so the user's
    /// clipboard never comes back sooner than it would after a full wait.
    static func likelyPasteRestoreDelay(fallbackDelay: UInt64, unusedWait: TimeInterval) -> UInt64 {
        guard unusedWait.isFinite, unusedWait > 0 else { return fallbackDelay }
        let extra = UInt64((min(unusedWait, 60) * 1_000_000_000).rounded())
        let (delay, overflowed) = fallbackDelay.addingReportingOverflow(extra)
        return overflowed ? .max : delay
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

struct FocusedTextPasteConfirmation {
    private let focusedElement: AXUIElement
    private let initialValue: String?
    private let replacedSelectionLength: Int
    private let initialSelectionRange: FocusedTextPasteConfirmationPolicy.SelectionRange?
    private let changeObserver: FocusedTextChangeObserver?
    private let focusedRole: String?
    private let valueIsSettable: Bool
    private let hasEditableAncestor: Bool

    var canObservePaste: Bool {
        initialValue != nil || initialSelectionRange != nil || changeObserver != nil
    }

    var focusIsClearlyNotTextEntry: Bool {
        FocusedTextPasteConfirmationPolicy.isClearlyNotTextEntry(
            role: focusedRole,
            valueIsSettable: valueIsSettable,
            hasEditableAncestor: hasEditableAncestor
        )
    }

    static func capture() -> FocusedTextPasteConfirmation? {
        guard let element = FocusedTextPasteConfirmationPolicy.boundedFocusedElement(
            systemWide: AXUIElementCreateSystemWide()
        ) else {
            return nil
        }
        return FocusedTextPasteConfirmation(
            focusedElement: element,
            initialValue: stringAttribute(kAXValueAttribute as CFString, from: element),
            replacedSelectionLength: stringAttribute(kAXSelectedTextAttribute as CFString, from: element)?.utf16.count ?? 0,
            initialSelectionRange: selectionRangeAttribute(from: element),
            changeObserver: FocusedTextChangeObserver.start(for: element),
            focusedRole: stringAttribute(kAXRoleAttribute as CFString, from: element),
            valueIsSettable: {
                var settable = DarwinBoolean(false)
                return AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success
                    && settable.boolValue
            }(),
            hasEditableAncestor: {
                // Web content lists these on anything inside a text box or
                // editable region (Muse routes a paste from a button inside
                // one), and not on the page around it (Claude's transcript).
                var names: CFArray?
                guard AXUIElementCopyAttributeNames(element, &names) == .success,
                      let names = names as? [String] else { return false }
                return names.contains("AXEditableAncestor") || names.contains("AXHighestEditableAncestor")
            }()
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

/// Sources that can't tell make no claim, so they never overrule a paste.
@MainActor
extension ClipboardPasteConfirmationSource {
    var focusIsClearlyNotTextEntry: Bool { false }
}

@MainActor
protocol ClipboardPasteConfirmationSource {
    var canObservePaste: Bool { get }
    /// True only when the focus is plainly somewhere text can't go (a web
    /// page, a button, a list). Unknown focus is not "clearly not".
    var focusIsClearlyNotTextEntry: Bool { get }

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
