@preconcurrency import AVFoundation
import FluidAudio
import Foundation

@available(macOS 14.0, *)
@MainActor
final class LiveMeetingTranscriber {
    private var streamingSession: StreamingAsrSession?
    private var channels: [LiveMeetingCodexSource: LiveMeetingTranscriberChannel] = [:]

    var isRunning: Bool {
        !channels.isEmpty
    }

    func start(
        capture: MeetingCaptureBridge,
        codexSession: LiveMeetingCodexSession,
        startedAt: Date = Date()
    ) {
        stop(capture: capture)

        let session = StreamingAsrSession()
        streamingSession = session

        let microphoneChannel = LiveMeetingTranscriberChannel(
            source: .microphone,
            audioSource: .microphone,
            streamingSession: session,
            codexSession: codexSession,
            startedAt: startedAt
        )
        let systemChannel = LiveMeetingTranscriberChannel(
            source: .system,
            audioSource: .system,
            streamingSession: session,
            codexSession: codexSession,
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

    func stop(capture: MeetingCaptureBridge) {
        capture.setMicLivePreviewHandler(nil)
        capture.setSystemLivePreviewHandler(nil)

        channels.values.forEach { $0.cancel() }
        channels.removeAll()

        if let streamingSession {
            Task.detached(priority: .utility) {
                await streamingSession.cleanup()
            }
        }
        streamingSession = nil
    }
}

@available(macOS 14.0, *)
private final class LiveMeetingTranscriberChannel: @unchecked Sendable {
    private let source: LiveMeetingCodexSource
    private let audioSource: AudioSource
    private let streamingSession: StreamingAsrSession
    private let codexSession: LiveMeetingCodexSession
    private let startedAt: Date
    private let inputQueue: DispatchQueue
    private let lock = NSLock()

    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private var inputTask: Task<Void, Never>?
    private var updateState = LiveMeetingStreamingUpdateState()

    init(
        source: LiveMeetingCodexSource,
        audioSource: AudioSource,
        streamingSession: StreamingAsrSession,
        codexSession: LiveMeetingCodexSession,
        startedAt: Date
    ) {
        self.source = source
        self.audioSource = audioSource
        self.streamingSession = streamingSession
        self.codexSession = codexSession
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
        }
    }

    private func consume(updates: AsyncStream<StreamingTranscriptionUpdate>) async {
        for await update in updates {
            append(update: update)
        }
    }

    private func append(update: StreamingTranscriptionUpdate) {
        let now = Date()
        let normalized = LiveMeetingStreamingUpdatePolicy.normalizedText(update.text)
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
        }

        let elapsed = now.timeIntervalSince(startedAt)
        try? codexSession.append(
            LiveMeetingCodexTranscriptEntry(
                source: source,
                text: normalized,
                timestampSeconds: elapsed,
                createdAt: now,
                isFinal: update.isConfirmed
            )
        )
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
