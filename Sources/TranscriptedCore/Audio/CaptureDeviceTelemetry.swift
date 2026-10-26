import Foundation
import CoreAudio
import AudioToolbox

/// Route and device state the capture telemetry compares once a second and
/// on every listener event. Session-local object IDs, transport classes and
/// formats only: never device names or UIDs.
struct CaptureEndpointTelemetry: Equatable {
    var id: AudioObjectID
    var transport: String
    var rate: Double
    var alive: Bool
    var running: Bool
    var streams: Int
    var channels: Int
    var format: String

    func fields(prefix: String) -> [String: String] {
        [
            "\(prefix)_id": "\(id)",
            "\(prefix)_class": transport,
            "\(prefix)_rate": "\(Int(rate.rounded()))",
            "\(prefix)_alive": "\(alive)",
            "\(prefix)_running": "\(running)",
            "\(prefix)_streams": "\(streams)",
            "\(prefix)_channels": "\(channels)",
            "\(prefix)_fmt": format
        ]
    }
}

struct CaptureDeviceTelemetryState: Equatable {
    var output: CaptureEndpointTelemetry?
    var input: CaptureEndpointTelemetry?
    var aggregate: CaptureEndpointTelemetry?
    var processesRunningOutput = 0
    var processesRunningInput = 0
    var zoomRunningOutput = false
    var zoomRunningInput = false

    var fields: [String: String] {
        var result: [String: String] = [
            "procs_out": "\(processesRunningOutput)",
            "procs_in": "\(processesRunningInput)",
            "zoom_out": "\(zoomRunningOutput)",
            "zoom_in": "\(zoomRunningInput)"
        ]
        for (prefix, endpoint) in [("out", output), ("in", input), ("agg", aggregate)] {
            if let endpoint { result.merge(endpoint.fields(prefix: prefix)) { $1 } } else { result["\(prefix)_id"] = "none" }
        }
        return result
    }

    /// Only the fields that changed, as `old->new`. Empty when equal.
    static func changes(from old: CaptureDeviceTelemetryState?, to new: CaptureDeviceTelemetryState) -> [String: String] {
        guard let old else { return new.fields }
        let before = old.fields
        return new.fields.reduce(into: [String: String]()) { result, pair in
            let previous = before[pair.key] ?? "none"
            if previous != pair.value { result[pair.key] = "\(previous)->\(pair.value)" }
        }
    }
}

