// ParakeetEngine.swift
// FluidAudio-based STT engine — CoreML Parakeet TDT V3 for batch transcription.
// AVAudioEngine tap → NSLock-batched samples → resampled to 16kHz → AsrManager.transcribe()
// for final batch inference.

import AppKit
@preconcurrency import AVFoundation
import Combine
import CoreAudio
import FluidAudio
import Foundation
import TranscriptedCore

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

private enum InputDeviceLookupError: Error {
    case propertyReadFailed(OSStatus)
    case unknownDevice
}

private enum CoreAudioInputDeviceLookup {
    static func preferredDictationInputSelection() throws -> DictationInputDeviceSelection {
        let defaultInputID = try defaultInputDeviceID()
        var availableInputs = try allInputDevices()

        let defaultInput: DictationAudioDevice
        if let existingDefault = availableInputs.first(where: { $0.id == defaultInputID }) {
            defaultInput = existingDefault
        } else {
            defaultInput = try deviceDescriptor(for: defaultInputID, inputChannelCount: 1)
            availableInputs.append(defaultInput)
        }

        let defaultOutput = try? deviceDescriptor(for: defaultOutputDeviceID(), inputChannelCount: 0)

        return DictationInputDeviceSelectionPolicy.selection(
            defaultInput: defaultInput,
            defaultOutput: defaultOutput,
            availableInputs: availableInputs
        )
    }

    private static func allInputDevices() throws -> [DictationAudioDevice] {
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
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr else {
            throw InputDeviceLookupError.propertyReadFailed(status)
        }

        var devices = [AudioDeviceID](
            repeating: AudioDeviceID(kAudioObjectUnknown),
            count: Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        )

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &devices
        )

        guard status == noErr else {
            throw InputDeviceLookupError.propertyReadFailed(status)
        }

