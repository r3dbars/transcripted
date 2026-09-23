// DictationInputDeviceSelectionPolicy.swift
// Follows the selected Mac input unless the user opts into a local-mic recommendation.

import Foundation

enum DictationAudioTransport: String {
    case builtIn
    case bluetooth
    case bluetoothLE
    case usb
    case aggregate
    case virtual
    case other
}

struct DictationAudioDevice: Equatable {
    let id: UInt32
    let name: String
    let transport: DictationAudioTransport
    let inputChannelCount: UInt32
    let uid: String?

    init(
        id: UInt32,
        name: String,
        transport: DictationAudioTransport,
        inputChannelCount: UInt32,
        uid: String? = nil
    ) {
        self.id = id
        self.name = name
        self.transport = transport
        self.inputChannelCount = inputChannelCount
        self.uid = uid
    }
}

enum DictationPreferredInputPolicy {
    static func input(
        preferredUID: String?,
        availableInputs: [DictationAudioDevice],
        automaticFallback: DictationAudioDevice
    ) -> DictationAudioDevice {
        guard let preferredUID,
              let preferred = availableInputs.first(where: {
                  $0.uid == preferredUID
                      && DictationInputDeviceSelectionPolicy.deviceClass(for: $0) != "bluetooth"
              }) else {
            return automaticFallback
        }
        return preferred
    }
}

/// Which microphone dictation uses when macOS routes both the mic and playback
/// to Bluetooth headphones such as AirPods.
///
/// Opening a headset mic puts it in call mode. Playback drops to mono call
/// quality while the mic is open, and the switch can take seconds. On
/// 2026-09-23 the AirPods mic still wasn't up 6s into a start and dictation
/// failed. So the Mac's mic goes first unless the user turned on "Use
/// Mac-selected microphone" (the same setting meetings read) or the MacBook
/// lid is closed, since a closed MacBook's mic can't hear anyone.
///
/// A slow headset mic doesn't get to fail the start alone: if it isn't
/// recording after `switchAfter`, the dictation wait loop switches to the
/// Mac's mic once. The reverse never happens. A slow Mac mic is retried,
/// never swapped for the headset mic, because opening the headset mic puts
/// playback into call mode. On 2026-09-23 a cold first start after relaunch
/// fell back to AirPods and garbled Justin's music for ~10s; a clear
/// "try again" is better than that.
enum DictationHeadsetMicChoice: String, Equatable {
    case macMic
    case headsetMic

    var alternate: DictationHeadsetMicChoice {
        self == .macMic ? .headsetMic : .macMic
    }
}

enum DictationHeadsetMicPolicy {
    /// How long the first mic gets before dictation tries the other one.
    static let switchAfter: TimeInterval = 2.5
    /// The other mic always gets at least this long, even past the normal
    /// dictation start budget.
    static let minimumBudgetAfterSwitch: TimeInterval = 4.0

    static func firstChoice(usesMacSelectedInput: Bool, isLidClosed: Bool) -> DictationHeadsetMicChoice {
        usesMacSelectedInput || isLidClosed ? .headsetMic : .macMic
    }

    /// What the selection actually picked. Anything but the built-in
    /// override is the headset (or a route with no headset at all).
    static func choiceInUse(for selection: DictationInputDeviceSelection) -> DictationHeadsetMicChoice {
        selection.reason == .preferredBuiltInForBluetoothHeadset ? .macMic : .headsetMic
    }

    /// Switch once, only from the headset mic to the Mac mic on a headset
    /// route: with a USB or built-in default there is no other mic to try,
    /// and a slow Mac mic is waited on rather than traded for call mode.
    static func shouldSwitch(
        elapsed: TimeInterval,
        alreadySwitched: Bool,
        selection: DictationInputDeviceSelection?
    ) -> Bool {
        guard !alreadySwitched, elapsed >= switchAfter, let selection else { return false }
        return DictationInputDeviceSelectionPolicy.deviceClass(for: selection.defaultInput) == "bluetooth"
            && choiceInUse(for: selection) == .headsetMic
    }
}

/// The mic that last started on a given Bluetooth headset. Later dictations
/// on the same headset start there directly instead of paying for the first
/// choice to fail again (on 2026-09-23 every start re-tried the Mac mic,
/// waited ~1.5s, then landed on AirPods). It stops applying if the shared
/// mic setting or the lid state changes.
struct DictationRememberedHeadsetMic: Equatable {
    let headsetKey: String
    let usesMacSelectedInput: Bool
    let isLidClosed: Bool
    let choice: DictationHeadsetMicChoice

