import AudioToolbox
@preconcurrency import AVFoundation
import Foundation

enum MeetingAudioTransport: String {
    case builtIn
    case bluetooth
    case bluetoothLE
    case usb
    case aggregate
    case virtual
    case other
}

enum MeetingInputDeviceSelectionMode: String {
    case automatic
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
    /// Meeting capture must not pin the same Bluetooth headset input used by a
    /// call app. That HFP route can leave the other app unable to transmit mic
    /// audio until Transcripted quits. Prefer a built-in input at meeting start
    /// while leaving USB and other safe defaults unchanged.
    static func selectionForMeetingStart(
        defaultInput: MeetingAudioDevice,
        defaultOutput: MeetingAudioDevice?,
        availableInputs: [MeetingAudioDevice]
    ) -> MeetingInputDeviceSelection {
        selection(
            defaultInput: defaultInput,
            defaultOutput: defaultOutput,
            availableInputs: availableInputs,
            mode: .automatic
        )
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

    static func outcomeAfterApplicationFailure(
        selectionReason: MeetingInputDeviceSelectionReason,
        requestedOutcome: CaptureRouteStabilizationOutcome
    ) -> CaptureRouteStabilizationOutcome {
        selectionReason == .preferredBuiltInForBluetoothHeadset
            ? .switchFailed
            : requestedOutcome
    }

    static func selection(
        defaultInput: MeetingAudioDevice,
        defaultOutput: MeetingAudioDevice?,
        availableInputs: [MeetingAudioDevice],
        mode: MeetingInputDeviceSelectionMode = .automatic
    ) -> MeetingInputDeviceSelection {
        guard shouldAvoidBluetoothHeadsetInput(defaultInput, defaultOutput: defaultOutput) else {
            return MeetingInputDeviceSelection(
                defaultInput: defaultInput,
                selectedInput: defaultInput,
                defaultOutput: defaultOutput,
                reason: .defaultIsSafe
            )
        }

        guard mode == .automatic else {
            return MeetingInputDeviceSelection(
                defaultInput: defaultInput,
                selectedInput: defaultInput,
                defaultOutput: defaultOutput,
                reason: .preservedDefaultInput
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
    static func preferredInputSelection() throws -> MeetingInputDeviceSelection {
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
            availableInputs: availableInputs
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
    @discardableResult
    func applyMeetingInputDevice(
        to inputNode: AVAudioInputNode,
        operation: String,
        routeWasUnstable: Bool = false
    ) -> CaptureRouteStabilizationOutcome {
        var selection = meetingInputSelectionSnapshot()
        if selection == nil {
            do {
                selection = try MeetingInputDeviceLookup.preferredInputSelection()
            } catch {
                AppLogger.audioMic.warning("Meeting input selection unavailable", [
                    "operation": operation,
                    "error": error.localizedDescription
                ])
                return .notNeeded
            }
        }

        guard let selection else {
            AppLogger.audioMic.warning("Meeting input selection unavailable", [
                "operation": operation
            ])
            return .notNeeded
        }

        var stabilizationOutcome = CaptureRouteStabilizationOutcome.notNeeded
        let stabilizationAlreadyAttempted = meetingRouteStabilizationOutcomeValue != CaptureRouteStabilizationOutcome.notNeeded.rawValue
        let selectedInputIsBluetooth = selection.selectedInput.transport == .bluetooth
            || selection.selectedInput.transport == .bluetoothLE

        if routeWasUnstable, selectedInputIsBluetooth, !stabilizationAlreadyAttempted {
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
            if outcome == .switchFailed {
                setMeetingRouteStabilizationOutcome(.switchFailed)
                emitMeetingRouteStabilityWarningIfNeeded(outcome: .switchFailed)
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
