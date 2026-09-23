import AudioToolbox
@preconcurrency import AVFoundation
import Foundation
import IOKit

enum MeetingAudioTransport: String {
    case builtIn
    case bluetooth
    case bluetoothLE
    case usb
    case aggregate
    case virtual
    case other
}

/// The host's microphone choice for a new meeting. Neither mode changes the
/// macOS default input or output device.
public enum MeetingInputDeviceSelectionMode: String, Sendable {
    /// Prefer a built-in microphone when a Bluetooth headset is the default
    /// input and output, avoiding contention with the call app's headset mic.
    case automatic
    /// Start on the macOS input, including a deliberately selected headset.
    /// A detected Bluetooth route failure may still use the bounded fallback.
    case preserveDefault
}

struct MeetingAudioDevice: Equatable {
    let id: AudioDeviceID
    let name: String
    let transport: MeetingAudioTransport
    let inputChannelCount: UInt32
}

enum MeetingInputDeviceSelectionReason: String {
    case defaultIsSafe
    case preservedDefaultInput
    case preferredBuiltInForBluetoothHeadset
    case noBuiltInFallbackAvailable
    /// The chosen mic could not start or stopped delivering audio, so this
    /// recording moved to the built-in mic instead of failing.
    case builtInFallbackAfterFailure
}

struct MeetingInputDeviceSelection: Equatable {
    let defaultInput: MeetingAudioDevice
    let selectedInput: MeetingAudioDevice
    let defaultOutput: MeetingAudioDevice?
    let reason: MeetingInputDeviceSelectionReason

    var didOverrideDefault: Bool {
        selectedInput.id != defaultInput.id
    }
}

enum MeetingInputDeviceSelectionPolicy {
    enum RouteReadiness: String, Equatable {
        case ready
        case deviceMismatch = "device_mismatch"
        case sampleRateMismatch = "sample_rate_mismatch"
    }

    /// Automatic mode isolates the call app's Bluetooth mic. An explicit host
    /// preference may instead preserve the macOS input for this recording.
    static func selectionForMeetingStart(
        defaultInput: MeetingAudioDevice,
        defaultOutput: MeetingAudioDevice?,
        availableInputs: [MeetingAudioDevice],
        mode: MeetingInputDeviceSelectionMode = .automatic
    ) -> MeetingInputDeviceSelection {
        selection(
            defaultInput: defaultInput,
            defaultOutput: defaultOutput,
            availableInputs: availableInputs,
            mode: mode
        )
    }

    static func shouldAttemptBuiltInStabilization(
        routeWasUnstable: Bool,
        selectedInput: MeetingAudioDevice,
        stabilizationAlreadyAttempted: Bool
    ) -> Bool {
        routeWasUnstable
            && (selectedInput.transport == .bluetooth || selectedInput.transport == .bluetoothLE)
            && !stabilizationAlreadyAttempted
    }

    static func selectionAfterStabilizationAttempt(
        pinnedSelection: MeetingInputDeviceSelection,
        attemptedSelection: MeetingInputDeviceSelection,
        outcome: CaptureRouteStabilizationOutcome
    ) -> MeetingInputDeviceSelection {
        outcome == .switchedToBuiltIn ? attemptedSelection : pinnedSelection
    }

    static func selectionAfterApplicationAttempt(
        currentSelection: MeetingInputDeviceSelection?,
        attemptedSelection: MeetingInputDeviceSelection,
        didApplySelection: Bool
    ) -> MeetingInputDeviceSelection? {
        didApplySelection ? attemptedSelection : currentSelection
    }

    static func shouldAbortMeetingStart(
        after outcome: CaptureRouteStabilizationOutcome
    ) -> Bool {
        outcome == .switchFailed
    }

    static func outcomeAfterLookupFailure(
        mode: MeetingInputDeviceSelectionMode
    ) -> CaptureRouteStabilizationOutcome {
        mode == .preserveDefault ? .switchFailed : .notNeeded
    }

