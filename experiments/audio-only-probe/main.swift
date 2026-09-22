import AppKit
import AVFoundation
import CoreAudio

// Standalone permission experiment. No ScreenCaptureKit or microphone access.
// Inspect aggregate input samples, retaining only frame counts and peak level.
final class Probe: NSObject, NSApplicationDelegate {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 580, height: 220), styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let status = NSTextField(wrappingLabelWithString: "Play audio from another app, then click Test. This checks eight seconds of system audio without saving recordings.")
    let queue = DispatchQueue(label: "AudioOnlyProbe.samples")
    var tap: AudioObjectID = 0
    var device: AudioObjectID = 0
    var proc: AudioDeviceIOProcID?
    var frames: UInt64 = 0
    var peak: Float = 0
    var button: NSButton!
#if PRODUCTION_CAPTURE
    let productionCapture = CoreAudioSystemAudioCapture()
#endif

    func applicationDidFinishLaunching(_ notification: Notification) {
        window.title = "Transcripted Audio-Only Probe"
        status.frame = NSRect(x: 20, y: 85, width: 540, height: 115)
        button = NSButton(title: "Test system audio only", target: self, action: #selector(runTest))
        button.frame = NSRect(x: 20, y: 25, width: 240, height: 40)
        window.contentView?.addSubview(status)
        window.contentView?.addSubview(button)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func check(_ value: OSStatus, _ operation: String) throws {
        if value != noErr { throw NSError(domain: operation, code: Int(value)) }
    }

    @objc func runTest() {
        button.isEnabled = false
        status.stringValue = "Starting Core Audio tap… Approve System Audio Recording if macOS asks."
        do {
#if PRODUCTION_CAPTURE
            frames = 0
            peak = 0
            try productionCapture.prepare()
            try productionCapture.start { [weak self] buffer in
                guard let self else { return }
                self.queue.sync {
                    self.frames += UInt64(buffer.frameLength)
                    for audioBuffer in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                        guard let data = audioBuffer.mData else { continue }
                        let values = data.assumingMemoryBound(to: Float.self)
                        for index in 0 ..< Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size {
                            let value = abs(values[index])
                            if value.isFinite { self.peak = max(self.peak, value) }
                        }
                    }
                }
            }
#else
            let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
            description.uuid = UUID()
            description.isPrivate = true
            description.muteBehavior = .unmuted
            try check(AudioHardwareCreateProcessTap(description, &tap), "create tap")
            var formatDescription = AudioStreamBasicDescription()
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &formatDescription), "read tap format")
            guard let format = AVAudioFormat(streamDescription: &formatDescription), format.commonFormat == .pcmFormatFloat32 else {
                throw NSError(domain: "unsupported tap format", code: 1)
            }
            let properties: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Transcripted Audio Only Probe",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: false,
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]]
            ]
            try check(AudioHardwareCreateAggregateDevice(properties as CFDictionary, &device), "create aggregate")
            frames = 0
            peak = 0
            try check(AudioDeviceCreateIOProcIDWithBlock(&proc, device, queue) { [weak self] _, input, _, _, _ in
                guard let self, let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
                self.frames += UInt64(buffer.frameLength)
                for audioBuffer in UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)) {
                    guard let data = audioBuffer.mData else { continue }
                    let values = data.assumingMemoryBound(to: Float.self)
                    for index in 0 ..< Int(audioBuffer.mDataByteSize) / MemoryLayout<Float>.size {
                        let value = abs(values[index])
                        if value.isFinite { self.peak = max(self.peak, value) }
                    }
                }
            }, "create IO callback")
            try check(AudioDeviceStart(device, proc), "start aggregate")
#endif
            status.stringValue = "Listening to system audio for eight seconds… No audio file is being saved."
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { self.finish() }
        } catch {
            cleanup()
            status.stringValue = "FAILED: \(error.localizedDescription)"
            button.isEnabled = true
        }
    }

    func finish() {
        cleanup()
        let result = queue.sync { (frames, peak) }
        status.stringValue = "\(result.1 > 0.0001 ? "PASS: audible system audio received" : "INCONCLUSIVE: no audible signal")\nFrames: \(result.0)\nPeak: \(result.1)\nCore Audio only; no ScreenCaptureKit or microphone."
        button.isEnabled = true
    }

    func cleanup() {
#if PRODUCTION_CAPTURE
        productionCapture.stopSync()
#else
        if device != 0 {
            if let proc {
                AudioDeviceStop(device, proc)
                AudioDeviceDestroyIOProcID(device, proc)
            }
            AudioHardwareDestroyAggregateDevice(device)
        }
        if tap != 0 { AudioHardwareDestroyProcessTap(tap) }
        proc = nil
        device = 0
        tap = 0
#endif
    }
    func applicationWillTerminate(_ notification: Notification) { cleanup() }
}

let app = NSApplication.shared
let delegate = Probe()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