/// Watches the default output and input devices, the tap's aggregate device
/// and the process list on its own utility queue, so slow HAL reads never
/// delay the tap drain. Logs once per change.
final class CaptureDeviceTelemetryObserver: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Transcripted.CaptureDeviceTelemetry", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var aggregate: AudioObjectID = 0
    private var last: CaptureDeviceTelemetryState?
    private var watched: [(object: AudioObjectID, address: AudioObjectPropertyAddress)] = []
    private var listener: AudioObjectPropertyListenerBlock?
    private let ownPID = getpid()

    /// No default-input listener: Core Audio rules keep that to
    /// `DefaultInputDeviceMonitor` in the app target. The 1 s poll reads it
    /// through `readDefaultInputDevice()` instead.
    private static let systemSelectors: [AudioObjectPropertySelector] = [
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyProcessObjectList
    ]
    private static let deviceSelectors: [AudioObjectPropertySelector] = [
        kAudioDevicePropertyNominalSampleRate,
        kAudioDevicePropertyDeviceIsAlive,
        kAudioDevicePropertyDeviceIsRunningSomewhere,
        kAudioDevicePropertyStreams,
        kAudioDevicePropertyStreamConfiguration
    ]

    func start(aggregate id: AudioObjectID) {
        queue.async { [self] in
            aggregate = id
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, addresses in
                self?.poll(trigger: CaptureDeviceTelemetryObserver.fourCC(addresses.pointee.mSelector))
            }
            listener = block
            for selector in CaptureDeviceTelemetryObserver.systemSelectors { add(.system, selector) }
            poll(trigger: "start")
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 1, repeating: 1)
            timer.setEventHandler { [weak self] in self?.poll(trigger: nil) }
            self.timer = timer
            timer.resume()
        }
    }

    /// The tap rebuilt onto a new aggregate device.
    func noteAggregate(_ id: AudioObjectID) {
        queue.async { [self] in
            guard id != aggregate else { return }
            aggregate = id
            poll(trigger: "rebuild")
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
            removeAll()
            listener = nil
            last = nil
        }
    }

    private func poll(trigger: String?) {
        guard listener != nil else { return }
        let state = Self.readState(aggregate: aggregate, excluding: ownPID)
        let changes = CaptureDeviceTelemetryState.changes(from: last, to: state)
        if last == nil || [state.output?.id, state.input?.id, state.aggregate?.id] != [last?.output?.id, last?.input?.id, last?.aggregate?.id] {
            rewatchDevices(state)
        }
        guard !changes.isEmpty else { return }
        last = state
        var fields = changes
        fields["trigger"] = trigger ?? "poll"
        AppLogger.audioSystem.info("Capture route state changed", fields)
    }

    private func rewatchDevices(_ state: CaptureDeviceTelemetryState) {
        removeAll(keepSystem: true)
        for id in Set([state.output?.id, state.input?.id, state.aggregate?.id].compactMap { $0 }) {
            for selector in CaptureDeviceTelemetryObserver.deviceSelectors { add(id, selector) }
        }
    }

    private func add(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) {
        guard let listener else { return }
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeWildcard, mElement: kAudioObjectPropertyElementWildcard)
        guard AudioObjectAddPropertyListenerBlock(object, &address, queue, listener) == noErr else { return }
        watched.append((object, address))
    }

    private func removeAll(keepSystem: Bool = false) {
        guard let listener else { watched = []; return }
        watched.removeAll { entry in
            guard !(keepSystem && entry.object == .system) else { return false }
            var address = entry.address
            AudioObjectRemovePropertyListenerBlock(entry.object, &address, queue, listener)
            return true
        }
    }

    // MARK: - HAL reads

    static func readState(aggregate: AudioObjectID, excluding ownPID: pid_t) -> CaptureDeviceTelemetryState {
        var state = CaptureDeviceTelemetryState()
        state.output = (try? AudioObjectID.readDefaultOutputDevice()).flatMap { endpoint($0, scope: kAudioObjectPropertyScopeOutput) }
        state.input = (try? AudioObjectID.readDefaultInputDevice()).flatMap { endpoint($0, scope: kAudioObjectPropertyScopeInput) }
        state.aggregate = aggregate.isValid ? endpoint(aggregate, scope: kAudioObjectPropertyScopeInput) : nil
        for process in objectList(.system, kAudioHardwarePropertyProcessObjectList, scope: kAudioObjectPropertyScopeGlobal) {
            if (try? process.read(kAudioProcessPropertyPID, defaultValue: pid_t(0))) == ownPID { continue }
            let output = ((try? process.read(kAudioProcessPropertyIsRunningOutput, defaultValue: UInt32(0))) ?? 0) != 0
            let input = ((try? process.read(kAudioProcessPropertyIsRunningInput, defaultValue: UInt32(0))) ?? 0) != 0
            guard output || input else { continue }
            if output { state.processesRunningOutput += 1 }
            if input { state.processesRunningInput += 1 }
            let isZoom = (try? process.readString(kAudioProcessPropertyBundleID))?.hasPrefix("us.zoom") == true
            if isZoom, output { state.zoomRunningOutput = true }
            if isZoom, input { state.zoomRunningInput = true }
        }
        return state
    }

    private static func endpoint(_ id: AudioObjectID, scope: AudioObjectPropertyScope) -> CaptureEndpointTelemetry? {
        guard id.isValid else { return nil }
        let streams = objectList(id, kAudioDevicePropertyStreams, scope: scope)
        var channels = 0
        var format = "none"
        for (index, stream) in streams.enumerated() {
            guard let asbd = try? stream.read(kAudioStreamPropertyPhysicalFormat, defaultValue: AudioStreamBasicDescription()) else { continue }
            channels += Int(asbd.mChannelsPerFrame)
            if index == 0 {
                let kind = asbd.mFormatFlags & AudioFormatFlags(kAudioFormatFlagIsFloat) != 0 ? "f" : "i"
                format = "\(Int(asbd.mSampleRate.rounded()))/\(asbd.mChannelsPerFrame)ch/\(kind)\(asbd.mBitsPerChannel)"
            }
        }
        return CaptureEndpointTelemetry(
            id: id,
            transport: transportClass((try? id.readTransportType()) ?? UInt32(kAudioDeviceTransportTypeUnknown)),
            rate: (try? id.readNominalSampleRate()) ?? 0,
            alive: (try? id.readIsAlive()) ?? false,
            running: ((try? id.read(kAudioDevicePropertyDeviceIsRunningSomewhere, defaultValue: UInt32(0))) ?? 0) != 0,
            streams: streams.count,
            channels: channels,
            format: format
        )
    }

    private static func objectList(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var list = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &list) == noErr else { return [] }
        return Array(list.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func transportClass(_ transport: UInt32) -> String {
        switch transport {
        case UInt32(kAudioDeviceTransportTypeBuiltIn): "built_in"
        case UInt32(kAudioDeviceTransportTypeBluetooth), UInt32(kAudioDeviceTransportTypeBluetoothLE): "bluetooth"
        case UInt32(kAudioDeviceTransportTypeUSB): "usb"
        case UInt32(kAudioDeviceTransportTypeAggregate), UInt32(kAudioDeviceTransportTypeAutoAggregate): "aggregate"
        case UInt32(kAudioDeviceTransportTypeVirtual): "virtual"
        case UInt32(kAudioDeviceTransportTypeUnknown): "unknown"
        default: "other"
        }
    }

    static func fourCC(_ selector: AudioObjectPropertySelector) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((selector >> UInt32($0)) & 0xFF) }
        guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return "\(selector)" }
        return String(decoding: bytes, as: UTF8.self)
    }
}
