import Foundation
import CoreAudio
import AppKit

@available(macOS 26.0, *)
class MicrophoneMonitor: NSObject {
    private var audio: Audio?
    private weak var floatingPanel: FloatingPanelController?
    private var monitoredDevices: [AudioDeviceID] = []
    private var debounceTimer: Timer?
    private let debounceDelay: TimeInterval = 5.0 // Wait 5 seconds before showing notification

    init(audio: Audio, floatingPanel: FloatingPanelController?) {
        self.audio = audio
        self.floatingPanel = floatingPanel
        super.init()

        startMonitoring()
    }

    deinit {
        stopMonitoring()
    }

    private func startMonitoring() {
        // Setup CoreAudio run loop for property notifications
        setupCoreAudioRunLoop()

        // Get all input devices and add listeners
        let inputDevices = getInputDevices()
        print("📡 Monitoring \(inputDevices.count) audio input device(s)")

        for deviceID in inputDevices {
            addDeviceRunningListener(deviceID: deviceID)

            // Log device name for debugging
            if let deviceName = getDeviceName(deviceID: deviceID) {
                print("  → \(deviceName) (ID: \(deviceID))")
            }
        }
    }

    private func stopMonitoring() {
        // Remove all property listeners
        for deviceID in monitoredDevices {
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )

            AudioObjectRemovePropertyListener(
                deviceID,
                &address,
                audioDevicePropertyListener,
                Unmanaged.passUnretained(self).toOpaque()
            )
        }

        monitoredDevices.removeAll()
        debounceTimer?.invalidate()
    }

    private func setupCoreAudioRunLoop() {
        // Set CoreAudio to use main run loop for property notifications
        var runLoop: CFRunLoop? = CFRunLoopGetMain()
        var runLoopAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyRunLoop,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let size = UInt32(MemoryLayout<CFRunLoop>.size)
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &runLoopAddress,
            0,
            nil,
            size,
            &runLoop
        )
    }

    private func getInputDevices() -> [AudioDeviceID] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize
        ) == noErr else {
            print("❌ Failed to get audio devices size")
            return []
        }

        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceIDs
        ) == noErr else {
            print("❌ Failed to get audio devices")
            return []
        }

        // Filter for input devices only
        return deviceIDs.filter { isInputDevice($0) }
    }

    private func isInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &propertySize
        )

        return status == noErr && propertySize > 0
    }

    private func getDeviceName(deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var deviceName: CFString = "" as CFString
        var propertySize = UInt32(MemoryLayout<CFString>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0,
            nil,
            &propertySize,
            &deviceName
        )

        return status == noErr ? (deviceName as String) : nil
    }

    private func addDeviceRunningListener(deviceID: AudioDeviceID) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectAddPropertyListener(
            deviceID,
            &address,
            audioDevicePropertyListener,
            Unmanaged.passUnretained(self).toOpaque()
        )

        if status == noErr {
            monitoredDevices.append(deviceID)
        } else {
            print("❌ Failed to add listener for device \(deviceID), status: \(status)")
        }
    }

    fileprivate func handleDeviceStateChange(deviceID: AudioDeviceID) {
        let isRunning = isDeviceRunning(deviceID: deviceID)
        let deviceName = getDeviceName(deviceID: deviceID) ?? "Unknown Device"

        if isRunning {
            print("🎤 Microphone activated: \(deviceName)")

            // Only show notification if not already recording or processing
            guard audio?.isBusy == false else {
                print("⚠️ App is busy (recording or processing), skipping notification")
                return
            }

            // Debounce: Wait a bit to avoid false positives from brief mic usage
            debounceTimer?.invalidate()
            debounceTimer = Timer.scheduledTimer(withTimeInterval: debounceDelay, repeats: false) { [weak self] _ in
                // Check again if mic is still active and we're not busy
                if self?.isDeviceRunning(deviceID: deviceID) == true,
                   self?.audio?.isBusy == false {
                    self?.showNotification(deviceName: deviceName)
                } else {
                    print("⚠️ Mic stopped or app became busy before debounce timer, skipping notification")
                }
            }
        } else {
            print("🎤 Microphone deactivated: \(deviceName)")

            // Cancel pending notification if mic stopped
            debounceTimer?.invalidate()
        }
    }

    private func isDeviceRunning(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var isRunning: UInt32 = 0
        var propertySize = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &propertySize,
            &isRunning
        )

        return status == noErr && isRunning == 1
    }

    private func showNotification(deviceName: String) {
        print("✓ Showing microphone banner for: \(deviceName)")
        floatingPanel?.showMicrophoneBanner()
    }
}

// MARK: - C Callback for CoreAudio

@available(macOS 26.0, *)
private func audioDevicePropertyListener(
    inObjectID: AudioObjectID,
    inNumberAddresses: UInt32,
    inAddresses: UnsafePointer<AudioObjectPropertyAddress>,
    inClientData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let clientData = inClientData else {
        return noErr
    }

    let monitor = Unmanaged<MicrophoneMonitor>.fromOpaque(clientData).takeUnretainedValue()

    // Handle on main thread for safety
    DispatchQueue.main.async {
        monitor.handleDeviceStateChange(deviceID: inObjectID)
    }

    return noErr
}
