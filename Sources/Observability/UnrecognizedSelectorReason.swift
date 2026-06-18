import Foundation

/// Parses the receiver class + selector out of an Objective-C
/// "unrecognized selector" exception reason.
///
/// AppKit target/action faults surface as a fatal `NSInvalidArgumentException`
/// whose reason reads:
///   `-[NSButton someSelector:]: unrecognized selector sent to instance 0x…`
/// (or `+[SomeClass sel]: … sent to class 0x…` for class methods).
///
/// Sentry's uncaught-NSException capture records that the exception happened but
/// not its `reason`, so these crashes arrive with no class/selector and are
/// undiagnosable. The leading class + selector are Objective-C symbol names —
/// the same kind of data already retained in sanitized stack-frame `function`
/// fields — so they are safe to surface as crash tags. The instance pointer and
/// any trailing free text are deliberately dropped.
enum UnrecognizedSelectorReason {
    struct Parsed: Equatable {
        let receiver: String
        let selector: String
        let isClassMethod: Bool
    }

    static func parse(_ reason: String?) -> Parsed? {
        guard let reason, reason.contains("unrecognized selector") else { return nil }
        guard let open = reason.firstIndex(of: "["),
              let close = reason.firstIndex(of: "]"),
              open < close,
              open > reason.startIndex else { return nil }

        // The dispatch prefix immediately before '[' is '-' (instance) or '+' (class).
        let isClassMethod: Bool
        switch reason[reason.index(before: open)] {
        case "+": isClassMethod = true
        case "-": isClassMethod = false
        default: return nil
        }

        let inner = reason[reason.index(after: open)..<close]   // e.g. "NSButton someSelector:"
        let parts = inner.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let receiver = String(parts[0])
        let selector = String(parts[1])
        guard !receiver.isEmpty, !selector.isEmpty else { return nil }

        return Parsed(receiver: receiver, selector: selector, isClassMethod: isClassMethod)
    }
}
