import Combine
import Foundation
@preconcurrency import AVFoundation
import QuartzCore
import TranscriptedCore

/// Local provisional text while the existing meeting recorder owns both tracks.
/// Only explicit per-session sharing starts inference. The final meeting pipeline
/// still independently diarizes, transcribes and saves its authoritative Markdown.
@MainActor
final class LiveMeetingTranscriptService {
    static let shared = LiveMeetingTranscriptService()
    private(set) var sessionID: UUID?
    private(set) var sharingEnabled = false
    private var state = "idle"
    /// A meeting is recording; a dictation inside it shows the meeting's
    /// transcript on hover, not its own preview.
    var isRecording: Bool { state == "recording" }
    private var liveStatus = "disabled"
    private var transcript = LiveMeetingTranscriptState()
    nonisolated let inbox = LiveMeetingAudioInbox()
    private var worker: Task<Void, Never>?
    private var workerGeneration = UUID()
    private weak var router: STTRouter?
    private var model: TranscriptionModelChoice?
    private var language: TranscriptionLanguageContext?
    private var origin: TimeInterval = 0
    private var sessionStartedAt: Date?
    private var finishedElapsed: TimeInterval?
    private var latestTextAt: Date?
    private var deliveryEnabled: ((Bool, UInt64) -> Void)?
    private var previewEpoch: UInt64 = 0
    private var deliveryDrops: (() -> Int)?
    private var mayInfer: (() -> Bool)?
    private var lastErrorCode: String?
    private var captionsYield: (@MainActor @Sendable () -> Bool)?
    private var captionsCaptureSystemAudio = true
    /// `captionsYield`'s answer, kept current on main for the caption tracks'
    /// drain loops so they never hop to the main actor to ask.
    nonisolated private let captionsYieldFlag = LiveMeetingCaptionYield()
    private var captionsYieldWatch: AnyCancellable?
    private var lastDelivery: (enabled: Bool, epoch: UInt64)?
    private var captionsStatusWatch: AnyCancellable?
    private var captionsSetting = NotchIslandPreferences.showsLiveTranscript()
    private var settingsObserver: NSObjectProtocol?