        return devices.filter { $0 != AudioDeviceID(kAudioObjectUnknown) }
    }

    private static func deviceDescriptor(
        for deviceID: AudioDeviceID,
        inputChannelCount: UInt32
    ) throws -> DictationAudioDevice {
        let name = try readStringProperty(
            selector: kAudioDevicePropertyDeviceNameCFString,
            objectID: AudioObjectID(deviceID)
        )
        let transport = (try? readUInt32Property(
            selector: kAudioDevicePropertyTransportType,
            objectID: AudioObjectID(deviceID)
        )).map(transportType) ?? .other

        return DictationAudioDevice(
            id: deviceID,
            name: name.isEmpty ? "Unknown" : name,
            transport: transport,
            inputChannelCount: inputChannelCount
        )
    }

    private static func defaultInputDeviceID() throws -> AudioDeviceID {
        try defaultDeviceID(selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    private static func defaultOutputDeviceID() throws -> AudioDeviceID {
        try defaultDeviceID(selector: kAudioHardwarePropertyDefaultOutputDevice)
    }

    private static func defaultDeviceID(selector: AudioObjectPropertySelector) throws -> AudioDeviceID {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceID
        )

        guard status == noErr else {
            throw InputDeviceLookupError.propertyReadFailed(status)
        }
        guard deviceID != AudioDeviceID(kAudioObjectUnknown) else {
            throw InputDeviceLookupError.unknownDevice
        }

        return deviceID
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
            AudioObjectID(deviceID),
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr else {
            throw InputDeviceLookupError.propertyReadFailed(status)
        }
        guard dataSize > 0 else { return 0 }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawPointer.deallocate() }

        status = AudioObjectGetPropertyData(
            AudioObjectID(deviceID),
            &address,
            0,
            nil,
            &dataSize,
            rawPointer
        )
        guard status == noErr else {
            throw InputDeviceLookupError.propertyReadFailed(status)
        }

        let bufferList = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(UInt32(0)) { total, buffer in
            total + buffer.mNumberChannels
        }
    }

    private static func readStringProperty(
        selector: AudioObjectPropertySelector,
        objectID: AudioObjectID
    ) throws -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<CFString>.size)

        let status = withUnsafeMutablePointer(to: &value) { valuePointer in
            AudioObjectGetPropertyData(
                objectID,
                &address,
                0,
                nil,
                &dataSize,
                UnsafeMutableRawPointer(valuePointer)
            )
        }

        guard status == noErr else {
            throw InputDeviceLookupError.propertyReadFailed(status)
        }

        return (value?.takeUnretainedValue() as String?) ?? ""
    }

    private static func readUInt32Property(
        selector: AudioObjectPropertySelector,
        objectID: AudioObjectID
    ) throws -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)

        let status = AudioObjectGetPropertyData(
            objectID,
            &address,
            0,
            nil,
            &dataSize,
            &value
        )

        guard status == noErr else {
            throw InputDeviceLookupError.propertyReadFailed(status)
        }

        return value
    }

    private static func transportType(_ rawValue: UInt32) -> DictationAudioTransport {
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

private func unregisterDefaultInputDeviceListener(_ listener: AudioObjectPropertyListenerBlock?) {
    guard let listener else { return }

    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    let status = AudioObjectRemovePropertyListenerBlock(
        AudioObjectID(kAudioObjectSystemObject),
        &address,
        .main,
        listener
    )

    if status != noErr {
        print("⚠️ PARAKEET | failed to remove default input listener (\(status))")
    }
}

// FluidAudio 0.7.9 no longer exposes the older streaming EOU manager used by
// this dormant live-display path. Keep a no-op shim so the disabled code path
// still compiles until we rewire live transcripts to the newer streaming API.
private actor StreamingEouAsrManager {
    enum ChunkSize {
        case ms320
    }

    init(chunkSize: ChunkSize, eouDebounceMs: Int) {}

    func loadModels(modelDir: URL) async throws {}

    func setPartialCallback(_ callback: @escaping @Sendable (String) -> Void) async {}

    func setEouCallback(_ callback: @escaping @Sendable (String) -> Void) async {}

    func process(audioBuffer: AVAudioPCMBuffer) async throws -> String { "" }

    func reset() async {}
}

enum ParakeetModelState {
    case notLoaded
    case downloading(progress: Double)
    case loading
    case ready
    case failed(String)
}

struct RecordedSpeechSamples {
    let nativeSampleCount: Int
    let samples16k: [Float]
}

private struct ParakeetAudioInputSnapshot {
    let outputFormat: AVAudioFormat
    let hwFormat: AVAudioFormat
    let selection: DictationInputDeviceSelection?
    let selectionApplication: ParakeetInputDeviceApplication?
    let engineWasRunning: Bool
}

private struct ParakeetAudioStartSnapshot {
    let engineWasRunning: Bool
}

private struct ParakeetInputDeviceApplication {
    let selection: DictationInputDeviceSelection
    let didApplyOverride: Bool
    let reportKey: String?
    let errorDescription: String?
}

@MainActor
class ParakeetEngine: ObservableObject {
    @Published var isRecording = false
    @Published var isTranscribing = false
    @Published var audioLevel: Float = 0
    @Published var liveTranscript: String = ""
    @Published var modelDownloadState: ParakeetModelState = .notLoaded
    @Published var recordingInterrupted = false
    @Published var isRecovering = false
    @Published var inputFormatReady = true

    private var audioEngine = AVAudioEngine()
    private let audioEngineQueue = DispatchQueue(label: "com.transcripted.parakeet.audio-engine", qos: .userInitiated)
    private var audioGraphGeneration = 0
    private var audioStartInProgress = false
    private var inputTapInstalled = false
    private var sampleBuffer: [Float] = []
    private var nativeSampleRate: Double = 48000
    private let pendingSamplesLock = NSLock()
    private var pendingSamples: [Float] = []
    private nonisolated(unsafe) var lastLevelUpdate: CFAbsoluteTime = 0
    private var isEnginePrewarmed = false
    private var wakeObserver: NSObjectProtocol?
    private var inputDeviceChangeListener: AudioObjectPropertyListenerBlock?

    // Live streaming text is intentionally disabled — the product focuses on
    // stable capture and final transcription rather than provisional text.
    private let liveDisplayEnabled = false
    private nonisolated(unsafe) var eouManager: StreamingEouAsrManager?
    private var committedStreamText: String = ""
    // Accumulates resampled 16kHz samples between tap callbacks before flushing to EOU.
    // Protected by streamingSamplesLock — accessed from both the audio render thread and MainActor.
    private let streamingSamplesLock = NSLock()
    private var streamingSampleBuffer: [Float] = []
    // Feed EOU in ~320ms chunks (shift size). The manager buffers internally and processes
    // when it has a full chunk (10240 samples = 64 mel frames at hop=160).
    private let eouChunkSamples: Int = 5120
    // Cached format for makePCMBuffer — always 16kHz mono, no need to recreate per chunk
    private let eouPCMFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)
    private var configChangeObserver: NSObjectProtocol?
    private var configChangeDebounceTask: Task<Void, Never>?
    private var configRecoveryTask: Task<Void, Never>?
    /// Tracks whether a recording was active when the first config change in a
    /// burst arrived. Subsequent changes during recovery inherit this flag so
    /// the final recovery attempt knows to restart recording.
    private var configChangeWasRecording = false
    /// Pure-logic state machine for device-change recovery. Owns the generation
    /// counter and the readiness flags. Mirrored into @Published so the UI can
    /// observe via Combine.
    private var recoveryState = ParakeetRecoveryState()
    /// Counts consecutive failed prewarm attempts. Reset on successful prewarm or
    /// on a fresh config-change burst. Bounded by `prewarmRetryBudget` to prevent
    /// infinite Task chains when the mic is permanently unavailable.
    private var prewarmRetryCount: Int = 0
    private var prewarmRetryTask: Task<Void, Never>?
    private var isShuttingDown = false

    // FluidAudio ASR
    private var asrManager: AsrManager?
    private var audioWatchdogTask: Task<Void, Never>?
    private var asrManagerReady = false
    private nonisolated(unsafe) var didReceiveAudioSamples = false
    private var cachedInputDeviceName = "Unknown"
    private var lastAudioStartFailureReportAt: TimeInterval?
    private var lastInputSelectionReportKey: String?
    private var ignoreInputSelectionConfigChangesUntil: CFAbsoluteTime = 0

    var isModelLoaded: Bool { asrManagerReady }
    var inputDeviceName: String { cachedInputDeviceName }

    init() {
        scheduleInputDeviceNameRefresh()
    }

    nonisolated private static func loadDictationInputDeviceSelection() -> DictationInputDeviceSelection? {
        do {
            return try CoreAudioInputDeviceLookup.preferredDictationInputSelection()
        } catch {
            return nil
        }
    }

    nonisolated private static var unknownInputDeviceSelection: DictationInputDeviceSelection {
        let unknownDevice = DictationAudioDevice(
            id: AudioDeviceID(kAudioObjectUnknown),
            name: "Unknown",
            transport: .other,
            inputChannelCount: 0
        )
        return DictationInputDeviceSelection(
            defaultInput: unknownDevice,
            selectedInput: unknownDevice,
            defaultOutput: nil,
            reason: .defaultIsSafe
        )
    }

    private func scheduleInputDeviceNameRefresh() {
        Task.detached(priority: .utility) { [weak self] in
            if let selection = Self.loadDictationInputDeviceSelection() {
                await self?.updateCachedInputDeviceSelection(selection)
            } else {
                await self?.updateCachedInputDeviceName("Unknown")
            }
        }
    }

    private func runAudioEngineWork<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            audioEngineQueue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private func runAudioEngineWork<T>(_ work: @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            audioEngineQueue.async {
                continuation.resume(returning: work())
            }
        }
    }

    private func updateCachedInputDeviceName(_ deviceName: String) {
        cachedInputDeviceName = deviceName
    }

    private func updateCachedInputDeviceSelection(_ selection: DictationInputDeviceSelection) {
        cachedInputDeviceName = selection.selectedInput.name
    }

    private func handleDefaultInputDeviceChange(selection: DictationInputDeviceSelection) {
        cachedInputDeviceName = selection.selectedInput.name
        print("🎤 PARAKEET | default input changed → \(selection.defaultInput.name); dictation input → \(selection.selectedInput.name)")
        EventReporter.shared.capture(
            level: .info,
            engine: "parakeet",
            event: "default_input_device_changed",
            message: "Default input device changed",
            context: inputSelectionContext(selection)
        )
        Task { @MainActor [weak self] in
            await self?.handleAudioConfigChange()
        }
    }

    // MARK: - Model Initialization

    /// Load Parakeet models from the app bundle (preferred) or download from HuggingFace (fallback).
    /// Bundle path: Contents/Resources/parakeet-models/parakeet-tdt-0.6b-v3-coreml/
    func initialize() async {
        guard !isShuttingDown, !Task.isCancelled else { return }
        scheduleInputDeviceNameRefresh()

        guard asrManager == nil else {
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "already_initialized",
                message: "initialize() called but ASR manager already exists — ignoring")
            return
        }

        switch modelDownloadState {
        case .downloading, .loading:
            return
        case .notLoaded, .ready, .failed:
            break
        }

        // Keep background model warmup quiet. The onboarding/settings surfaces
        // own microphone permission requests so launch-time initialization does
        // not surprise users with a hidden or out-of-context prompt.

        modelDownloadState = .loading
        print("🔄 PARAKEET | initializing models...")

        var failureStage: ParakeetModelInitStage = .authorizationRequest
        var loadSource: ParakeetModelLoadSource = .unresolved
        let bundledModelPath = bundledModelPath(subdirectory: "parakeet-tdt-0.6b-v3-coreml", checkFile: "Encoder.mlmodelc")
        let bundledModelPresent = bundledModelPath != nil

        do {
            let models: AsrModels
            let loadSourceName: String

            // Try loading from app bundle first (bundled by build.sh)
            if let bundlePath = bundledModelPath {
                failureStage = .bundleLoad
                loadSource = .bundle
                print("📦 PARAKEET | loading from bundle: \(bundlePath.path)")
                models = try await AsrModels.load(from: bundlePath, version: .v3)
                guard !Task.isCancelled, !isShuttingDown else { return }
                loadSourceName = loadSource.rawValue
            } else {
                // Fallback: download from HuggingFace (~600MB on first run).
                //
                // SECURITY: AsrModels.download() pulls model artifacts from HuggingFace
                // through FluidAudio. Transcripted does not currently re-verify the
                // downloaded artifacts against pinned SHA-256 digests. Trust here rests
                // on the system TLS chain plus HuggingFace's CDN integrity. A targeted
                // TLS interception or CDN compromise could swap the model files, with
                // a worst-case impact of bad transcriptions or — much less likely —
                // exploitation of a Core ML deserialization bug.
                //
                // To close this gap we'd ship a static `[filename: sha256]` table for
                // each supported Parakeet variant and verify it after download, before
                // calling AsrModels.load(...). The hashes need to be computed from a
                // trusted release of the model bundle; without that source of truth a
                // verification stub would be worse than no check at all.
                failureStage = .downloadModels
                loadSource = .download
                print("🌐 PARAKEET | models not bundled, downloading (~600MB)...")
                modelDownloadState = .downloading(progress: 0.0)
                let downloadedPath = try await AsrModels.download(version: .v3)
                guard !Task.isCancelled, !isShuttingDown else { return }
                modelDownloadState = .loading
                print("🌐 PARAKEET | loading downloaded models from: \(downloadedPath.path)")
                models = try await AsrModels.load(from: downloadedPath, version: .v3)
                guard !Task.isCancelled, !isShuttingDown else { return }
                loadSourceName = loadSource.rawValue
            }

            failureStage = .managerInitialize
            let manager = AsrManager(config: .default)
            try await manager.initialize(models: models)
            guard !Task.isCancelled, !isShuttingDown else {
                Task { manager.cleanup() }
                return
            }

            asrManager = manager
            asrManagerReady = true
            modelDownloadState = .ready
            print("✅ PARAKEET | TDT V3 models loaded (source: \(loadSourceName))")
            EventReporter.shared.capture(level: .info, engine: "parakeet", event: "models_loaded",
                message: "Parakeet ASR models initialized successfully",
                context: ["load_source": loadSourceName])

            if liveDisplayEnabled {
                await initializeEouModel()
            }

        } catch {
            guard !Task.isCancelled, !isShuttingDown else { return }
            let friendlyMessage = ModelDownloadService.classifyError(error).detail
            modelDownloadState = .failed(friendlyMessage)
            print("❌ PARAKEET | model initialization failed: \(error.localizedDescription)")
            EventReporter.shared.capture(level: .error, engine: "parakeet", event: "model_init_failed",
                message: error.localizedDescription,
                context: ParakeetModelInitDiagnostics.failureContext(
                    stage: failureStage,
                    loadSource: loadSource,
                    bundledModelPresent: bundledModelPresent,
                    microphoneStatus: AVCaptureDevice.authorizationStatus(for: .audio)
                ))
        }
    }

    /// Load Parakeet EOU 120M for streaming live display.
    /// Non-fatal — if EOU fails, live transcript stays empty but batch result still works.
    private func initializeEouModel() async {
        do {
            let eou = StreamingEouAsrManager(chunkSize: .ms320, eouDebounceMs: 1280)

            let modelDir: URL
            if let bundlePath = bundledModelPath(subdirectory: "parakeet-eou-120m-coreml", checkFile: "streaming_encoder.mlmodelc") {
                print("📦 PARAKEET EOU | loading from bundle: \(bundlePath.path)")
                modelDir = bundlePath
            } else {
                // Download from HuggingFace (~120MB) and cache locally
                // DownloadUtils nests inside <directory>/<repo.folderName>/, so we use the parent
                let cacheBase = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("FluidAudio/Models", isDirectory: true)
                let expectedDir = cacheBase.appendingPathComponent("parakeet-eou-streaming/320ms", isDirectory: true)
                let checkFile = expectedDir.appendingPathComponent("streaming_encoder.mlmodelc")
                if FileManager.default.fileExists(atPath: checkFile.path) {
                    print("📦 PARAKEET EOU | loading from cache: \(expectedDir.path)")
                    modelDir = expectedDir
                } else {
                    print("⚠️ PARAKEET EOU | streaming model download unavailable with current FluidAudio API")
                    EventReporter.shared.capture(
                        level: .warning,
                        engine: "parakeet",
                        event: "eou_model_unavailable",
                        message: "Streaming EOU model download is unavailable with the current FluidAudio version"
                    )
                    return
                }
            }
            try await eou.loadModels(modelDir: modelDir)

            // Partial callback fires on every chunk with new tokens — live "ghost text" display
            await eou.setPartialCallback { [weak self] partial in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    let trimmed = partial.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    self.liveTranscript = self.committedStreamText.isEmpty
                        ? trimmed
                        : self.committedStreamText + " " + trimmed
                }
            }

            // EOU callback fires after silence — commits the utterance so partial text resets
            await eou.setEouCallback { [weak self] transcript in
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    let trimmed = transcript.trimmingCharacters(in: .whitespaces)
                    guard !trimmed.isEmpty else { return }
                    self.committedStreamText = self.committedStreamText.isEmpty
                        ? trimmed
                        : self.committedStreamText + " " + trimmed
                    self.liveTranscript = self.committedStreamText
                }
            }

            eouManager = eou
            print("✅ PARAKEET EOU | streaming model ready")
            EventReporter.shared.capture(level: .info, engine: "parakeet", event: "eou_model_loaded",
                message: "Parakeet EOU streaming model initialized")
        } catch {
            // Non-fatal — live display will just stay empty until batch result arrives
            print("⚠️ PARAKEET EOU | model load failed (live display disabled): \(error.localizedDescription)")
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "eou_model_failed",
                message: error.localizedDescription)
        }
    }

    /// Check for a Parakeet model bundled in the app at build time.
    /// Expected layout: Contents/Resources/parakeet-models/{subdirectory}/{checkFile}
    private func bundledModelPath(subdirectory: String, checkFile: String) -> URL? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        let path = URL(fileURLWithPath: resourcePath)
            .appendingPathComponent("parakeet-models")
            .appendingPathComponent(subdirectory)
        guard FileManager.default.fileExists(atPath: path.appendingPathComponent(checkFile).path) else { return nil }
        return path
    }

    // MARK: - Input readiness

    func prewarm() async {
        guard !isShuttingDown else { return }
        guard !isRecording else { return }
        guard !audioStartInProgress else { return }
        installAudioObserversIfNeeded()
        scheduleInputDeviceNameRefresh()

        await releaseIdleAudioHardware(removeTap: false)

        let microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch ParakeetPrewarmPolicy.decision(for: microphoneStatus) {
        case .proceed:
            break
        case .skip(let level, let event, let message, let context):
            let eventLevel: EventLevel
            switch level {
            case .info:
                eventLevel = .info
            case .warning:
                eventLevel = .warning
            }
            EventReporter.shared.capture(
                level: eventLevel,
                engine: "parakeet",
                event: event,
                message: message,
                context: context
            )
            return
        }

        let snapshot: ParakeetAudioInputSnapshot
        do {
            snapshot = try await audioInputSnapshot(operation: "prewarm")
        } catch {
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "prewarm_failed",
                message: error.localizedDescription
            )
            markFormatUnreadyAndPublish()
            schedulePrewarmRetry()
            return
        }

        // Validate both formats. AirPods on macOS run input in Hands-Free Profile
        // (24kHz hw / 48kHz output bus); CoreAudio's internal converter handles
        // the upsample and the tap delivers at the output bus rate. Both must be
        // valid before declaring the engine ready — input alone or output alone
        // can transiently report zero during device transitions.
        let readiness = audioFormatReadiness(
            outputFormat: snapshot.outputFormat,
            hwFormat: snapshot.hwFormat,
            selection: snapshot.selection
        )
        guard readiness == .ready else {
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "prewarm_invalid_format",
                message: "Audio format invalid during prewarm",
                context: audioFormatContext(
                    outputFormat: snapshot.outputFormat,
                    hwFormat: snapshot.hwFormat,
                    selection: snapshot.selection,
                    readiness: readiness
                ))
            if readiness == .routeNotSettled {
                await rebuildAudioEngine(reason: "audio_route_not_settled")
            }
            markFormatUnreadyAndPublish()
            schedulePrewarmRetry()
            return
        }

        nativeSampleRate = snapshot.outputFormat.sampleRate

        prewarmRetryCount = 0
        markFormatReadyAndPublish()
        print("🔥 PARAKEET | input ready (\(inputDeviceName), \(nativeSampleRate)Hz)")
    }

    private func schedulePrewarmRetry() {
        guard !isShuttingDown else { return }
        // Bounded retry — give CoreAudio time to settle, but don't loop forever.
        // Each call counts toward the budget; budget resets on a successful prewarm
        // or on an explicit device change (which restarts the cycle anyway).
        guard prewarmRetryCount < TranscriptedConstants.prewarmRetryBudget else {
            EventReporter.shared.capture(level: .warning, engine: "parakeet",
                event: "prewarm_retry_budget_exhausted",
                message: "Prewarm retry budget exhausted — engine will retry on next device change or user action",
                context: ["audio_device": inputDeviceName])
            prewarmRetryCount = 0
            return
        }
        prewarmRetryCount += 1
        let capturedGeneration = recoveryState.generation
        prewarmRetryTask?.cancel()
        prewarmRetryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: TranscriptedConstants.audioRecoveryDelay)
            guard !Task.isCancelled,
                  let self,
                  !self.isShuttingDown,
                  !self.recoveryState.isStale(generation: capturedGeneration) else { return }
            await self.prewarm()
        }
    }

    private func installAudioObserversIfNeeded() {
        installAudioEngineConfigObserverIfNeeded()

        if wakeObserver == nil {
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    await self?.handleSystemWake()
                }
            }
        }

        installInputDeviceChangeListenerIfNeeded()
    }

    private func installAudioEngineConfigObserverIfNeeded() {
        guard configChangeObserver == nil else { return }
        configChangeObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: audioEngine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.handleAudioConfigChange()
            }
        }
    }

    private func removeAudioEngineConfigObserver() {
        guard let observer = configChangeObserver else { return }
        NotificationCenter.default.removeObserver(observer)
        configChangeObserver = nil
    }

    private func installInputDeviceChangeListenerIfNeeded() {
        guard inputDeviceChangeListener == nil else { return }

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task.detached(priority: .utility) { [weak self] in
                let selection = Self.loadDictationInputDeviceSelection() ?? Self.unknownInputDeviceSelection
                await self?.handleDefaultInputDeviceChange(selection: selection)
            }
        }

        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            .main,
            listener
        )

        guard status == noErr else {
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "default_input_listener_failed",
                message: "Failed to register default input device listener",
                context: ["status": "\(status)"]
            )
            return
        }

        inputDeviceChangeListener = listener
    }

    private func removeInputDeviceChangeListener() {
        unregisterDefaultInputDeviceListener(inputDeviceChangeListener)
        inputDeviceChangeListener = nil
    }

    private func handleAudioConfigChange() async {
        if CFAbsoluteTimeGetCurrent() < ignoreInputSelectionConfigChangesUntil {
            return
        }
        audioGraphGeneration += 1

        // Track whether any config change in the current burst interrupted a
        // recording. Once set, subsequent changes in the same burst inherit it.
        if isRecording {
            configChangeWasRecording = true
        }

        // Bump the generation counter and signal UI that engine is recovering.
        // DictationSessionController waits on these flags instead of racing.
        _ = recoveryState.beginConfigChange()
        publishRecoveryState()
        // Fresh device state warrants a fresh retry budget for prewarm.
        prewarmRetryCount = 0

        // Immediately tear down anything that's running — the system has
        // already stopped the engine internally before posting this notification,
        // so the tap and prewarm state are stale.
        cancelAudioWatchdog()
        prewarmRetryTask?.cancel()
        prewarmRetryTask = nil

        if isRecording {
            pendingSamplesLock.withLock {
                pendingSamples.removeAll(keepingCapacity: true)
            }
            streamingSamplesLock.withLock { streamingSampleBuffer.removeAll(keepingCapacity: true) }
            Task { await eouManager?.reset() }
            await removeRecordingTap()
            isRecording = false
            audioLevel = 0
        }

        await stopAudioEngine()
        isEnginePrewarmed = false
        await rebuildAudioEngine(reason: "configuration_change")

        // Cancel any in-flight recovery — the latest device change wins.
        // Bluetooth disconnect/reconnect fires multiple notifications over
        // 500-1500ms; each cancels the previous recovery so only the final
        // stable device state gets a recovery attempt.
        configChangeDebounceTask?.cancel()
        configRecoveryTask?.cancel()

        configChangeDebounceTask = Task { @MainActor [weak self] in
            // 250ms debounce — long enough to coalesce rapid BT notifications,
            // short enough that dictation recovery feels responsive.
            try? await Task.sleep(nanoseconds: TranscriptedConstants.audioConfigChangeDebounceDelay)
            guard !Task.isCancelled, let self = self else { return }
            self.attemptDeviceRecovery()
        }
    }

    private func attemptDeviceRecovery() {
        let shouldRestartRecording = configChangeWasRecording
        configChangeWasRecording = false
        let myGeneration = recoveryState.generation

        configRecoveryTask = Task { @MainActor [weak self] in
            // Wait for CoreAudio to finish settling the new device graph.
            try? await Task.sleep(nanoseconds: TranscriptedConstants.audioRecoveryDelay)
            guard !Task.isCancelled, let self = self else { return }
            guard !self.recoveryState.isStale(generation: myGeneration) else { return }
            do {
                // Two-step format validation. CoreAudio sometimes reports zero
                // sample rate on first read after device change, even past the
                // initial settle delay. One extra wait + re-read is enough.
                var snapshot = try await self.audioInputSnapshot(operation: "device_recovery")
                if self.audioFormatReadiness(outputFormat: snapshot.outputFormat, hwFormat: snapshot.hwFormat, selection: snapshot.selection) != .ready {
                    try? await Task.sleep(nanoseconds: TranscriptedConstants.audioRecoveryDelay)
                    guard !self.recoveryState.isStale(generation: myGeneration) else { return }
                    snapshot = try await self.audioInputSnapshot(operation: "device_recovery_retry")
                }
                let readiness = self.audioFormatReadiness(
                    outputFormat: snapshot.outputFormat,
                    hwFormat: snapshot.hwFormat,
                    selection: snapshot.selection
                )
                guard readiness == .ready else {
                    EventReporter.shared.capture(
                        level: .warning,
                        engine: "parakeet",
                        event: "device_change_rewarm_deferred",
                        message: "Audio route still settling after device change",
                        context: self.audioFormatContext(
                            outputFormat: snapshot.outputFormat,
                            hwFormat: snapshot.hwFormat,
                            selection: snapshot.selection,
                            readiness: readiness
                        )
                    )
                    await self.rebuildAudioEngine(reason: "device_change_route_not_settled")
                    self.prewarmRetryCount = 0
                    self.schedulePrewarmRetry()
                    throw NSError(domain: "ParakeetEngine", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Audio route not settled after device change"])
                }
                self.nativeSampleRate = snapshot.outputFormat.sampleRate
                self.prewarmRetryCount = 0
                print("🔄 PARAKEET | audio device changed → \(self.inputDeviceName) (\(snapshot.outputFormat.sampleRate)Hz), input ready")

                guard !Task.isCancelled else { return }
                guard self.recoveryState.finishRecovery(success: true, generation: myGeneration) else { return }
                self.publishRecoveryState()

                // If we were recording, try to restart on the new device.
                // The watchdog (via isRecoveryAttempt=false) catches silent
                // failures where the device looks functional but produces no
                // samples. The watchdog gets one retry before giving up.
                if shouldRestartRecording {
                    var restarted = false
                    for attempt in 1...TranscriptedConstants.recordingRestartAttempts {
                        guard !Task.isCancelled else { return }
                        guard !self.recoveryState.isStale(generation: myGeneration) else { return }
                        if await self.startRecording() {
                            restarted = true
                            print("✅ PARAKEET | recording recovered on new device (\(self.inputDeviceName)) after \(attempt) attempt(s)")
                            EventReporter.shared.capture(level: .info, engine: "parakeet",
                                event: "recording_recovered_device_change",
                                message: "Recording recovered after device change",
                                context: [
                                    "audio_device": self.inputDeviceName,
                                    "sample_rate": "\(self.nativeSampleRate)",
                                    "attempts": "\(attempt)"
                                ])
                            break
                        }
                        // BT format negotiation can take ~1-2s; wait between attempts.
                        try? await Task.sleep(nanoseconds: TranscriptedConstants.recordingRestartRetryDelay)
                    }
                    if !restarted {
                        self.recordingInterrupted = true
                        EventReporter.shared.capture(level: .warning, engine: "parakeet",
                            event: "recording_interrupted",
                            message: "Recording could not restart after device change within retry budget",
                            context: ["audio_device": self.inputDeviceName])
                    }
                }
            } catch {
                if self.recoveryState.finishRecovery(success: false, generation: myGeneration) {
                    self.publishRecoveryState()
                }
                if shouldRestartRecording {
                    self.recordingInterrupted = true
                    EventReporter.shared.capture(level: .warning, engine: "parakeet",
                        event: "recording_interrupted",
                        message: "Recording interrupted — engine rewarm failed after device change",
                        context: ["audio_device": self.inputDeviceName, "error": error.localizedDescription])
                }
                EventReporter.shared.capture(level: .error, engine: "parakeet",
                    event: "device_change_rewarm_failed",
                    message: error.localizedDescription, context: ["audio_device": self.inputDeviceName])
                await self.rebuildAudioEngine(reason: "device_change_rewarm_failed")
                self.prewarmRetryCount = 0
                self.schedulePrewarmRetry()
            }
        }
    }

    private func publishRecoveryState() {
        isRecovering = recoveryState.isRecovering
        inputFormatReady = recoveryState.inputFormatReady
    }

    private func markFormatUnreadyAndPublish() {
        recoveryState.markFormatUnready()
        publishRecoveryState()
    }

    private func markStartFailedAndPublish() {
        recoveryState.markStartFailed()
        publishRecoveryState()
    }

    private func markFormatReadyAndPublish() {
        if !recoveryState.inputFormatReady {
            recoveryState.markFormatReady()
            publishRecoveryState()
        }
    }

    private func audioFormatReadiness(
        outputFormat: AVAudioFormat,
        hwFormat: AVAudioFormat,
        selection: DictationInputDeviceSelection?
    ) -> ParakeetAudioFormatReadiness {
        ParakeetAudioFormatReadinessPolicy.readiness(
            outputSampleRate: outputFormat.sampleRate,
            outputChannelCount: outputFormat.channelCount,
            inputSampleRate: hwFormat.sampleRate,
            inputChannelCount: hwFormat.channelCount,
            selectedInputClass: selectedInputClass(for: selection),
            selectionOverrodeDefault: selection?.didOverrideDefault ?? false
        )
    }

    private func selectedInputClass(for selection: DictationInputDeviceSelection?) -> String {
        if let selection {
            return DictationInputDeviceSelectionPolicy.deviceClass(for: selection.selectedInput)
        }
        return inputDeviceClass(for: inputDeviceName)
    }

    private func audioFormatContext(
        outputFormat: AVAudioFormat,
        hwFormat: AVAudioFormat,
        selection: DictationInputDeviceSelection?,
        readiness: ParakeetAudioFormatReadiness
    ) -> [String: String] {
        var context = [
            "format_readiness": readiness.rawValue,
            "output_rate_hz": String(format: "%.0f", outputFormat.sampleRate),
            "output_channels": "\(outputFormat.channelCount)",
            "input_rate_hz": String(format: "%.0f", hwFormat.sampleRate),
            "hw_channels": "\(hwFormat.channelCount)",
            "input_device_class": selectedInputClass(for: selection),
            "selection_overrode_default": "\(selection?.didOverrideDefault ?? false)",
            "recovering": "\(recoveryState.isRecovering)",
            "format_ready": "\(recoveryState.inputFormatReady)",
            "generation": "\(recoveryState.generation)",
        ]

        if let selection {
            context["selection_reason"] = selection.reason.rawValue
            context["default_input_class"] = DictationInputDeviceSelectionPolicy.deviceClass(for: selection.defaultInput)
            context["selected_input_class"] = DictationInputDeviceSelectionPolicy.deviceClass(for: selection.selectedInput)
            if let defaultOutput = selection.defaultOutput {
                context["default_output_class"] = DictationInputDeviceSelectionPolicy.deviceClass(for: defaultOutput)
            }
        }

        return context
    }

    private func audioInputSnapshot(operation: String) async throws -> ParakeetAudioInputSnapshot {
        let selection = Self.loadDictationInputDeviceSelection()
        if let selection, selection.didOverrideDefault {
            let shouldApplyOverride = await runAudioEngineWork {
                self.audioEngine.inputNode.auAudioUnit.deviceID != selection.selectedInput.id
            }
            if shouldApplyOverride {
                ignoreInputSelectionConfigChangesUntil = CFAbsoluteTimeGetCurrent() + 1.0
            }
        }

        let snapshot = try await runAudioEngineWork { () throws -> ParakeetAudioInputSnapshot in
            let inputNode = self.audioEngine.inputNode
            let selectionApplication = Self.applyPreferredDictationInputDevice(selection, to: inputNode)
            return ParakeetAudioInputSnapshot(
                outputFormat: inputNode.outputFormat(forBus: 0),
                hwFormat: inputNode.inputFormat(forBus: 0),
                selection: selection,
                selectionApplication: selectionApplication,
                engineWasRunning: self.audioEngine.isRunning
            )
        }
        recordInputSelection(snapshot.selectionApplication, operation: operation)
        return snapshot
    }

    private func installTapAndStartEngine(isRecoveryAttempt: Bool) async throws -> ParakeetAudioStartSnapshot {
        let wasPrewarmed = isEnginePrewarmed
        return try await runAudioEngineWork {
            let inputNode = self.audioEngine.inputNode
            inputNode.removeTap(onBus: 0)
            inputNode.installTap(onBus: 0, bufferSize: TranscriptedConstants.audioTapBufferSize, format: nil) { [weak self] buffer, _ in
                guard let self = self,
                      let monoSamples = self.extractMonoSamples(from: buffer) else { return }
                let frameLength = monoSamples.count
                guard frameLength > 0 else { return }

                if !self.didReceiveAudioSamples && frameLength > 0 {
                    self.didReceiveAudioSamples = true
                    Task { @MainActor in
                        EventReporter.shared.capture(level: .info, engine: "parakeet", event: "audio_samples_detected",
                            message: "Audio samples started flowing",
                            context: [
                                "sample_rate": "\(self.nativeSampleRate)",
                                "channels": "\(buffer.format.channelCount)",
                                "frames": "\(frameLength)"
                            ])
                    }
                }

                if self.liveDisplayEnabled, let eou = self.eouManager {
                    let resampled = AudioResampler.resample(monoSamples, from: self.nativeSampleRate, to: 16000)
                    self.streamingSamplesLock.lock()
                    self.streamingSampleBuffer.append(contentsOf: resampled)
                    var chunk: [Float]? = nil
                    if self.streamingSampleBuffer.count >= self.eouChunkSamples {
                        chunk = self.streamingSampleBuffer
                        self.streamingSampleBuffer = []
                    }
                    self.streamingSamplesLock.unlock()
                    if let chunk = chunk, let pcm = self.makePCMBuffer(from: chunk) {
                        Task {
                            do { _ = try await eou.process(audioBuffer: pcm) }
                            catch { EventReporter.shared.capture(level: .warning, engine: "parakeet",
                                event: "eou_process_error", message: error.localizedDescription) }
                        }
                    }
                }

                self.pendingSamplesLock.lock()
                self.pendingSamples.append(contentsOf: monoSamples)
                let maxSamples = Int(self.nativeSampleRate) * TranscriptedConstants.audioBufferCapacitySeconds
                if self.pendingSamples.count > maxSamples + Int(self.nativeSampleRate) {
                    self.pendingSamples.removeFirst(self.pendingSamples.count - maxSamples)
                }
                self.pendingSamplesLock.unlock()

                let now = CFAbsoluteTimeGetCurrent()
                guard now - self.lastLevelUpdate > TranscriptedConstants.audioMeteringInterval else { return }
                self.lastLevelUpdate = now

                var sumOfSquares: Float = 0
                for sample in monoSamples {
                    let s = sample
                    sumOfSquares += s * s
                }
                let rms = sqrt(sumOfSquares / Float(max(1, frameLength)))
                let dB = rms > 0.0001 ? 20.0 * log10(rms) : -60.0
                let normalized = max(0.0, min(1.0, (dB - TranscriptedConstants.audioLevelFloorDB) / (TranscriptedConstants.audioLevelCeilingDB - TranscriptedConstants.audioLevelFloorDB)))

                Task { @MainActor [weak self] in
                    self?.audioLevel = normalized
                }
            }

            let engineWasRunning = self.audioEngine.isRunning
            if !wasPrewarmed || !self.audioEngine.isRunning {
                self.audioEngine.prepare()
                try self.audioEngine.start()
            }
            return ParakeetAudioStartSnapshot(engineWasRunning: engineWasRunning)
        }
    }

    private func removeRecordingTap(force: Bool = false) async {
        guard force || inputTapInstalled else { return }
        await runAudioEngineWork {
            self.audioEngine.inputNode.removeTap(onBus: 0)
        }
        inputTapInstalled = false
    }

    private func stopAudioEngine() async {
        await runAudioEngineWork {
            if self.audioEngine.isRunning {
                self.audioEngine.stop()
            }
        }
    }

    private func resetAudioGraphAfterStartFailure(reason: String, rebuildEngine: Bool) async {
        // Keep runtime/UI state coherent when startRecording fails before we ever
        // transition to a stable recording session.
        cancelAudioWatchdog()
        isRecording = false
        audioLevel = 0
        didReceiveAudioSamples = false

        if rebuildEngine {
            await rebuildAudioEngine(reason: reason)
            return
        }
        audioGraphGeneration += 1
        await runAudioEngineWork {
            self.audioEngine.inputNode.removeTap(onBus: 0)
            if self.audioEngine.isRunning {
                self.audioEngine.stop()
            }
            self.audioEngine.reset()
        }
        inputTapInstalled = false
        isEnginePrewarmed = false
    }

    private func rebuildAudioEngine(reason: String) async {
        audioGraphGeneration += 1
        removeAudioEngineConfigObserver()
        await runAudioEngineWork {
            self.audioEngine.inputNode.removeTap(onBus: 0)
            if self.audioEngine.isRunning {
                self.audioEngine.stop()
            }
            self.audioEngine.reset()
            self.audioEngine = AVAudioEngine()
        }
        inputTapInstalled = false
        isEnginePrewarmed = false
        didReceiveAudioSamples = false
        if !isShuttingDown {
            installAudioEngineConfigObserverIfNeeded()
        }
        EventReporter.shared.capture(
            level: .warning,
            engine: "parakeet",
            event: "audio_engine_rebuilt",
            message: "Audio engine rebuilt after microphone graph failure",
            context: [
                "reason": reason,
                "recovering": "\(recoveryState.isRecovering)",
                "format_ready": "\(recoveryState.inputFormatReady)",
                "generation": "\(recoveryState.generation)"
            ]
        )
    }

    private func handleSystemWake() async {
        print("🔄 PARAKEET | system wake detected, resetting audio engine")
        EventReporter.shared.capture(level: .info, engine: "parakeet", event: "system_wake",
            message: "System woke from sleep, resetting audio engine",
            context: ["was_recording": "\(isRecording)", "was_prewarmed": "\(isEnginePrewarmed)"])

        audioGraphGeneration += 1
        let wasRecording = isRecording
        cancelAudioWatchdog()
        if isRecording {
            pendingSamplesLock.withLock {
                pendingSamples.removeAll(keepingCapacity: true)
            }
            streamingSamplesLock.withLock {
                streamingSampleBuffer.removeAll(keepingCapacity: true)
            }
            Task { await eouManager?.reset() }
            await removeRecordingTap()
            isRecording = false
            audioLevel = 0
        }

        await stopAudioEngine()
        isEnginePrewarmed = false

        if wasRecording {
            recordingInterrupted = true
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "recording_interrupted",
                message: "Recording interrupted by system sleep/wake")
        }
    }

    // MARK: - Recording

    @discardableResult
    private static func applyPreferredDictationInputDevice(
        _ selection: DictationInputDeviceSelection?,
        to inputNode: AVAudioInputNode
    ) -> ParakeetInputDeviceApplication? {
        guard let selection else {
            return nil
        }

        guard selection.didOverrideDefault else {
            return ParakeetInputDeviceApplication(
                selection: selection,
                didApplyOverride: false,
                reportKey: nil,
                errorDescription: nil
            )
        }

        guard inputNode.auAudioUnit.deviceID != selection.selectedInput.id else {
            return ParakeetInputDeviceApplication(
                selection: selection,
                didApplyOverride: false,
                reportKey: nil,
                errorDescription: nil
            )
        }

        do {
            try inputNode.auAudioUnit.setDeviceID(selection.selectedInput.id)
            return ParakeetInputDeviceApplication(
                selection: selection,
                didApplyOverride: true,
                reportKey: "\(selection.defaultInput.id)->\(selection.selectedInput.id)",
                errorDescription: nil
            )
        } catch {
            return ParakeetInputDeviceApplication(
                selection: selection,
                didApplyOverride: false,
                reportKey: nil,
                errorDescription: error.localizedDescription
            )
        }
    }

    private func recordInputSelection(
        _ application: ParakeetInputDeviceApplication?,
        operation: String
    ) {
        guard let application else { return }
        let selection = application.selection

        guard selection.didOverrideDefault else {
            cachedInputDeviceName = selection.selectedInput.name
            lastInputSelectionReportKey = nil
            return
        }

        if let errorDescription = application.errorDescription {
            ignoreInputSelectionConfigChangesUntil = 0
            cachedInputDeviceName = selection.defaultInput.name
            var context = inputSelectionContext(selection, operation: operation)
            context["error"] = errorDescription
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "dictation_input_device_selection_failed",
                message: "Failed to apply preferred dictation input device",
                context: context
            )
            return
        }

        cachedInputDeviceName = selection.selectedInput.name
        guard application.didApplyOverride,
              let reportKey = application.reportKey,
              lastInputSelectionReportKey != reportKey else { return }

        lastInputSelectionReportKey = reportKey
        print("🎤 PARAKEET | using \(selection.selectedInput.name) instead of \(selection.defaultInput.name) to avoid Bluetooth headset mode")
        EventReporter.shared.capture(
            level: .info,
            engine: "parakeet",
            event: "dictation_input_device_auto_selected",
            message: "Dictation input changed away from Bluetooth headset microphone",
            context: inputSelectionContext(selection, operation: operation)
        )
    }

    private func inputSelectionContext(
        _ selection: DictationInputDeviceSelection,
        operation: String? = nil
    ) -> [String: String] {
        var context = [
            "audio_device": selection.selectedInput.name,
            "default_input_device": selection.defaultInput.name,
            "selected_input_device": selection.selectedInput.name,
            "default_input_class": DictationInputDeviceSelectionPolicy.deviceClass(for: selection.defaultInput),
            "selected_input_class": DictationInputDeviceSelectionPolicy.deviceClass(for: selection.selectedInput),
            "selection_reason": selection.reason.rawValue,
            "selection_overrode_default": "\(selection.didOverrideDefault)"
        ]

        if let defaultOutput = selection.defaultOutput {
            context["default_output_device"] = defaultOutput.name
            context["default_output_class"] = DictationInputDeviceSelectionPolicy.deviceClass(for: defaultOutput)
        }

        if let operation {
            context["operation"] = operation
        }

        return context
    }

    private func audioStartContext(
        attempt: Int,
        isRecoveryAttempt: Bool,
        engineWasRunning: Bool,
        outputFormat: AVAudioFormat,
        hwFormat: AVAudioFormat,
        error: Error? = nil
    ) -> [String: String] {
        var context = [
            "attempt": "\(attempt)",
            "start_mode": isRecoveryAttempt ? "recovery" : "normal",
            "recovering": "\(recoveryState.isRecovering)",
            "format_ready": "\(recoveryState.inputFormatReady)",
            "generation": "\(recoveryState.generation)",
            "prewarmed": "\(isEnginePrewarmed)",
            "engine_running_before_start": "\(engineWasRunning)",
            "tap_installed": "\(inputTapInstalled)",
            "output_rate_hz": String(format: "%.0f", outputFormat.sampleRate),
            "output_channels": "\(outputFormat.channelCount)",
            "input_rate_hz": String(format: "%.0f", hwFormat.sampleRate),
            "hw_channels": "\(hwFormat.channelCount)",
            "input_device_class": inputDeviceClass(for: inputDeviceName),
        ]

        if let error {
            let nsError = error as NSError
            context["status_domain"] = nsError.domain
            context["status_code"] = "\(nsError.code)"
        }

        return context
    }

    private func inputDeviceClass(for deviceName: String) -> String {
        DictationInputDeviceSelectionPolicy.deviceClass(forName: deviceName)
    }

    private func reportAudioStartFailureIfNeeded(message: String, context: [String: String]) {
        let now = CFAbsoluteTimeGetCurrent()
        guard ParakeetAudioStartRecoveryPolicy.shouldReportFailure(
            now: now,
            lastReportAt: lastAudioStartFailureReportAt
        ) else {
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "audio_engine_start_failed",
                message: message,
                context: context.merging(["report_throttled": "true"]) { current, _ in current }
            )
            return
        }

        lastAudioStartFailureReportAt = now
        EventReporter.shared.capture(
            level: .error,
            engine: "parakeet",
            event: "audio_engine_start_failed",
            message: message,
            context: context
        )
    }

    func startRecording(isRecoveryAttempt: Bool = false) async -> Bool {
        guard !isShuttingDown else { return false }
        guard !isRecording else { return true }
        guard !audioStartInProgress else {
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "audio_start_deferred",
                message: "Audio start requested while another start is still in progress",
                context: [
                    "recovering": "\(recoveryState.isRecovering)",
                    "format_ready": "\(recoveryState.inputFormatReady)",
                    "generation": "\(recoveryState.generation)",
                    "audio_graph_generation": "\(audioGraphGeneration)"
                ]
            )
            return false
        }
        audioStartInProgress = true
        audioGraphGeneration += 1
        var startGeneration = audioGraphGeneration
        defer {
            audioStartInProgress = false
        }

        scheduleInputDeviceNameRefresh()
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        guard micStatus == .authorized else {
            EventReporter.shared.capture(level: .error, engine: "parakeet", event: "mic_not_authorized",
                message: "Microphone permission status: \(micStatus.rawValue)")
            return false
        }

        installAudioObserversIfNeeded()
        guard isRecoveryAttempt || recoveryState.canStartRecording else {
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "audio_start_deferred",
                message: "Audio start requested while input format is still recovering",
                context: [
                    "recovering": "\(recoveryState.isRecovering)",
                    "format_ready": "\(recoveryState.inputFormatReady)",
                    "generation": "\(recoveryState.generation)"
                ]
            )
            if !recoveryState.isRecovering {
                schedulePrewarmRetry()
            }
            return false
        }

        recordingInterrupted = false
        didReceiveAudioSamples = false
        cancelAudioWatchdog()
        pendingSamplesLock.withLock {
            pendingSamples.removeAll(keepingCapacity: true)
        }
        sampleBuffer.removeAll(keepingCapacity: true)
        sampleBuffer.reserveCapacity(Int(nativeSampleRate * Double(TranscriptedConstants.audioBufferCapacitySeconds)))

        let maxAttempts = isRecoveryAttempt ? 1 : 1 + TranscriptedConstants.audioStartRecoveryAttempts
        for attempt in 1...maxAttempts {
            guard startGeneration == audioGraphGeneration else {
                EventReporter.shared.capture(
                    level: .warning,
                    engine: "parakeet",
                    event: "audio_start_aborted",
                    message: "Audio start aborted because the audio graph changed before startup finished",
                    context: ["audio_graph_generation": "\(audioGraphGeneration)"]
                )
                return false
            }

            let snapshot: ParakeetAudioInputSnapshot
            do {
                snapshot = try await audioInputSnapshot(operation: "start_recording")
            } catch {
                EventReporter.shared.capture(
                    level: .warning,
                    engine: "parakeet",
                    event: "audio_format_unavailable",
                    message: "Audio hardware format could not be read while starting dictation",
                    context: [
                        "attempt": "\(attempt)",
                        "start_mode": isRecoveryAttempt ? "recovery" : "normal",
                        "error": error.localizedDescription
                    ]
                )
                await resetAudioGraphAfterStartFailure(reason: "audio_format_read_failed", rebuildEngine: true)
                markFormatUnreadyAndPublish()
                schedulePrewarmRetry()
                return false
            }
            guard startGeneration == audioGraphGeneration else {
                EventReporter.shared.capture(
                    level: .warning,
                    engine: "parakeet",
                    event: "audio_start_aborted",
                    message: "Audio start aborted because the audio graph changed while reading input format",
                    context: ["audio_graph_generation": "\(audioGraphGeneration)"]
                )
                return false
            }

            let readiness = audioFormatReadiness(
                outputFormat: snapshot.outputFormat,
                hwFormat: snapshot.hwFormat,
                selection: snapshot.selection
            )
            guard readiness == .ready else {
                let startFailureAction = ParakeetStartRecordingFailurePolicy.action(
                    for: readiness.startFailureReason ?? .invalidAudioFormat,
                    isRecoveryAttempt: isRecoveryAttempt
                )
                print("⚠️ PARAKEET | input format unavailable (\(readiness.rawValue)): output=\(snapshot.outputFormat.sampleRate)Hz/\(snapshot.outputFormat.channelCount)ch hw=\(snapshot.hwFormat.sampleRate)Hz/\(snapshot.hwFormat.channelCount)ch")
                var context = audioStartContext(
                    attempt: attempt,
                    isRecoveryAttempt: isRecoveryAttempt,
                    engineWasRunning: snapshot.engineWasRunning,
                    outputFormat: snapshot.outputFormat,
                    hwFormat: snapshot.hwFormat
                )
                context.merge(
                    audioFormatContext(
                        outputFormat: snapshot.outputFormat,
                        hwFormat: snapshot.hwFormat,
                        selection: snapshot.selection,
                        readiness: readiness
                    )
                ) { current, _ in current }
                EventReporter.shared.capture(
                    level: .warning,
                    engine: "parakeet",
                    event: "audio_format_unavailable",
                    message: "Audio hardware format not ready while starting dictation",
                    context: context
                )
                await resetAudioGraphAfterStartFailure(
                    reason: readiness == .routeNotSettled ? "audio_route_not_settled" : "invalid_audio_format",
                    rebuildEngine: startFailureAction.rebuildAudioEngine
                )
                if startFailureAction.markFormatUnready {
                    markFormatUnreadyAndPublish()
                }
                if startFailureAction.schedulePrewarmRetry {
                    schedulePrewarmRetry()
                }
                return false
            }

            nativeSampleRate = snapshot.outputFormat.sampleRate
            sampleBuffer.reserveCapacity(Int(nativeSampleRate * Double(TranscriptedConstants.audioBufferCapacitySeconds)))

            do {
                let startSnapshot = try await installTapAndStartEngine(isRecoveryAttempt: isRecoveryAttempt)
                guard startGeneration == audioGraphGeneration else {
                    await removeRecordingTap(force: true)
                    await stopAudioEngine()
                    EventReporter.shared.capture(
                        level: .warning,
                        engine: "parakeet",
                        event: "audio_start_aborted",
                        message: "Audio start aborted because the audio graph changed while starting",
                        context: ["audio_graph_generation": "\(audioGraphGeneration)"]
                    )
                    return false
                }
                inputTapInstalled = true
                isEnginePrewarmed = true

                if !startSnapshot.engineWasRunning && isEnginePrewarmed {
                    EventReporter.shared.capture(level: .info, engine: "parakeet",
                        event: "audio_engine_started",
                        message: "Audio engine started on worker queue",
                        context: [
                            "start_mode": isRecoveryAttempt ? "recovery" : "normal",
                            "output_rate_hz": String(format: "%.0f", snapshot.outputFormat.sampleRate),
                            "input_rate_hz": String(format: "%.0f", snapshot.hwFormat.sampleRate)
                        ])
                }
            } catch {
                let context = audioStartContext(
                    attempt: attempt,
                    isRecoveryAttempt: isRecoveryAttempt,
                    engineWasRunning: snapshot.engineWasRunning,
                    outputFormat: snapshot.outputFormat,
                    hwFormat: snapshot.hwFormat,
                    error: error
                )
                let failureReason = ParakeetAudioFormatReadinessPolicy.startFailureReason(for: error as NSError)
                let shouldRetry = failureReason == .audioEngineStartFailed
                    && ParakeetAudioStartRecoveryPolicy.shouldRetryStartFailure(
                    isRecoveryAttempt: isRecoveryAttempt,
                    failedAttempts: attempt
                )
                await resetAudioGraphAfterStartFailure(
                    reason: failureReason == .audioRouteNotSettled ? "audio_route_not_settled" : "audio_engine_start_failed",
                    rebuildEngine: true
                )

                if shouldRetry {
                    startGeneration = audioGraphGeneration
                    print("🔄 PARAKEET | audio engine start failed, resetting graph and retrying once: \(error.localizedDescription)")
                    EventReporter.shared.capture(
                        level: .warning,
                        engine: "parakeet",
                        event: "audio_engine_start_retrying",
                        message: "Audio engine failed to start; resetting graph and retrying",
                        context: context
                    )
                    continue
                }

                if failureReason == .audioRouteNotSettled {
                    print("⚠️ PARAKEET | audio route format unsupported while starting; waiting for CoreAudio to settle")
                    EventReporter.shared.capture(
                        level: .warning,
                        engine: "parakeet",
                        event: "audio_route_not_settled",
                        message: "Audio route format was not ready while starting dictation",
                        context: context
                    )
                    let startFailureAction = ParakeetStartRecordingFailurePolicy.action(
                        for: failureReason,
                        isRecoveryAttempt: isRecoveryAttempt
                    )
                    if startFailureAction.markFormatUnready {
                        markStartFailedAndPublish()
                    }
                    if startFailureAction.schedulePrewarmRetry {
                        schedulePrewarmRetry()
                    }
                    return false
                }

                print("❌ PARAKEET | audio engine failed after \(attempt) attempt(s): \(error.localizedDescription)")
                reportAudioStartFailureIfNeeded(message: error.localizedDescription, context: context)
                let startFailureAction = ParakeetStartRecordingFailurePolicy.action(
                    for: .audioEngineStartFailed,
                    isRecoveryAttempt: isRecoveryAttempt
                )
                if startFailureAction.markFormatUnready {
                    markStartFailedAndPublish()
                }
                if startFailureAction.schedulePrewarmRetry {
                    schedulePrewarmRetry()
                }
                return false
            }

            if attempt > 1 {
                EventReporter.shared.capture(
                    level: .info,
                    engine: "parakeet",
                    event: "audio_engine_start_recovered",
                    message: "Audio engine started after a graph reset",
                    context: [
                        "attempts": "\(attempt)",
                        "start_mode": isRecoveryAttempt ? "recovery" : "normal",
                        "output_rate_hz": String(format: "%.0f", snapshot.outputFormat.sampleRate),
                        "output_channels": "\(snapshot.outputFormat.channelCount)",
                        "input_rate_hz": String(format: "%.0f", snapshot.hwFormat.sampleRate),
                        "hw_channels": "\(snapshot.hwFormat.channelCount)",
                    ]
                )
            }
            lastAudioStartFailureReportAt = nil
            break
        }

        guard startGeneration == audioGraphGeneration else {
            await removeRecordingTap(force: true)
            await stopAudioEngine()
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: "audio_start_aborted",
                message: "Audio start aborted before publishing recording state",
                context: ["audio_graph_generation": "\(audioGraphGeneration)"]
            )
            return false
        }
        isRecording = true
        markFormatReadyAndPublish()
        liveTranscript = ""
        committedStreamText = ""
        if liveDisplayEnabled {
            streamingSamplesLock.withLock {
                streamingSampleBuffer.removeAll(keepingCapacity: true)
            }
            Task { await eouManager?.reset() }
        }
        print("🎤 PARAKEET | recording started (\(inputDeviceName), \(nativeSampleRate)Hz)")

        // Watchdog: detect zombie audio engine (running but no samples flowing after sleep/wake).
        // Only on first attempt — recovery attempt doesn't re-watchdog to prevent infinite loops.
        if !isRecoveryAttempt {
            startAudioWatchdog()
        }

        return true
    }

    private func extractMonoSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        guard frameCount > 0, channelCount > 0 else { return [] }

        if channelCount == 1 {
            guard let channelData = buffer.floatChannelData?[0] else { return nil }
            return Array(UnsafeBufferPointer(start: channelData, count: frameCount))
        }

        var monoSamples = Array<Float>(repeating: 0, count: frameCount)

        if buffer.format.isInterleaved {
            guard let interleavedData = buffer.floatChannelData?[0] else { return nil }
            for frame in 0..<frameCount {
                let baseIndex = frame * channelCount
                var sum: Float = 0
                for channel in 0..<channelCount {
                    sum += interleavedData[baseIndex + channel]
                }
                monoSamples[frame] = sum / Float(channelCount)
            }
            return monoSamples
        }

        guard let channelData = buffer.floatChannelData else { return nil }
        for frame in 0..<frameCount {
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += channelData[channel][frame]
            }
            monoSamples[frame] = sum / Float(channelCount)
        }
        return monoSamples
    }

    /// Watchdog that detects zombie audio engines — running but producing no samples.
    /// After sleep/wake, CoreAudio may report the engine as running but the hardware graph
    /// is disconnected. If no samples arrive within 2 seconds, tear down and retry once.
    private func startAudioWatchdog() {
        cancelAudioWatchdog()
        audioWatchdogTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: TranscriptedConstants.audioWatchdogTimeout)
            guard let self = self, self.isRecording, !Task.isCancelled else { return }

            let sampleCount = self.pendingSamplesLock.withLock {
                guard self.isRecording else { return -1 }
                return self.pendingSamples.count + self.sampleBuffer.count
            }
            guard sampleCount >= 0 else { return }

            guard sampleCount == 0 else { return }  // Audio is flowing — all good

            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "zombie_engine_detected",
                message: "No audio samples received after recording start — resetting engine",
                context: ["audio_device": self.inputDeviceName])

            // Full teardown
            self.streamingSamplesLock.withLock {
                self.streamingSampleBuffer.removeAll(keepingCapacity: true)
            }
            self.pendingSamplesLock.withLock {
                self.pendingSamples.removeAll(keepingCapacity: true)
            }
            await self.eouManager?.reset()
            await self.removeRecordingTap()
            await self.stopAudioEngine()
            self.isEnginePrewarmed = false
            self.isRecording = false
            self.audioLevel = 0

            // Brief delay for hardware to reinitialize
            try? await Task.sleep(nanoseconds: TranscriptedConstants.audioRecoveryDelay)
            guard !Task.isCancelled else { return }

            // Retry once — isRecoveryAttempt prevents another watchdog
            if await self.startRecording(isRecoveryAttempt: true) {
                print("✅ PARAKEET | zombie engine recovered — recording restarted")
                EventReporter.shared.capture(level: .info, engine: "parakeet", event: "zombie_engine_recovered",
                    message: "Audio engine recovered after reset")
            } else {
                print("❌ PARAKEET | zombie engine recovery failed")
                EventReporter.shared.capture(level: .error, engine: "parakeet", event: "zombie_engine_recovery_failed",
                    message: "Audio engine could not recover after reset",
                    context: ["audio_device": self.inputDeviceName])
                self.recordingInterrupted = true
            }
        }
    }

    func stopRecording() async {
        guard isRecording else {
            if audioStartInProgress {
                audioGraphGeneration += 1
            }
            return
        }
        audioGraphGeneration += 1
        cancelAudioWatchdog()
        if liveDisplayEnabled {
            let remainingEou: [Float] = streamingSamplesLock.withLock {
                let remainingEou = streamingSampleBuffer
                streamingSampleBuffer.removeAll(keepingCapacity: true)
                return remainingEou
            }
            if let eou = eouManager, !remainingEou.isEmpty, let pcm = makePCMBuffer(from: remainingEou) {
                Task {
                    do { _ = try await eou.process(audioBuffer: pcm) }
                    catch { EventReporter.shared.capture(level: .warning, engine: "parakeet",
                        event: "eou_process_error", message: error.localizedDescription) }
                }
            }
        }
        await removeRecordingTap()
        await stopAudioEngine()
        isEnginePrewarmed = false
        drainPendingSamplesIntoSampleBuffer()
        isRecording = false
        audioLevel = 0
        print("⏹️ PARAKEET | recording stopped (\(sampleBuffer.count) samples, \(String(format: "%.1f", Double(sampleBuffer.count) / nativeSampleRate))s)")
    }

    // MARK: - EOU Streaming (live display)
    // Live display is driven by StreamingEouAsrManager fed via the audio tap (see startRecording).
    // EOU callback in initializeEouModel() updates committedStreamText → liveTranscript.
    // No explicit start/stop methods needed — tap feeds the manager, reset() clears state.

    private func drainPendingSamplesIntoSampleBuffer() {
        pendingSamplesLock.withLock {
            guard !pendingSamples.isEmpty else { return }
            if sampleBuffer.isEmpty {
                swap(&sampleBuffer, &pendingSamples)
            } else {
                sampleBuffer.append(contentsOf: pendingSamples)
                pendingSamples.removeAll(keepingCapacity: false)
            }
        }
    }

    /// Convert [Float] samples to AVAudioPCMBuffer for StreamingEouAsrManager.
    private func makePCMBuffer(from samples: [Float]) -> AVAudioPCMBuffer? {
        guard let format = eouPCMFormat,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let dest = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                dest.update(from: src.baseAddress!, count: samples.count)
            }
        }
        return buffer
    }

    // MARK: - Transcription

    func drainRecordedSamplesForExternalTranscription(engineName: String) async -> RecordedSpeechSamples? {
        guard !isTranscribing else {
            EventReporter.shared.capture(
                level: .warning,
                engine: engineName,
                event: "transcription_already_active",
                message: "transcribe() called while transcription already in progress"
            )
            return nil
        }

        drainPendingSamplesIntoSampleBuffer()

        guard !sampleBuffer.isEmpty else {
            EventReporter.shared.capture(
                level: .warning,
                engine: engineName,
                event: "no_audio_samples",
                message: "No audio samples in buffer when transcribe() called"
            )
            return nil
        }

        isTranscribing = true
        var samples: [Float] = []
        swap(&samples, &sampleBuffer)
        let inputRate = nativeSampleRate
        let nativeCount = samples.count
        let samplesForResampling = samples
        samples.removeAll(keepingCapacity: false)
        let resampled = await Task.detached(priority: .userInitiated) {
            AudioResampler.resample(samplesForResampling, from: inputRate, to: 16000)
        }.value
        print("🔄 \(engineName.uppercased()) | resampled \(nativeCount) → \(resampled.count) samples")

        let shortAudioDecision = ParakeetShortAudioGate.dictation(
            nativeSampleCount: nativeCount,
            resampledSampleCount: resampled.count
        )
        guard shortAudioDecision.shouldTranscribe else {
            let audioDuration = shortAudioDecision.context["audio_duration_s"] ?? "0.00"
            print("⚠️ \(engineName.uppercased()) | skipping transcription for short audio (\(audioDuration)s)")
            EventReporter.shared.capture(
                level: .warning,
                engine: engineName,
                event: shortAudioDecision.event ?? "recording_too_short",
                message: shortAudioDecision.message ?? "Dictation audio too short for transcription",
                context: shortAudioDecision.context
            )
            finishExternalTranscription()
            return nil
        }

        return RecordedSpeechSamples(nativeSampleCount: nativeCount, samples16k: resampled)
    }

    func finishExternalTranscription() {
        isTranscribing = false
        sampleBuffer.removeAll(keepingCapacity: true)
    }

    func transcribe() async -> String? {
        guard !isTranscribing else {
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "transcription_already_active",
                message: "transcribe() called while transcription already in progress")
            return nil
        }
        drainPendingSamplesIntoSampleBuffer()
        guard !sampleBuffer.isEmpty else {
            EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "no_audio_samples",
                message: "No audio samples in buffer when transcribe() called")
            return nil
        }
        guard let manager = asrManager, asrManagerReady else {
            print("❌ PARAKEET | ASR manager not available")
            EventReporter.shared.capture(level: .error, engine: "parakeet", event: "asr_manager_unavailable",
                message: "ASR manager not available for transcription")
            return nil
        }

        isTranscribing = true
        // Swap instead of copy — moves data out of sampleBuffer without allocating a duplicate.
        // sampleBuffer is cleared immediately, freeing capacity before resampling.
        var samples: [Float] = []
        swap(&samples, &sampleBuffer)
        let inputRate = nativeSampleRate

        let startTime = CFAbsoluteTimeGetCurrent()

        // Resample to 16kHz for Parakeet inference, then free the native-rate buffer
        // before inference — avoids holding both the raw and resampled arrays simultaneously.
        let nativeCount = samples.count
        let samplesForResampling = samples
        samples.removeAll(keepingCapacity: false)
        let resampled = await Task.detached(priority: .userInitiated) {
            AudioResampler.resample(samplesForResampling, from: inputRate, to: 16000)
        }.value
        print("🔄 PARAKEET | resampled \(nativeCount) → \(resampled.count) samples")

        let shortAudioDecision = ParakeetShortAudioGate.dictation(
            nativeSampleCount: nativeCount,
            resampledSampleCount: resampled.count
        )
        guard shortAudioDecision.shouldTranscribe else {
            let audioDuration = shortAudioDecision.context["audio_duration_s"] ?? "0.00"
            print("⚠️ PARAKEET | skipping transcription for short audio (\(audioDuration)s)")
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: shortAudioDecision.event ?? "recording_too_short",
                message: shortAudioDecision.message ?? "Dictation audio too short for transcription",
                context: shortAudioDecision.context
            )
            isTranscribing = false
            sampleBuffer.removeAll(keepingCapacity: true)
            return nil
        }

        do {
            let result = try await manager.transcribe(resampled, source: .microphone)
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            let trimmed = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let corrected = CustomDictionaryTextProcessor.apply(to: trimmed)

            let audioDuration = Double(resampled.count) / TranscriptedConstants.parakeetSampleRate
            let rtf = audioDuration > 0 ? elapsed / audioDuration : 0
            print("✅ PARAKEET | transcribed in \(String(format: "%.2f", elapsed))s: \"\(corrected.prefix(80))...\"")

            if trimmed.isEmpty {
                let analysis = DictationAudioRecovery.analyze(
                    samples: resampled,
                    sampleRate: TranscriptedConstants.parakeetSampleRate
                )
                var emptyContext = ["samples": "\(nativeCount)"]
                emptyContext.merge(analysis.context) { current, _ in current }

                if let retrySamples = DictationAudioRecovery.retrySamples(
                    from: resampled,
                    sampleRate: TranscriptedConstants.parakeetSampleRate,
                    analysis: analysis
                ) {
                    let retryStarted = CFAbsoluteTimeGetCurrent()
                    EventReporter.shared.capture(
                        level: .info,
                        engine: "parakeet",
                        event: "dictation_empty_retry_started",
                        message: "Retrying empty dictation with focused audio",
                        context: emptyContext.merging([
                            "retry_samples": "\(retrySamples.count)",
                            "retry_audio_duration_s": String(format: "%.2f", Double(retrySamples.count) / TranscriptedConstants.parakeetSampleRate),
                        ]) { current, _ in current }
                    )

                    do {
                        let retryResult = try await manager.transcribe(retrySamples, source: .microphone)
                        let retryElapsed = CFAbsoluteTimeGetCurrent() - retryStarted
                        let retryTrimmed = retryResult.text.trimmingCharacters(in: .whitespacesAndNewlines)
                        let retryCorrected = CustomDictionaryTextProcessor.apply(to: retryTrimmed)
                        if !retryTrimmed.isEmpty {
                            let totalElapsed = CFAbsoluteTimeGetCurrent() - startTime
                            let retryDuration = Double(retrySamples.count) / TranscriptedConstants.parakeetSampleRate
                            let retryRtf = retryDuration > 0 ? retryElapsed / retryDuration : 0
                            EventReporter.shared.capture(level: .info, engine: "parakeet", event: "transcription_recovered",
                                message: "Recovered empty dictation on retry",
                                context: emptyContext.merging([
                                    "elapsed_s": String(format: "%.3f", totalElapsed),
                                    "retry_elapsed_s": String(format: "%.3f", retryElapsed),
                                    "retry_audio_duration_s": String(format: "%.2f", retryDuration),
                                    "retry_rtf": String(format: "%.3f", retryRtf),
                                    "retry_samples": "\(retrySamples.count)",
                                    "chars": "\(retryCorrected.count)",
                                    "input_samples": "\(nativeCount)",
                                ]) { current, _ in current })
                            isTranscribing = false
                            sampleBuffer.removeAll(keepingCapacity: true)
                            return retryCorrected
                        }

                        emptyContext["retry_empty"] = "true"
                        emptyContext["retry_elapsed_s"] = String(format: "%.3f", retryElapsed)
                        emptyContext["retry_samples"] = "\(retrySamples.count)"
                    } catch {
                        emptyContext["retry_error"] = error.localizedDescription
                    }
                } else if !analysis.hasUsableSpeechSignal {
                    EventReporter.shared.capture(
                        level: .warning,
                        engine: "parakeet",
                        event: "dictation_audio_silent",
                        message: "Dictation audio did not contain enough speech-like signal",
                        context: emptyContext
                    )
                }

                EventReporter.shared.capture(level: .warning, engine: "parakeet", event: "transcription_empty",
                    message: "Parakeet returned no text after \(String(format: "%.1f", elapsed))s inference",
                    context: emptyContext)
                isTranscribing = false
                sampleBuffer.removeAll(keepingCapacity: true)
                return nil
            }

            isTranscribing = false
            sampleBuffer.removeAll(keepingCapacity: true)

            EventReporter.shared.capture(level: .info, engine: "parakeet", event: "transcription_complete",
                message: "Transcribed in \(String(format: "%.2f", elapsed))s",
                context: [
                    "elapsed_s": String(format: "%.3f", elapsed),
                    "audio_duration_s": String(format: "%.1f", audioDuration),
                    "rtf": String(format: "%.3f", rtf),
                    "chars": "\(corrected.count)",
                    "input_samples": "\(nativeCount)",
                ])
            return corrected
        } catch {
            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            if let fallbackDecision = ParakeetShortAudioGate.dictationFallback(
                nativeSampleCount: nativeCount,
                resampledSampleCount: resampled.count,
                errorMessage: error.localizedDescription
            ) {
                var fallbackContext = fallbackDecision.context
                fallbackContext["elapsed"] = String(format: "%.2f", elapsed)
                EventReporter.shared.capture(
                    level: .warning,
                    engine: "parakeet",
                    event: fallbackDecision.event ?? "recording_too_short",
                    message: fallbackDecision.message ?? "Dictation audio too short for transcription",
                    context: fallbackContext
                )
                isTranscribing = false
                sampleBuffer.removeAll(keepingCapacity: true)
                return nil
            }

            print("❌ PARAKEET | transcription failed: \(error.localizedDescription)")
            EventReporter.shared.capture(level: .error, engine: "parakeet", event: "transcription_failed",
                message: error.localizedDescription,
                context: ["samples": "\(nativeCount)", "elapsed": String(format: "%.2f", elapsed)])
            isTranscribing = false
            sampleBuffer.removeAll(keepingCapacity: true)
            return nil
        }
    }

    // MARK: - Pure-Sample Transcription (for Meeting pipeline)

    /// Transcribe pre-resampled 16kHz mono Float32 samples directly, bypassing
    /// ParakeetEngine's recording lifecycle (audioEngine, sampleBuffer, EOU streaming).
    ///
    /// Used by `MeetingSTTAdapter` to satisfy Core's `SpeechToTextEngine` protocol:
    /// Core's TranscriptionPipeline owns its own recording (mic + system audio files via
    /// `Audio.swift`), extracts 16kHz samples per speaker segment, and calls this method
    /// once per segment. This is distinct from the app's regular dictation flow, which uses
    /// `startRecording()` / `transcribe()` to capture and transcribe in one shot.
    ///
    /// - Parameters:
    ///   - samples: 16kHz mono Float32 samples. Caller must resample; we do not.
    ///   - source: FluidAudio's `AudioSource` (`.microphone` or `.system`).
    /// - Returns: Transcribed text, trimmed. Empty string if Parakeet returned nothing.
    /// - Throws: Re-throws `AsrManager.transcribe` errors (including model-not-ready).
    func transcribeSamples(_ samples: [Float], source: AudioSource) async throws -> String {
        guard let manager = asrManager, asrManagerReady else {
            EventReporter.shared.capture(level: .error, engine: "parakeet", event: "asr_manager_unavailable",
                message: "ASR manager not available for transcribeSamples")
            throw NSError(domain: "ParakeetEngine", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Parakeet ASR manager is not loaded"
            ])
        }
        guard !samples.isEmpty else { return "" }
        let shortAudioDecision = ParakeetShortAudioGate.meetingSegment(
            sampleCount: samples.count,
            sourceDescription: source == .microphone ? "microphone" : "system"
        )
        guard shortAudioDecision.shouldTranscribe else {
            EventReporter.shared.capture(
                level: .warning,
                engine: "parakeet",
                event: shortAudioDecision.event ?? "segment_too_short",
                message: shortAudioDecision.message ?? "Skipped short audio segment before Parakeet transcription",
                context: shortAudioDecision.context
            )
            return ""
        }

        let startTime = CFAbsoluteTimeGetCurrent()
        let sourceDescription = source == .microphone ? "microphone" : "system"
        let resultText: String
        do {
            let result = try await manager.transcribe(samples, source: source)
            resultText = result.text
        } catch {
            if let fallbackDecision = ParakeetShortAudioGate.meetingSegmentFallback(
                sampleCount: samples.count,
                sourceDescription: sourceDescription,
                errorMessage: error.localizedDescription
            ) {
                EventReporter.shared.capture(
                    level: .warning,
                    engine: "parakeet",
                    event: fallbackDecision.event ?? "segment_too_short",
                    message: fallbackDecision.message ?? "Skipped short audio segment before Parakeet transcription",
                    context: fallbackDecision.context
                )
                return ""
            }
            throw error
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        let trimmed = resultText.trimmingCharacters(in: .whitespacesAndNewlines)
        let corrected = CustomDictionaryTextProcessor.apply(to: trimmed)

        let audioDuration = Double(samples.count) / TranscriptedConstants.parakeetSampleRate
        let rtf = audioDuration > 0 ? elapsed / audioDuration : 0
        EventReporter.shared.capture(level: .info, engine: "parakeet", event: "meeting_segment_transcribed",
            message: "Meeting segment transcribed in \(String(format: "%.2f", elapsed))s",
            context: [
                "elapsed_s": String(format: "%.3f", elapsed),
                "audio_duration_s": String(format: "%.2f", audioDuration),
                "rtf": String(format: "%.3f", rtf),
                "chars": "\(corrected.count)",
            ])

        return corrected
    }

    // MARK: - Cleanup

    func cancel() {
        cancelAudioWatchdog()
        prewarmRetryTask?.cancel()
        prewarmRetryTask = nil
        pendingSamplesLock.withLock {
            pendingSamples.removeAll(keepingCapacity: true)
        }
        if isRecording {
            if liveDisplayEnabled {
                streamingSamplesLock.withLock {
                    streamingSampleBuffer.removeAll(keepingCapacity: true)
                }
                Task { await eouManager?.reset() }
            }
            isRecording = false
            audioLevel = 0
        }
        audioGraphGeneration += 1
        let cleanupGeneration = audioGraphGeneration
        Task { @MainActor [weak self] in
            await self?.releaseIdleAudioHardware(removeTap: true, expectedGeneration: cleanupGeneration)
        }
        sampleBuffer.removeAll()
        isTranscribing = false
        liveTranscript = ""
        committedStreamText = ""
    }

    private func releaseIdleAudioHardware(removeTap: Bool, expectedGeneration: Int? = nil) async {
        if let expectedGeneration, expectedGeneration != audioGraphGeneration {
            return
        }
        audioGraphGeneration += 1
        let cleanupGeneration = audioGraphGeneration
        if removeTap {
            await removeRecordingTap(force: true)
        }
        if expectedGeneration != nil, cleanupGeneration != audioGraphGeneration {
            return
        }
        await stopAudioEngine()
        if expectedGeneration != nil, cleanupGeneration != audioGraphGeneration {
            return
        }
        isEnginePrewarmed = false
    }

    private func cancelAudioWatchdog() {
        audioWatchdogTask?.cancel()
        audioWatchdogTask = nil
    }

    func cleanup() {
        isShuttingDown = true
        cancelAudioWatchdog()
        prewarmRetryTask?.cancel()
        prewarmRetryTask = nil
        configChangeDebounceTask?.cancel()
        configChangeDebounceTask = nil
        configRecoveryTask?.cancel()
        configRecoveryTask = nil
        audioGraphGeneration += 1
        let cleanupGeneration = audioGraphGeneration
        Task { @MainActor [weak self] in
            await self?.releaseIdleAudioHardware(removeTap: true, expectedGeneration: cleanupGeneration)
        }
        isRecording = false
        audioLevel = 0
        removeAudioEngineConfigObserver()
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }
        removeInputDeviceChangeListener()
        let mgr = asrManager
        asrManager = nil
        asrManagerReady = false
        eouManager = nil
        modelDownloadState = .notLoaded
        Task { mgr?.cleanup() }
    }

    deinit {
        if let observer = configChangeObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        unregisterDefaultInputDeviceListener(inputDeviceChangeListener)
        audioEngineQueue.async { [audioEngine] in
            audioEngine.inputNode.removeTap(onBus: 0)
            if audioEngine.isRunning {
                audioEngine.stop()
            }
        }
        let mgr = asrManager
        Task { mgr?.cleanup() }
        eouManager = nil
    }
}
