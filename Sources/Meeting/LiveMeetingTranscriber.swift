@preconcurrency import AVFoundation
import FluidAudio
import Foundation

@available(macOS 14.0, *)
@MainActor
final class LiveMeetingTranscriber {
    private var streamingSession: SlidingWindowAsrSession?
    private var channels: [LiveMeetingCodexSource: LiveMeetingTranscriberChannel] = [:]

    var isRunning: Bool {
        !channels.isEmpty
    }

    func start(
        capture: MeetingCaptureBridge,
        codexSession: LiveMeetingCodexSession,
        feed: LiveMeetingTranscriptFeed? = nil,
        startedAt: Date = Date()
    ) {
        stop(capture: capture)

        let session = SlidingWindowAsrSession()
        streamingSession = session

        let microphoneChannel = LiveMeetingTranscriberChannel(
            source: .microphone,
            audioSource: .microphone,
            streamingSession: session,
            codexSession: codexSession,
            feed: feed,
            startedAt: startedAt
        )
        let systemChannel = LiveMeetingTranscriberChannel(
            source: .system,
            audioSource: .system,
            streamingSession: session,
            codexSession: codexSession,
            feed: feed,
            startedAt: startedAt
        )

        channels = [
            .microphone: microphoneChannel,
            .system: systemChannel,
        ]

        capture.setMicLivePreviewHandler { [weak microphoneChannel] buffer in
            microphoneChannel?.enqueueCopy(of: buffer)
        }
        capture.setSystemLivePreviewHandler { [weak systemChannel] buffer in
            systemChannel?.enqueueCopy(of: buffer)
        }

        microphoneChannel.start()
        systemChannel.start()
    }

    func stop(capture: MeetingCaptureBridge, clearPreviewHandlers: Bool = true) {
        if clearPreviewHandlers {
            clearCapturePreviewHandlers(capture: capture)
        }

        channels.values.forEach { $0.cancel() }
        channels.removeAll()

        if let streamingSession {
            Task.detached(priority: .utility) {
                await streamingSession.cleanup()
            }
        }
        streamingSession = nil
    }

    func clearCapturePreviewHandlers(capture: MeetingCaptureBridge) {
        capture.setMicLivePreviewHandler(nil)
        capture.setSystemLivePreviewHandler(nil)
    }
}

@available(macOS 14.0, *)
private final class LiveMeetingTranscriberChannel: @unchecked Sendable {
    private let source: LiveMeetingCodexSource
    private let audioSource: AudioSource
    private let streamingSession: SlidingWindowAsrSession
    private let codexSession: LiveMeetingCodexSession
    private let feed: LiveMeetingTranscriptFeed?
    private let startedAt: Date
    private let inputQueue: DispatchQueue
    private let lock = NSLock()

    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var inputTask: Task<Void, Never>?
    private var updateState = LiveMeetingStreamingUpdateState()
    private var lastFeedText = ""
    private var lastFeedWasFinal = false

    init(
        source: LiveMeetingCodexSource,
        audioSource: AudioSource,
        streamingSession: SlidingWindowAsrSession,
        codexSession: LiveMeetingCodexSession,
        feed: LiveMeetingTranscriptFeed?,
        startedAt: Date
    ) {
        self.source = source
        self.audioSource = audioSource
        self.streamingSession = streamingSession
        self.codexSession = codexSession
        self.feed = feed
        self.startedAt = startedAt
        self.inputQueue = DispatchQueue(
            label: "com.transcripted.live-meeting-transcriber.\(source.rawValue)",
            qos: .utility
        )
    }

    func start() {
        let (stream, continuation) = AsyncStream<AVAudioPCMBuffer>.makeStream(
            bufferingPolicy: .bufferingNewest(24)
        )
        lock.withLock {
            self.continuation = continuation
        }

        inputTask = Task.detached(priority: .utility) { [weak self] in
            await self?.run(stream: stream)
        }
    }