    static func outcomeAfterApplicationFailure(
        selectionReason: MeetingInputDeviceSelectionReason,
        requestedOutcome: CaptureRouteStabilizationOutcome
    ) -> CaptureRouteStabilizationOutcome {
        switch selectionReason {
        case .preferredBuiltInForBluetoothHeadset, .preservedDefaultInput, .builtInFallbackAfterFailure:
            // An unapplied explicit choice must not become a nil selection
            // that lets route readiness accept the node's previous device.
            return .switchFailed
        case .defaultIsSafe, .noBuiltInFallbackAvailable:
            return requestedOutcome
        }
    }

    static func routeReadiness(
        selection: MeetingInputDeviceSelection?,
        boundInputDeviceIDBeforeVoiceProcessing: AudioDeviceID,
        actualInputDeviceID: AudioDeviceID,
        capturedSampleRate: Double,
        selectedNominalSampleRate: Double?,
        voiceProcessingEnabled: Bool
    ) -> RouteReadiness {
        guard let selection else { return .ready }
        // Prove the selected physical microphone was bound before VPIO wraps
        // the node. Once enabled, AUVoiceProcessingIO may expose an unknown or
        // private device ID, so its post-wrap identity cannot safely validate
        // the physical route. Actual audio frames remain the final start gate.
        guard boundInputDeviceIDBeforeVoiceProcessing == selection.selectedInput.id else {
            return .deviceMismatch
        }

        // The raw path does not replace the device identity, so it must still
        // report the exact selected microphone after graph configuration.
        guard voiceProcessingEnabled
                || actualInputDeviceID == selection.selectedInput.id else {
            return .deviceMismatch
        }

        // A non-default built-in selection must expose that device's hardware
        // rate. The failed AirPods handoff reported the built-in device ID but
        // retained the 24 kHz HFP format and then delivered zero buffers.
        // VPIO intentionally exposes a converter format, so only compare the
        // raw hardware path.
        guard selection.didOverrideDefault,
              !voiceProcessingEnabled,
              let selectedNominalSampleRate,
              selectedNominalSampleRate.isFinite,
              selectedNominalSampleRate > 0 else {
            return .ready
        }

        return abs(capturedSampleRate - selectedNominalSampleRate) <= 1
            ? .ready
            : .sampleRateMismatch
    }

    static func selection(
        defaultInput: MeetingAudioDevice,
        defaultOutput: MeetingAudioDevice?,
        availableInputs: [MeetingAudioDevice],
        mode: MeetingInputDeviceSelectionMode = .automatic
    ) -> MeetingInputDeviceSelection {
        guard mode == .automatic else {
            return MeetingInputDeviceSelection(
                defaultInput: defaultInput,
                selectedInput: defaultInput,
                defaultOutput: defaultOutput,
                reason: .preservedDefaultInput
            )
        }

        guard shouldAvoidBluetoothHeadsetInput(defaultInput, defaultOutput: defaultOutput) else {
            return MeetingInputDeviceSelection(
                defaultInput: defaultInput,
                selectedInput: defaultInput,
                defaultOutput: defaultOutput,
                reason: .defaultIsSafe
            )
        }

        guard let builtInInput = preferredBuiltInInput(from: availableInputs, defaultInput: defaultInput) else {
            return MeetingInputDeviceSelection(
                defaultInput: defaultInput,
                selectedInput: defaultInput,
                defaultOutput: defaultOutput,
                reason: .noBuiltInFallbackAvailable
            )
        }

        return MeetingInputDeviceSelection(
            defaultInput: defaultInput,
            selectedInput: builtInInput,
            defaultOutput: defaultOutput,
            reason: .preferredBuiltInForBluetoothHeadset
        )
    }

    /// The built-in mic to try after `failedInputID` could not be used, in
    /// either selection mode. Nil when there is no built-in mic, or when the
    /// built-in mic is the one that just failed. With the lid closed the
    /// laptop's own mic is cut off in hardware and would record silence
    /// without ever failing, so only a display or other built-in mic counts.
    static func builtInFallbackAfterFailure(
        failedInputID: AudioDeviceID,
        defaultInput: MeetingAudioDevice,
        defaultOutput: MeetingAudioDevice?,
        availableInputs: [MeetingAudioDevice],
        lidIsClosed: Bool = false
    ) -> MeetingInputDeviceSelection? {
        let candidates = lidIsClosed
            ? availableInputs.filter { !isLaptopInternalMic($0) }
            : availableInputs
        guard let builtInInput = bestBuiltInInput(
            from: candidates,
            excluding: failedInputID
        ) else {
            return nil
        }
        return MeetingInputDeviceSelection(
            defaultInput: defaultInput,
            selectedInput: builtInInput,
            defaultOutput: defaultOutput,
            reason: .builtInFallbackAfterFailure
        )
    }

