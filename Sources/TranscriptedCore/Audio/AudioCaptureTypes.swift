import Foundation
@preconcurrency import AVFoundation

// Capture value and policy types shared by `Audio` and its embedders:
// stop cleanup, lifecycle cues, system-audio status, recording-format
// policy, input-tap teardown order, and sleep/wake notification names.

public enum RecordingStopFinalizationDisposition: Sendable, Equatable {
    case finalized
    case journalRecoveryOwned
}

/// Keep independent audio backends independent during shutdown. Each writer
/// closes only after its producer stops and its serial queue drains. Completion
/// also waits for any host-buffer drain already registered in `group`.
enum AudioStopCleanup {
    static func schedule(
        group: DispatchGroup,
        microphoneFileQueue: DispatchQueue,
        systemFileQueue: DispatchQueue,
        stopMicrophone: @escaping () -> Void,
        stopSystem: @escaping () -> Void,
        closeMicrophone: @escaping () -> Void,
        closeSystem: @escaping () -> Void,
        completion: @escaping () -> Void
    ) {
        // Register both branches before dispatch or notify: either branch can
        // finish immediately, including when recording never finished starting.
        group.enter()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            stopMicrophone()
            microphoneFileQueue.async {
                closeMicrophone()
                group.leave()
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            stopSystem()
            systemFileQueue.async {
                closeSystem()
                group.leave()
            }
        }
        group.notify(queue: .global(qos: .utility), execute: completion)
    }
}

/// Lifecycle cues emitted by `Audio` so embedders can react without `Audio`
/// itself depending on AppKit / NSSound.
///
/// `recordingStarted` / `recordingStopped` are cosmetic (UI sounds).
/// `micAttenuatedByForeignVoiceProcessing` is an actionable one-shot signal:
/// the mic stayed attenuated for ~30s despite the software AGC pinned at max
/// gain (issue #500 — a foreign app holds the shared input device in macOS
/// voice/communication mode). Hosts may route it to a consent prompt that
/// offers Apple voice processing for the active recording.
public enum CaptureLifecycleCue: Sendable {
    case recordingStarted
    case recordingStopped
    case micAttenuatedByForeignVoiceProcessing
    case meetingRouteStabilityWarning(CaptureRouteStabilizationOutcome)
}

/// Coarse, privacy-safe result of the one bounded input-route stabilization
/// attempt allowed during a meeting. The value is also safe to expose to host
/// UI and analytics because it contains no device identity.
public enum CaptureRouteStabilizationOutcome: String, Equatable, Sendable {
    case notNeeded = "not_needed"
    case switchedToBuiltIn = "switched_to_built_in"
    case builtInUnavailable = "built_in_unavailable"
    case switchFailed = "switch_failed"
}

/// Status of system audio capture for UI feedback
/// Used to show warnings when device switching or audio loss occurs
public enum SystemAudioStatus: Equatable {
    case unknown        // Not recording
    case healthy        // Receiving audio data normally
    case reconnecting   // Device change detected, recovering (~200ms)
    case silent         // Prolonged silence (>10s) - might indicate capture issue
    case failed         // Recovery failed - system audio unavailable

    public var isWarning: Bool {
        switch self {
        case .silent, .failed: return true
        default: return false
        }
    }

    public var isRecovering: Bool {
        self == .reconnecting
    }

    public var displayText: String {
        switch self {
        case .unknown: return ""
        case .healthy: return ""
        case .reconnecting: return "Reconnecting..."
        case .silent: return "System audio silent"
        case .failed: return "System audio unavailable \u{2014} try recording again"
        }
    }
}

struct AudioRecordingFormatSnapshot: Equatable {
    let sampleRate: Double
    let channelCount: AVAudioChannelCount
}

struct AudioCaptureStaleSessionError: LocalizedError {
    var errorDescription: String? {
        "Recording start was cancelled before audio capture finished"
    }
}

enum AudioRecordingFormatPolicy {
    private static let minimumUsableSampleRate: Double = 8_000
    private static let maximumUsableSampleRate: Double = 384_000

    static func snapshot(_ format: AVAudioFormat) -> AudioRecordingFormatSnapshot? {
        let sampleRate = format.sampleRate
        let channelCount = format.channelCount
        guard isUsableSampleRate(sampleRate), channelCount > 0 else {
            return nil
        }
        return AudioRecordingFormatSnapshot(sampleRate: sampleRate, channelCount: channelCount)
    }

    static func isUsableSampleRate(_ sampleRate: Double) -> Bool {
        sampleRate.isFinite
            && sampleRate >= minimumUsableSampleRate
            && sampleRate <= maximumUsableSampleRate
    }

    static func displaySampleRate(_ sampleRate: Double) -> String {
        isUsableSampleRate(sampleRate) ? "\(Int(sampleRate))" : "invalid"
    }

    static func makeMonoOutputFormat(sampleRate: Double) throws -> AVAudioFormat {
        guard isUsableSampleRate(sampleRate) else {
            throw NSError(domain: "AudioRecordingFormatPolicy", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Refusing to create mic format from invalid sample rate"
            ])
        }

        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw NSError(domain: "AudioRecordingFormatPolicy", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Failed to create mono mic format"
            ])
        }

        return monoFormat
    }
}

public enum AudioInputTapTeardownStep: Equatable, Sendable {
    case stopEngine
    case waitForStoppedInputCallbacks
    case removeInputTap
}

/// Single source of truth for the order in which an AVAudioEngine input tap may
/// be torn down. A running graph MUST stop and let in-flight input callbacks
/// drain BEFORE the tap is removed; otherwise CoreAudio can deliver input to a
/// node that has neither a tap nor a sink and trips the fatal assertion
/// `required condition is false: isSink || tap != nullptr`.
///
/// Shared by the meeting/mic capture path (`Audio.tearDownInputTapSafely`) and
/// the dictation path (`ParakeetEngine`) so both honor the same ordering.
public enum AudioInputTapTeardownPolicy {
    public static let inputCallbackDrainDelay: TimeInterval = 0.05

    public static func steps(engineIsRunning: Bool) -> [AudioInputTapTeardownStep] {
        engineIsRunning
            ? [.stopEngine, .waitForStoppedInputCallbacks, .removeInputTap]
            : [.removeInputTap]
    }
}

/// Host-provided sleep/wake notifications for recording gap tracking.
///
/// The default uses macOS workspace notification names without importing
/// AppKit, so `TranscriptedCore` stays a reusable library boundary.
public struct AudioSleepWakeNotifications: Sendable {
    public let center: NotificationCenter
    public let willSleepName: Notification.Name
    public let didWakeName: Notification.Name

    public init(
        center: NotificationCenter = .default,
        willSleepName: Notification.Name,
        didWakeName: Notification.Name
    ) {
        self.center = center
        self.willSleepName = willSleepName
        self.didWakeName = didWakeName
    }

    public static let macOSWorkspace = AudioSleepWakeNotifications(
        willSleepName: Notification.Name("NSWorkspaceWillSleepNotification"),
        didWakeName: Notification.Name("NSWorkspaceDidWakeNotification")
    )
}