    func enqueueCopy(of buffer: AVAudioPCMBuffer) {
        guard let copy = Self.copyPCMBuffer(buffer) else { return }
        inputQueue.async { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.continuation }?.yield(copy)
        }
    }

    func cancel() {
        let continuation = lock.withLock { () -> AsyncStream<AVAudioPCMBuffer>.Continuation? in
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.finish()
        inputTask?.cancel()
        inputTask = nil
    }

    private func run(stream: AsyncStream<AVAudioPCMBuffer>) async {
        do {
            try Task.checkCancellation()
            try codexSession.updateStreamingBackendStatus("local_streaming_asr_initializing")

            let manager = try await streamingSession.createStream(
                source: audioSource,
                config: .streaming
            )
            try Task.checkCancellation()
            try codexSession.updateStreamingBackendStatus("local_streaming_asr_running")
            if let feed {
                await MainActor.run { feed.markLive() }
            }

            let updates = await manager.transcriptionUpdates
            let updateTask = Task.detached(priority: .utility) { [weak self] in
                await self?.consume(updates: updates)
            }

            for await buffer in stream {
                try Task.checkCancellation()
                await manager.streamAudio(buffer)
            }

            updateTask.cancel()
            await manager.cancel()
            await streamingSession.removeStream(for: audioSource)
        } catch is CancellationError {
            return
        } catch {
            try? codexSession.updateStreamingBackendStatus(
                "local_streaming_asr_failed",
                note: "\(source.displayName) live streaming stopped: \(error.localizedDescription)"
            )
            if let feed {
                let note = "\(source.displayName) live transcription stopped. The final transcript still saves normally."
                await MainActor.run { feed.markFailed(note: note) }
            }
        }
    }

    private func consume(updates: AsyncStream<SlidingWindowTranscriptionUpdate>) async {
        for await update in updates {
            append(update: update)
        }
    }

    private func append(update: SlidingWindowTranscriptionUpdate) {
        let now = Date()
        let normalized = LiveMeetingStreamingUpdatePolicy.normalizedText(update.text)
        guard !normalized.isEmpty else { return }
        let elapsed = now.timeIntervalSince(startedAt)
        let entry = LiveMeetingCodexTranscriptEntry(
            source: source,
            text: normalized,
            timestampSeconds: elapsed,
            createdAt: now,
            isFinal: update.isConfirmed
        )

        // In-app drawer lane: unthrottled. Partials replace themselves in
        // memory, so every distinct hypothesis can flow word-by-word; only
        // exact repeats are dropped.
        if let feed {
            let isDistinct = lock.withLock {
                guard normalized != lastFeedText || update.isConfirmed != lastFeedWasFinal else {
                    return false
                }
                lastFeedText = normalized
                lastFeedWasFinal = update.isConfirmed
                return true
            }
            if isDistinct {
                Task { @MainActor in feed.ingest(entry) }
            }
        }

        // Sidecar file lane: keep the append throttle so provisional updates
        // do not hammer live_transcript.md on disk.
        let shouldAppend = lock.withLock {
            LiveMeetingStreamingUpdatePolicy.shouldAppend(
                text: normalized,
                isFinal: update.isConfirmed,
                now: now,
                state: updateState
            )
        }
        guard shouldAppend else { return }

        lock.withLock {
            updateState.lastText = normalized
            updateState.lastAppendedAt = now
            updateState.lastAppendedWasFinal = update.isConfirmed
        }

        try? codexSession.append(entry)
    }

    private static func copyPCMBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let frameLength = buffer.frameLength
        guard frameLength > 0,
              let copy = AVAudioPCMBuffer(
                pcmFormat: buffer.format,
                frameCapacity: frameLength
              ) else {
            return nil
        }

        copy.frameLength = frameLength

        let sourceBuffers = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: buffer.audioBufferList)
        )
        let destinationBuffers = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard sourceBuffers.count == destinationBuffers.count else { return nil }

        for index in sourceBuffers.indices {
            let source = sourceBuffers[index]
            guard let sourceData = source.mData,
                  let destinationData = destinationBuffers[index].mData else {
                return nil
            }
            let byteCount = Int(source.mDataByteSize)
            destinationBuffers[index].mDataByteSize = source.mDataByteSize
            memcpy(destinationData, sourceData, byteCount)
        }

        return copy
    }
}