    static func preferredBuiltInFallback(
        for selectedInput: MeetingAudioDevice,
        availableInputs: [MeetingAudioDevice]
    ) -> MeetingAudioDevice? {
        guard isBluetoothHeadsetInput(selectedInput) else { return nil }
        return preferredBuiltInInput(from: availableInputs, defaultInput: selectedInput)
    }

    private static func shouldAvoidBluetoothHeadsetInput(
        _ defaultInput: MeetingAudioDevice,
        defaultOutput: MeetingAudioDevice?
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
        from availableInputs: [MeetingAudioDevice],
        defaultInput: MeetingAudioDevice
    ) -> MeetingAudioDevice? {
        bestBuiltInInput(from: availableInputs, excluding: defaultInput.id)
    }

    private static func bestBuiltInInput(
        from availableInputs: [MeetingAudioDevice],
        excluding excludedInputID: AudioDeviceID
    ) -> MeetingAudioDevice? {
        availableInputs
            .filter { $0.id != excludedInputID }
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

    /// The mic inside a laptop's lid, the one closing the lid silences.
    static func isLaptopInternalMic(_ device: MeetingAudioDevice) -> Bool {
        let rank = builtInInputRank(device)
        return rank == 0 || rank == 1
    }

    private static func builtInInputRank(_ device: MeetingAudioDevice) -> Int {
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

    private static func isBluetoothHeadsetInput(_ device: MeetingAudioDevice) -> Bool {
        isBluetoothTransport(device.transport) || isBluetoothHeadsetName(normalize(device.name))
    }

    private static func isBluetoothAudioDevice(_ device: MeetingAudioDevice) -> Bool {
        isBluetoothTransport(device.transport) || isBluetoothHeadsetName(normalize(device.name))
    }

    private static func isBluetoothTransport(_ transport: MeetingAudioTransport) -> Bool {
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

    private static func normalize(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

private enum MeetingInputDeviceLookup {
    static func preferredInputSelection(
        mode: MeetingInputDeviceSelectionMode
    ) throws -> MeetingInputDeviceSelection {
        let defaultInputID = try AudioObjectID.readDefaultInputDevice()
        var availableInputs = try allInputDevices()

        let defaultInput: MeetingAudioDevice
        if let existingDefault = availableInputs.first(where: { $0.id == defaultInputID }) {
            defaultInput = existingDefault
        } else {
            defaultInput = try deviceDescriptor(for: defaultInputID, inputChannelCount: 1)
            availableInputs.append(defaultInput)
        }

        let defaultOutput = try? deviceDescriptor(
            for: AudioObjectID.readDefaultOutputDevice(),
            inputChannelCount: 0
        )

        return MeetingInputDeviceSelectionPolicy.selectionForMeetingStart(
            defaultInput: defaultInput,
            defaultOutput: defaultOutput,
            availableInputs: availableInputs,
            mode: mode
        )
    }

    static func builtInFallbackAfterFailure(
        failedInputID: AudioDeviceID?
    ) throws -> MeetingInputDeviceSelection? {
        let defaultInputID = try AudioObjectID.readDefaultInputDevice()
        let availableInputs = try allInputDevices()
        let defaultInput = try availableInputs.first(where: { $0.id == defaultInputID })
            ?? deviceDescriptor(for: defaultInputID, inputChannelCount: 1)
        let defaultOutput = try? deviceDescriptor(
            for: AudioObjectID.readDefaultOutputDevice(),
            inputChannelCount: 0
        )
        return MeetingInputDeviceSelectionPolicy.builtInFallbackAfterFailure(
            failedInputID: failedInputID ?? defaultInputID,
            defaultInput: defaultInput,
            defaultOutput: defaultOutput,
            availableInputs: availableInputs,
            lidIsClosed: MacLidState.isClosed()
        )
    }

    static func preferredBuiltInFallback(
        for selectedInput: MeetingAudioDevice
    ) throws -> MeetingAudioDevice? {
        MeetingInputDeviceSelectionPolicy.preferredBuiltInFallback(
            for: selectedInput,
            availableInputs: try allInputDevices()
        )
    }

    private static func allInputDevices() throws -> [MeetingAudioDevice] {
        try allDeviceIDs().compactMap { deviceID in
            let inputChannels = (try? channelCount(for: deviceID, scope: kAudioDevicePropertyScopeInput)) ?? 0
            guard inputChannels > 0 else { return nil }
            return try? deviceDescriptor(for: deviceID, inputChannelCount: inputChannels)
        }
    }

    private static func allDeviceIDs() throws -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0

        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID.system,
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr else {
            throw NSError(domain: "MeetingInputDeviceLookup", code: Int(status))
        }

        var devices = [AudioDeviceID](
            repeating: AudioDeviceID.unknown,
            count: Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        )

        status = AudioObjectGetPropertyData(
            AudioObjectID.system,
            &address,
            0,
            nil,
            &dataSize,
            &devices
        )
        guard status == noErr else {
            throw NSError(domain: "MeetingInputDeviceLookup", code: Int(status))
        }

        return devices.filter(\.isValid)
    }

    private static func deviceDescriptor(
        for deviceID: AudioDeviceID,
        inputChannelCount: UInt32
    ) throws -> MeetingAudioDevice {
        let name = (try? deviceID.readString(kAudioDevicePropertyDeviceNameCFString)) ?? ""
        let transport = (try? deviceID.readTransportType()).map(transportType) ?? .other

        return MeetingAudioDevice(
            id: deviceID,
            name: name.isEmpty ? "Unknown" : name,
            transport: transport,
            inputChannelCount: inputChannelCount
        )
    }

    private static func channelCount(
        for deviceID: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0

        var status = AudioObjectGetPropertyDataSize(
            deviceID,
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr else {
            throw NSError(domain: "MeetingInputDeviceLookup", code: Int(status))
        }
        guard dataSize > 0 else { return 0 }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &dataSize,
            rawPointer
        )
        guard status == noErr else {
            throw NSError(domain: "MeetingInputDeviceLookup", code: Int(status))
        }

        let bufferList = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(UInt32(0)) { total, buffer in
            total + buffer.mNumberChannels
        }
    }

    private static func transportType(_ rawValue: UInt32) -> MeetingAudioTransport {
        switch rawValue {
        case kAudioDeviceTransportTypeBuiltIn:
            return .builtIn
        case kAudioDeviceTransportTypeBluetooth:
            return .bluetooth
        case kAudioDeviceTransportTypeBluetoothLE:
            return .bluetoothLE
        case kAudioDeviceTransportTypeUSB:
            return .usb
        case kAudioDeviceTransportTypeAggregate:
            return .aggregate
        case kAudioDeviceTransportTypeVirtual:
            return .virtual
        default:
            return .other
        }
    }
}

private struct MeetingInputDeviceApplicationResult {
    let outcome: CaptureRouteStabilizationOutcome
    let didApplySelection: Bool
}

extension Audio {
    /// Pin the built-in mic for the next graph attempt because the chosen mic
    /// could not be used. Returns false, leaving the selection alone, when
    /// there is no built-in mic or it is the one that just failed.
    @discardableResult
    func pinBuiltInMeetingInputFallback(operation: String) -> Bool {
        let failedSelection = meetingInputSelectionSnapshot()
        let fallback: MeetingInputDeviceSelection?
        do {
            fallback = try MeetingInputDeviceLookup.builtInFallbackAfterFailure(
                failedInputID: failedSelection?.selectedInput.id
            )
        } catch {
            AppLogger.audioMic.warning("Built-in microphone fallback unavailable", [
                "operation": operation,
                "error": error.localizedDescription
            ])
            return false
        }
        guard let fallback else {
            AppLogger.audioMic.info("No other built-in microphone to fall back to", [
                "operation": operation,
                "failedTransport": failedSelection?.selectedInput.transport.rawValue ?? "unknown"
            ])
            return false
        }
        setMeetingInputSelection(fallback)
        AppLogger.audioMic.warning("Falling back to the built-in microphone", [
            "operation": operation,
            "failedTransport": failedSelection?.selectedInput.transport.rawValue ?? "unknown",
            "selectedTransport": fallback.selectedInput.transport.rawValue
        ])
        return true
    }

    @discardableResult
    func applyMeetingInputDevice(
        to inputNode: AVAudioInputNode,
        operation: String,
        routeWasUnstable: Bool = false
    ) -> CaptureRouteStabilizationOutcome {
        var selection = meetingInputSelectionSnapshot()
        if selection == nil {
            do {
                selection = try MeetingInputDeviceLookup.preferredInputSelection(
                    mode: meetingInputDeviceSelectionModeForCurrentRecording
                )
            } catch {
                AppLogger.audioMic.warning("Meeting input selection unavailable", [
                    "operation": operation,
                    "error": error.localizedDescription
                ])
                return MeetingInputDeviceSelectionPolicy.outcomeAfterLookupFailure(
                    mode: meetingInputDeviceSelectionModeForCurrentRecording
                )
            }
        }

        guard let selection else {
            AppLogger.audioMic.warning("Meeting input selection unavailable", [
                "operation": operation
            ])
            return MeetingInputDeviceSelectionPolicy.outcomeAfterLookupFailure(
                mode: meetingInputDeviceSelectionModeForCurrentRecording
            )
        }

        var stabilizationOutcome = CaptureRouteStabilizationOutcome.notNeeded
        let stabilizationAlreadyAttempted = meetingRouteStabilizationOutcomeValue != CaptureRouteStabilizationOutcome.notNeeded.rawValue
        if MeetingInputDeviceSelectionPolicy.shouldAttemptBuiltInStabilization(
            routeWasUnstable: routeWasUnstable,
            selectedInput: selection.selectedInput,
            stabilizationAlreadyAttempted: stabilizationAlreadyAttempted
        ) {
            do {
                guard let builtInInput = try MeetingInputDeviceLookup.preferredBuiltInFallback(
                    for: selection.selectedInput
                ) else {
                    stabilizationOutcome = .builtInUnavailable
                    recordMeetingRouteStabilizationAttempt(outcome: stabilizationOutcome)
                    AppLogger.audioMic.warning("Bluetooth meeting input stayed selected after route instability", [
                        "operation": operation,
                        "outcome": stabilizationOutcome.rawValue
                    ])
                    emitMeetingRouteStabilityWarningIfNeeded(outcome: stabilizationOutcome)
                    return applySelectedMeetingInputDevice(
                        selection: selection,
                        to: inputNode,
                        operation: operation,
                        stabilizationOutcome: stabilizationOutcome
                    ).outcome
                }

                let fallbackSelection = MeetingInputDeviceSelection(
                    defaultInput: selection.defaultInput,
                    selectedInput: builtInInput,
                    defaultOutput: selection.defaultOutput,
                    reason: .preferredBuiltInForBluetoothHeadset
                )
                stabilizationOutcome = .switchedToBuiltIn
                recordMeetingRouteStabilizationAttempt(outcome: stabilizationOutcome)

                let application = applySelectedMeetingInputDevice(
                    selection: fallbackSelection,
                    to: inputNode,
                    operation: operation,
                    stabilizationOutcome: stabilizationOutcome
                )
                let outcome = application.outcome
                // Keep the original Bluetooth selection pinned until the
                // fallback is actually applied. A failed setDeviceID must
                // not turn the next recovery into another built-in loop.
                setMeetingInputSelection(
                    MeetingInputDeviceSelectionPolicy.selectionAfterStabilizationAttempt(
                        pinnedSelection: selection,
                        attemptedSelection: fallbackSelection,
                        outcome: outcome
                    )
                )
                if routeWasUnstable, outcome != .notNeeded {
                    emitMeetingRouteStabilityWarningIfNeeded(outcome: outcome)
                }
                return outcome
            } catch {
                stabilizationOutcome = .builtInUnavailable
                recordMeetingRouteStabilizationAttempt(outcome: stabilizationOutcome)
                AppLogger.audioMic.warning("Bluetooth meeting input fallback unavailable", [
                    "operation": operation,
                    "outcome": stabilizationOutcome.rawValue,
                    "error": error.localizedDescription
                ])
            }
        }

        let application = applySelectedMeetingInputDevice(
            selection: selection,
            to: inputNode,
            operation: operation,
            stabilizationOutcome: stabilizationOutcome
        )
        if let persistedSelection = MeetingInputDeviceSelectionPolicy.selectionAfterApplicationAttempt(
            currentSelection: meetingInputSelectionSnapshot(),
            attemptedSelection: selection,
            didApplySelection: application.didApplySelection
        ) {
            setMeetingInputSelection(persistedSelection)
        }
        let outcome = application.outcome
        if routeWasUnstable, outcome != .notNeeded {
            emitMeetingRouteStabilityWarningIfNeeded(outcome: outcome)
        }
        return outcome
    }

    private func applySelectedMeetingInputDevice(
        selection: MeetingInputDeviceSelection,
        to inputNode: AVAudioInputNode,
        operation: String,
        stabilizationOutcome: CaptureRouteStabilizationOutcome
    ) -> MeetingInputDeviceApplicationResult {
        guard inputNode.auAudioUnit.deviceID != selection.selectedInput.id else {
            if selection.didOverrideDefault {
                AppLogger.audioMic.info("Meeting input pinned to selected microphone", [
                    "operation": operation,
                    "reason": selection.reason.rawValue,
                    "selectedTransport": selection.selectedInput.transport.rawValue,
                    "stabilizationOutcome": stabilizationOutcome.rawValue
                ])
            }
            return MeetingInputDeviceApplicationResult(
                outcome: stabilizationOutcome,
                didApplySelection: true
            )
        }

        do {
            try inputNode.auAudioUnit.setDeviceID(selection.selectedInput.id)
            let message = selection.didOverrideDefault
                ? "Meeting input pinned to selected microphone"
                : "Meeting input synced to selected microphone"
            AppLogger.audioMic.info(message, [
                "operation": operation,
                "reason": selection.reason.rawValue,
                "selectedTransport": selection.selectedInput.transport.rawValue,
                "stabilizationOutcome": stabilizationOutcome.rawValue
            ])
            return MeetingInputDeviceApplicationResult(
                outcome: stabilizationOutcome,
                didApplySelection: true
            )
        } catch {
            let outcome = MeetingInputDeviceSelectionPolicy.outcomeAfterApplicationFailure(
                selectionReason: selection.reason,
                requestedOutcome: stabilizationOutcome
            )
            // An explicit-device bind failure aborts this graph attempt too,
            // but is not evidence of a failed Bluetooth-to-built-in switch.
            if outcome == .switchFailed,
               selection.reason == .preferredBuiltInForBluetoothHeadset {
                setMeetingRouteStabilizationOutcome(.switchFailed)
                let retryableLifecycleOperation = operation.hasPrefix("start_recording")
                    || operation.hasPrefix("device_recovery")
                if !retryableLifecycleOperation {
                    emitMeetingRouteStabilityWarningIfNeeded(outcome: .switchFailed)
                }
            }
            AppLogger.audioMic.warning("Meeting input selection failed", [
                "operation": operation,
                "reason": selection.reason.rawValue,
                "error": error.localizedDescription
            ])
            return MeetingInputDeviceApplicationResult(
                outcome: outcome,
                didApplySelection: false
            )
        }
    }
}

/// Whether a laptop's lid is closed (clamshell mode on an external display).
/// False on desktops and whenever the state can't be read, so a failed read
/// never hides a mic.
enum MacLidState {
    static func isClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != IO_OBJECT_NULL else { return false }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(
            service,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() else { return false }
        return (value as? Bool) ?? false
    }
}