    private init() {
        // Captions that fail to load stop needing audio.
        captionsStatusWatch = LiveMeetingCaptions.shared.$status
            .removeDuplicates()
            // @Published fires before the value lands; read it after.
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.updateDelivery() }
            }
        // Turning "Live transcript" on or off mid-meeting applies at once.
        settingsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let setting = NotchIslandPreferences.showsLiveTranscript()
                guard setting != self.captionsSetting else { return }
                self.captionsSetting = setting
                self.refreshCaptions()
                if setting {
                    LiveMeetingCaptions.shared.prewarm()
                } else {
                    LiveMeetingCaptions.shared.cancelPrewarm()
                }
            }
        }
        if captionsSetting { LiveMeetingCaptions.shared.prewarm() }
    }

    func beginCapture(sessionID: UUID, router: STTRouter, model: TranscriptionModelChoice,
                      languageSelection: TranscriptionLanguageSelection,
                      capturesSystemAudio: Bool,
                      deliveryEnabled: @escaping (Bool, UInt64) -> Void, deliveryDrops: @escaping () -> Int,
                      mayInfer: @escaping () -> Bool,
                      shouldCaptionsYield: @escaping @MainActor @Sendable () -> Bool = { false }) {
        self.setDelivery(false)
        previewEpoch &+= 1
        worker?.cancel()
        workerGeneration = UUID()
        inbox.cancel()
        self.sessionID = sessionID
        self.router = router
        self.model = model
        captionsCaptureSystemAudio = capturesSystemAudio
        if case .explicit(let code) = languageSelection {
            language = TranscriptionLanguageContext(selection: languageSelection, languageCode: code, resolution: .explicit)
        } else {
            language = nil
        }
        self.deliveryEnabled = deliveryEnabled
        self.deliveryDrops = deliveryDrops
        self.mayInfer = mayInfer
        origin = CACurrentMediaTime()
        sessionStartedAt = Date()
        finishedElapsed = nil
        latestTextAt = nil
        state = "recording"
        sharingEnabled = false
        liveStatus = "disabled"
        lastErrorCode = nil
        transcript = LiveMeetingTranscriptState()
        captionsYield = shouldCaptionsYield
        syncCaptionsYield()
        captionsYieldWatch = Publishers.Merge(
            router.$isRecording.removeDuplicates().map { _ in () },
            router.$isTranscribing.removeDuplicates().map { _ in () }
        )
        // @Published fires before the value lands; read it after.
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            MainActor.assumeIsolated { self?.syncCaptionsYield() }
        }
        refreshCaptions()
    }

    /// Starts or stops the island's live transcript to match the setting,
    /// for the recording in progress. Safe to call any time.
    func refreshCaptions() {
        let captions = LiveMeetingCaptions.shared
        let wanted = state == "recording" && NotchIslandPreferences.showsLiveTranscript()
        if wanted, let sessionID, captionsYield != nil {
            captions.start(sessionID: sessionID, capturesSystemAudio: captionsCaptureSystemAudio,
                           shouldYield: captionsYieldFlag)
        } else if !wanted {
            captions.stop()
        }
        updateDelivery()
    }

    private func syncCaptionsYield() {
        captionsYieldFlag.set(captionsYield?() ?? false)
    }

    /// Core restarts its delivery generation (dropping buffers in flight and
    /// zeroing its drop count) on every call, so only call when something
    /// actually changed.
    private func setDelivery(_ enabled: Bool) {
        guard lastDelivery?.enabled != enabled || lastDelivery?.epoch != previewEpoch else { return }
        lastDelivery = (enabled, previewEpoch)
        deliveryEnabled?(enabled, previewEpoch)
    }

    /// Live PCM flows while either consumer wants it: agent sharing (gated by
    /// the preview epoch in the inbox) or the island's live transcript.
    private func updateDelivery() {
        let sharingNeedsAudio = sharingEnabled && liveStatus != "unavailable"
        let wanted = state == "recording" && (sharingNeedsAudio || LiveMeetingCaptions.shared.isActive)
        setDelivery(wanted)
    }

    @discardableResult
    func setSharingEnabled(_ enabled: Bool, sessionID: UUID) -> Bool {
        guard self.sessionID == sessionID else { return false }
        guard !enabled || state == "recording" else { return false }
        guard enabled != sharingEnabled else { return true }
        setDelivery(false)
        previewEpoch &+= 1
        sharingEnabled = enabled
        if !enabled {
            worker?.cancel()
            workerGeneration = UUID()
            inbox.cancel()
            transcript.clear()
            latestTextAt = nil
            liveStatus = "disabled"
            lastErrorCode = nil
            updateDelivery()
        } else if state == "recording" {
            inbox.begin(sessionID: sessionID, origin: origin, previewEpoch: previewEpoch)
            setDelivery(true)
            startWorker(sessionID: sessionID)
        } else {
            liveStatus = "finished"
        }
        return true
    }

    func finishCapture(sessionID: UUID) {
        guard self.sessionID == sessionID else { return }
        setDelivery(false)
        LiveMeetingCaptions.shared.stop(sessionID: sessionID)
        captionsYieldWatch = nil
        state = "finished"
        finishedElapsed = max(0, CACurrentMediaTime() - origin)
        inbox.finish()
        if !sharingEnabled { liveStatus = "disabled" }
    }

    /// Invoked on Core's bounded live-delivery worker, not an audio callback.
    nonisolated func receive(_ buffer: AVAudioPCMBuffer, source: LiveMeetingAudioSource, capturedAt: TimeInterval, previewEpoch: UInt64) {
        guard let samples = LiveMeetingAudioDownmix.monoSamples(buffer), !samples.isEmpty else { return }
        let rate = buffer.format.sampleRate
        guard rate.isFinite, rate >= 8_000, rate <= 192_000 else { return }
        let resampled = AudioResampler.resample(samples, from: rate, to: 16_000)
        LiveMeetingCaptions.inlet.offer(resampled, track: source == .microphone ? .microphone : .system)
        inbox.append(samples: resampled, source: source == .microphone ? .microphone : .system,
            capturedAt: capturedAt, expectedEpoch: previewEpoch)
    }

    func statusSnapshot() -> [String: Any] {
        let observedAt = Date()
        let elapsed = sessionID == nil ? 0 : finishedElapsed ?? max(0, CACurrentMediaTime() - origin)
        let latestAudioEnd = transcript.segments.map(\.endSeconds).max()
        var result: [String: Any] = [
            "session_id": sessionID.map { $0.uuidString as Any } ?? NSNull(), "state": state,
            "live_status": liveStatus, "sharing_enabled": sharingEnabled,
            "segment_count": transcript.segments.count,
            "first_sequence": transcript.segments.first?.sequence ?? transcript.latestSequence + 1,
            "latest_sequence": transcript.latestSequence, "provisional": true,
            "dropped_windows": inbox.dropCount, "dropped_audio_buffers": deliveryDrops?() ?? 0,
            "pending_windows": inbox.pendingWindowCount,
            "snapshot_at_unix_seconds": observedAt.timeIntervalSince1970,
            "session_started_at_unix_seconds": sessionStartedAt.map { $0.timeIntervalSince1970 as Any } ?? NSNull(),
            "latest_text_at_unix_seconds": latestTextAt.map { $0.timeIntervalSince1970 as Any } ?? NSNull(),
            "capture_elapsed_seconds": elapsed,
            "latest_text_audio_end_seconds": latestAudioEnd.map { $0 as Any } ?? NSNull(),
            // This is distance from the most recently recognized speech to the
            // capture position. Silence can also increase it; queue/status tell
            // the host whether inference is actually paused or falling behind.
            "preview_lag_seconds": latestAudioEnd.map { max(0, elapsed - $0) as Any } ?? NSNull(),
            "update_interval_seconds": 4,
            "audio_overlap_seconds": 0.5,
            "speaker_labels": "capture_track_only"
        ]
        if let model { result["model"] = model.rawValue }
        result["language_selection"] = language?.selection.rawValue ?? "auto"
        if let lastErrorCode { result["error_code"] = lastErrorCode }
        return result
    }

    /// Sharing is enforced here as well as in the native bridge. Disabling it
    /// clears retained text and audio; a stale caller can never read a new call.
    func readLive(sessionID: UUID, afterSequence: Int = 0, limit: Int = 30) -> [String: Any]? {
        guard self.sessionID == sessionID, sharingEnabled else { return nil }
        let segments = transcript.window(afterSequence: afterSequence, limit: limit)
        var result = statusSnapshot()
        result["segments"] = segments.map(\.payload)
        let next = segments.last?.sequence ?? max(0, afterSequence)
        result["next_sequence"] = next
        result["truncated"] = next < transcript.latestSequence
        result["context_gap"] = (afterSequence > 0 && (transcript.segments.first?.sequence ?? 1) > afterSequence + 1) || inbox.dropCount > 0 || (deliveryDrops?() ?? 0) > 0
        return result
    }

    private func startWorker(sessionID: UUID) {
        guard let router, let requestedModel = model else {
            liveStatus = "unavailable"
            lastErrorCode = "model_unavailable"
            return
        }
        worker?.cancel()
        let generation = UUID()
        workerGeneration = generation
        let retainedModel = router.retainModelForForegroundUse(requestedModel)
        let captureLanguage = language
        model = retainedModel
        liveStatus = "waiting_for_model"
        worker = Task { @MainActor [weak self, router] in
            defer { router.releaseModelFromForegroundUse(retainedModel) }
            await router.initializeRetainedModel(retainedModel)
            guard let self, self.isCurrent(sessionID, generation), !Task.isCancelled else { return }
            guard router.isModelLoaded(for: retainedModel) else {
                self.liveStatus = "unavailable"
                self.lastErrorCode = "model_unavailable"
                // The island's live transcript may still need the audio.
                self.updateDelivery()
                self.inbox.cancel()
                return
            }
            while self.isCurrent(sessionID, generation), !Task.isCancelled {
                // Dictation and the authoritative saved-meeting job have priority.
                // Parakeet also serializes inference, including pure-sample callers.
                if router.isRecording || router.isTranscribing || router.parakeetEngine.hasActiveASRWork || self.mayInfer?() == false {
                    self.liveStatus = "paused_for_other_transcription"
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                guard let window = self.inbox.take() else {
                    if self.state == "finished" { self.liveStatus = "finished"; return }
                    self.liveStatus = "listening"
                    try? await Task.sleep(for: .milliseconds(250))
                    continue
                }
                guard window.sessionID == sessionID else { continue }
                // Avoid sending exact silence through the model. No speech or
                // language is inferred from capture readiness/recording bytes.
                let energy = window.samples.reduce(Double(0)) { $0 + Double($1 * $1) } / Double(window.samples.count)
                guard energy > 0.000_000_09 else { continue }
                self.liveStatus = "transcribing"
                do {
                    let text = try await router.transcribeSegment(samples: window.samples,
                        source: window.source == .microphone ? .microphone : .system, model: retainedModel,
                        language: captureLanguage)
                    guard self.isCurrent(sessionID, generation), !Task.isCancelled else { return }
                    let previousSequence = self.transcript.latestSequence
                    self.transcript.append(text: text, startSeconds: window.startSeconds,
                        endSeconds: window.endSeconds, source: window.source)
                    if self.transcript.latestSequence != previousSequence { self.latestTextAt = Date() }
                    self.lastErrorCode = nil
                } catch {
                    guard self.isCurrent(sessionID, generation), !Task.isCancelled else { return }
                    self.lastErrorCode = "live_inference_failed"
                    self.liveStatus = "retrying"
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
    }

    private func isCurrent(_ sessionID: UUID, _ generation: UUID) -> Bool {
        self.sessionID == sessionID && workerGeneration == generation && sharingEnabled
    }
}