    func applies(usesMacSelectedInput: Bool, isLidClosed: Bool) -> Bool {
        self.usesMacSelectedInput == usesMacSelectedInput && self.isLidClosed == isLidClosed
    }
}

extension DictationHeadsetMicPolicy {
    static func headsetKey(for device: DictationAudioDevice) -> String {
        device.uid ?? device.name
    }

    /// What to remember after a start succeeds, or nil to keep what is
    /// already remembered. Only headset routes have a second mic worth
    /// remembering. A recovery start that followed the headset because the
    /// fallback was suppressed is a last resort, not a choice, so it must not
    /// pin later dictations to the headset mic.
    static func remembered(
        afterStartingWith selection: DictationInputDeviceSelection,
        usesMacSelectedInput: Bool,
        isLidClosed: Bool
    ) -> DictationRememberedHeadsetMic? {
        guard DictationInputDeviceSelectionPolicy.deviceClass(for: selection.defaultInput) == "bluetooth",
              selection.reason != .builtInFallbackSuppressedForRecoveryAttempt else {
            return nil
        }
        return DictationRememberedHeadsetMic(
            headsetKey: headsetKey(for: selection.defaultInput),
            usesMacSelectedInput: usesMacSelectedInput,
            isLidClosed: isLidClosed,
            choice: choiceInUse(for: selection)
        )
    }
}

enum DictationInputDeviceSelectionReason: String {
    case defaultIsSafe
    case preferredBuiltInForBluetoothHeadset
    case builtInFallbackSuppressedForRecoveryAttempt
    case noBuiltInFallbackAvailable
}

struct DictationInputDeviceSelection: Equatable {
    let defaultInput: DictationAudioDevice
    let selectedInput: DictationAudioDevice
    let defaultOutput: DictationAudioDevice?
    let reason: DictationInputDeviceSelectionReason

    var didOverrideDefault: Bool {
        selectedInput.id != defaultInput.id
    }
}

enum DictationVoiceProcessingRouteDecision: Equatable {
    case disabledByPreference
    case enabled
    case deferredForSplitBluetoothOutput

    var shouldEnable: Bool {
        self == .enabled
    }
}

/// Apple voice processing owns a coupled input/output voice-call graph. On a
/// split route (for example, a built-in or USB mic with Bluetooth playback),
/// enabling it can pull CoreAudio toward the headset input and repeatedly
/// renegotiate the live mic format. Keep the user's preference for matched
/// routes, but use the stable regular input graph for split Bluetooth output.
enum DictationVoiceProcessingRoutePolicy {
    static func decision(
        requested: Bool,
        selection: DictationInputDeviceSelection?
    ) -> DictationVoiceProcessingRouteDecision {
        guard requested else { return .disabledByPreference }
        guard let selection, let defaultOutput = selection.defaultOutput else {
            return .enabled
        }

        let inputClass = DictationInputDeviceSelectionPolicy.deviceClass(
            for: selection.selectedInput
        )
        let outputClass = DictationInputDeviceSelectionPolicy.deviceClass(
            for: defaultOutput
        )
        guard outputClass == "bluetooth", inputClass != "bluetooth" else {
            return .enabled
        }
        return .deferredForSplitBluetoothOutput
    }
}

enum DictationInputDeviceSelectionPolicy {
    static func selection(
        defaultInput: DictationAudioDevice,
        defaultOutput: DictationAudioDevice?,
        availableInputs: [DictationAudioDevice],
        prefersBuiltInBluetoothInput: Bool = false,
        allowsBuiltInBluetoothFallback: Bool = true
    ) -> DictationInputDeviceSelection {
        // A visible built-in device is not proof that it can hear the user.
        // Without the preference this follows macOS. Callers turn it on for
        // the Mac-mic headset choice (DictationHeadsetMicPolicy), which checks
        // the lid first and falls back to the headset if the Mac mic stalls.
        guard prefersBuiltInBluetoothInput,
              shouldAvoidBluetoothHeadsetInput(defaultInput, defaultOutput: defaultOutput) else {
            return DictationInputDeviceSelection(
                defaultInput: defaultInput,
                selectedInput: defaultInput,
                defaultOutput: defaultOutput,
                reason: .defaultIsSafe
            )
        }

        guard allowsBuiltInBluetoothFallback else {
            return DictationInputDeviceSelection(
                defaultInput: defaultInput,
                selectedInput: defaultInput,
                defaultOutput: defaultOutput,
                reason: .builtInFallbackSuppressedForRecoveryAttempt
            )
        }

        guard let builtInInput = preferredBuiltInInput(from: availableInputs, defaultInput: defaultInput) else {
            return DictationInputDeviceSelection(
                defaultInput: defaultInput,
                selectedInput: defaultInput,
                defaultOutput: defaultOutput,
                reason: .noBuiltInFallbackAvailable
            )
        }

        return DictationInputDeviceSelection(
            defaultInput: defaultInput,
            selectedInput: builtInInput,
            defaultOutput: defaultOutput,
            reason: .preferredBuiltInForBluetoothHeadset
        )
    }

