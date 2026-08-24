import Foundation
import AudioToolbox

// MARK: - Constants

extension AudioObjectID {
    /// Convenience for `kAudioObjectSystemObject`.
    static let system = AudioObjectID(kAudioObjectSystemObject)
    /// Convenience for `kAudioObjectUnknown`.
    static let unknown = kAudioObjectUnknown

    /// `true` if this object has the value of `kAudioObjectUnknown`.
    var isUnknown: Bool { self == .unknown }

    /// `false` if this object has the value of `kAudioObjectUnknown`.
    var isValid: Bool { !isUnknown }
}

// MARK: - Concrete Property Helpers

extension AudioObjectID {
    /// Reads the value for `kAudioHardwarePropertyDefaultSystemOutputDevice`.
    public static func readDefaultSystemOutputDevice() throws -> AudioDeviceID {
        try AudioDeviceID.system.readDefaultSystemOutputDevice()
    }

    /// Reads the value for `kAudioHardwarePropertyDefaultOutputDevice`.
    public static func readDefaultOutputDevice() throws -> AudioDeviceID {
        try AudioDeviceID.system.readDefaultOutputDevice()
    }

    /// Reads the value for `kAudioHardwarePropertyDefaultInputDevice`.
    public static func readDefaultInputDevice() throws -> AudioDeviceID {
        try AudioObjectID.system.readDefaultInputDevice()
    }

    /// Reads the value for `kAudioHardwarePropertyDefaultSystemOutputDevice`, should only be called on the system object.
    func readDefaultSystemOutputDevice() throws -> AudioDeviceID {
        try requireSystemObject()

        return try read(kAudioHardwarePropertyDefaultSystemOutputDevice, defaultValue: AudioDeviceID.unknown)
    }

    /// Reads the value for `kAudioHardwarePropertyDefaultOutputDevice`, should only be called on the system object.
    func readDefaultOutputDevice() throws -> AudioDeviceID {
        try requireSystemObject()

        return try read(kAudioHardwarePropertyDefaultOutputDevice, defaultValue: AudioDeviceID.unknown)
    }

    /// Reads the value for `kAudioHardwarePropertyDefaultInputDevice`, should only be called on the system object.
    func readDefaultInputDevice() throws -> AudioDeviceID {
        try requireSystemObject()

        return try read(kAudioHardwarePropertyDefaultInputDevice, defaultValue: AudioDeviceID.unknown)
    }

    /// Reads the nominal sample rate of an audio device via `kAudioDevicePropertyNominalSampleRate`.
    /// Returns the rate the device is configured to operate at (e.g. 24000, 44100, 48000, 96000).
    func readNominalSampleRate() throws -> Float64 {
        try read(kAudioDevicePropertyNominalSampleRate, defaultValue: Float64(0))
    }

    /// Reads the coarse transport type for a device without exposing its name or UID.
    func readTransportType() throws -> UInt32 {
        try read(kAudioDevicePropertyTransportType, defaultValue: UInt32(kAudioDeviceTransportTypeUnknown))
    }

    /// Reads the device's scalar volume for the requested scope.
    /// Returns the hardware value only; this never writes or adjusts volume.
    func readVolumeScalar(scope: AudioObjectPropertyScope) throws -> Float32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(self, &address) else {
            throw "Volume scalar unavailable for \(address)"
        }
        return try read(address, defaultValue: Float32.nan)
    }

    private func requireSystemObject() throws {
        if self != .system { throw "Only supported for the system object." }
    }
}

// MARK: - Generic Property Access

extension AudioObjectID {
    func read<T>(_ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                    defaultValue: T) throws -> T
    {
        try read(AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element), defaultValue: defaultValue)
    }

    func read<T>(_ address: AudioObjectPropertyAddress, defaultValue: T) throws -> T {
        try read(address, defaultValue: defaultValue, inQualifierSize: 0, inQualifierData: nil)
    }

    public func readString(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) throws -> String {
        try read(AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element), defaultValue: "" as CFString) as String
    }

    private func read<T>(_ inAddress: AudioObjectPropertyAddress, defaultValue: T, inQualifierSize: UInt32 = 0, inQualifierData: UnsafeRawPointer? = nil) throws -> T {
        var address = inAddress

        var dataSize: UInt32 = 0

        var err = AudioObjectGetPropertyDataSize(self, &address, inQualifierSize, inQualifierData, &dataSize)

        guard err == noErr else {
            throw "Error reading data size for \(inAddress): \(err)"
        }

        var value: T = defaultValue
        err = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(self, &address, inQualifierSize, inQualifierData, &dataSize, ptr)
        }

        guard err == noErr else {
            throw "Error reading data for \(inAddress): \(err)"
        }

        return value
    }
}

// MARK: - String Error Support

extension String: @retroactive LocalizedError {
    public var errorDescription: String? { self }
}

// MARK: - Debugging Helpers

private extension UInt32 {
    var fourCharString: String {
        String(cString: [
            UInt8((self >> 24) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8(self & 0xFF),
            0
        ])
    }
}

extension AudioObjectPropertyAddress: @retroactive CustomStringConvertible {
    public var description: String {
        let elementDescription = mElement == kAudioObjectPropertyElementMain ? "main" : mElement.fourCharString
        return "\(mSelector.fourCharString)/\(mScope.fourCharString)/\(elementDescription)"
    }
}