    static func deviceClass(for device: DictationAudioDevice) -> String {
        deviceClass(forName: device.name, transport: device.transport)
    }

    static func deviceClass(
        forName deviceName: String,
        transport: DictationAudioTransport = .other
    ) -> String {
        let normalized = normalize(deviceName)

        if isBluetoothTransport(transport) || isBluetoothHeadsetName(normalized) {
            return "bluetooth"
        }

        if isBuiltInCandidateName(normalized) || transport == .builtIn {
            return "built_in"
        }

        if transport == .aggregate {
            return "aggregate"
        }

        if transport == .virtual {
            return "virtual"
        }

        if isExternalMicrophoneName(normalized, transport: transport) {
            return "external"
        }

        return "unknown"
    }

    private static func shouldAvoidBluetoothHeadsetInput(
        _ defaultInput: DictationAudioDevice,
        defaultOutput: DictationAudioDevice?
    ) -> Bool {
        guard isBluetoothHeadsetInput(defaultInput) else { return false }

        guard let defaultOutput else {
            return true
        }

        if defaultOutput.id == defaultInput.id {
            return true
        }

        if isBluetoothAudioDevice(defaultOutput) {
            return true
        }

        return normalize(defaultOutput.name) == normalize(defaultInput.name)
    }

    private static func preferredBuiltInInput(
        from availableInputs: [DictationAudioDevice],
        defaultInput: DictationAudioDevice
    ) -> DictationAudioDevice? {
        availableInputs
            .filter { $0.id != defaultInput.id }
            .filter { builtInInputRank($0) < Int.max }
            .sorted { lhs, rhs in
                let lhsRank = builtInInputRank(lhs)
                let rhsRank = builtInInputRank(rhs)
                if lhsRank != rhsRank {
                    return lhsRank < rhsRank
                }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            .first
    }

    private static func builtInInputRank(_ device: DictationAudioDevice) -> Int {
        let normalized = normalize(device.name)

        if normalized.contains("macbook") && normalized.contains("microphone") {
            return 0
        }

        if normalized.contains("built-in microphone")
            || normalized.contains("built in microphone") {
            return 1
        }

        if normalized.contains("studio display") && normalized.contains("microphone") {
            return 2
        }

        if device.transport == .builtIn
            && (normalized.contains("microphone") || normalized.contains("mic")) {
            return 3
        }

        if device.transport == .builtIn {
            return 4
        }

        return Int.max
    }

    private static func isBluetoothHeadsetInput(_ device: DictationAudioDevice) -> Bool {
        isBluetoothAudioDevice(device)
    }

    private static func isBluetoothAudioDevice(_ device: DictationAudioDevice) -> Bool {
        isBluetoothTransport(device.transport) || isBluetoothHeadsetName(normalize(device.name))
    }

    private static func isBluetoothTransport(_ transport: DictationAudioTransport) -> Bool {
        transport == .bluetooth || transport == .bluetoothLE
    }

    private static func isBluetoothHeadsetName(_ normalized: String) -> Bool {
        normalized.contains("airpod")
            || normalized.contains("bluetooth")
            || normalized.contains("beats")
            || normalized.contains("buds")
            || normalized.contains("earbuds")
            || normalized.contains("headset")
            || normalized.contains("hands-free")
            || normalized.contains("hands free")
            || normalized.contains("hfp")
    }

    private static func isBuiltInCandidateName(_ normalized: String) -> Bool {
        normalized.contains("macbook")
            || normalized.contains("built-in")
            || normalized.contains("built in")
            || normalized.contains("studio display")
    }

    private static func isExternalMicrophoneName(
        _ normalized: String,
        transport: DictationAudioTransport
    ) -> Bool {
        transport == .usb
            || normalized.contains("usb")
            || normalized.contains("audio interface")
            || normalized.contains("camera")
            || normalized.contains("c920")
            || normalized.contains("elgato")
            || normalized.contains("external")
            || normalized.contains("interface")
            || normalized.contains("logitech")
            || normalized.contains("mv7")
            || normalized.contains("rode")
            || normalized.contains("scarlett")
            || normalized.contains("shure")
            || normalized.contains("webcam")
            || normalized.contains("yeti")
    }

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

/// A valid audio format does not prove that AUHAL is bound to the selected mic.
/// Keep the binding operation testable without opening real audio hardware.
enum DictationInputDeviceBindingError: LocalizedError, Equatable {
    case applicationFailed
    case selectedDeviceNotBound
    case selectionUnavailable

    var errorDescription: String? {
        "The selected microphone is still settling. Try dictation again."
    }
}

enum DictationInputDeviceBindingPolicy {
    static func requireSelection(_ selection: DictationInputDeviceSelection?) throws -> DictationInputDeviceSelection {
        guard let selection, selection.selectedInput.id != 0 else {
            throw DictationInputDeviceBindingError.selectionUnavailable
        }
        return selection
    }

    /// Poll an already-issued route command. Reissuing the setter on every
    /// stale read can restart a slow driver's transition indefinitely.
    /// The probe must honor its remaining timeout, including native work.
    @MainActor
    static func waitForBinding<Value>(
        timeoutNanoseconds: UInt64 = TranscriptedConstants.audioInputBindingSettleTimeout,
        initialDelayNanoseconds: UInt64 = TranscriptedConstants.audioRecoveryDelay,
        pollIntervalNanoseconds: UInt64 = TranscriptedConstants.dictationReadinessPollInterval,
        now: () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        sleep: (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) },
        isCurrent: () -> Bool,
        probe: (UInt64) async throws -> Value
    ) async throws -> Value {
        let startedAt = now()
        func remaining() -> UInt64 {
            let elapsed = now() &- startedAt
            return elapsed < timeoutNanoseconds ? timeoutNanoseconds - elapsed : 0
        }
        var delay = initialDelayNanoseconds
        while true {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            let beforeSleep = remaining()
            guard beforeSleep > 0 else { throw DictationInputDeviceBindingError.selectedDeviceNotBound }
            try await sleep(min(delay, beforeSleep))
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            let budget = remaining()
            guard budget > 0 else { throw DictationInputDeviceBindingError.selectedDeviceNotBound }
            do {
                let value = try await probe(budget)
                try Task.checkCancellation()
                guard isCurrent() else { throw CancellationError() }
                guard remaining() > 0 else { throw DictationInputDeviceBindingError.selectedDeviceNotBound }
                return value
            } catch DictationInputDeviceBindingError.selectedDeviceNotBound {
                // Only an unsettled ID is retryable. Native failures and
                // cancellation must leave this loop immediately.
                delay = max(1, pollIntervalNanoseconds)
            }
        }
    }

    /// Returns whether a route command was issued. A changed route must be
    /// verified by the caller after settling before publishing readiness.
    @discardableResult
    static func apply(
        selection: DictationInputDeviceSelection,
        currentDeviceID: () -> UInt32,
        setDeviceID: (UInt32) throws -> Void
    ) throws -> Bool {
        let selectedID = selection.selectedInput.id
        guard selectedID != 0 else {
            throw DictationInputDeviceBindingError.selectedDeviceNotBound
        }
        // Following the default also needs a rebind if an earlier session
        // pinned this graph to a different microphone.
        let needsBinding = currentDeviceID() != selectedID
        if needsBinding {
            try setDeviceID(selectedID)
            // A successful AUHAL command need not publish the new ID immediately.
            // Let audioInputSnapshot reach its bounded delay and strict verification.
            return true
        }
        try verify(selectedDeviceID: selectedID, boundDeviceID: currentDeviceID())
        return false
    }

    static func verify(selectedDeviceID: UInt32, boundDeviceID: UInt32) throws {
        guard selectedDeviceID != 0, selectedDeviceID == boundDeviceID else {
            throw DictationInputDeviceBindingError.selectedDeviceNotBound
        }
    }
}
