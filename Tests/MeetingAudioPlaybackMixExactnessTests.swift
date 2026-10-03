import AVFoundation
import Foundation

// Promises: the playback mix is exactly min(0.98, max(-0.98, system * 0.95 + mic * 0.90))
// per sample (no gating, no fused multiply-add, zero past a track's end, mono mic on
// every channel); non-finite input never reaches playback; and the owner-only
// permission tightening behaves the same for files, symlinks and dangling symlinks.
func testMeetingAudioPlaybackMixExactness() async {
    for layout in [(micChannels: 1, micFrames: 12_289, systemFrames: 9_001),
                   (micChannels: 2, micFrames: 9_001, systemFrames: 12_289)] {
        await runSuite("MeetingAudioPlaybackMixer output equals the gain-and-clamp formula (\(layout.micChannels)ch mic)") {
            let directory = makeMixExactnessDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            var seed: UInt64 = 0x9E37_79B9_7F4A_7C15 &+ UInt64(layout.micChannels)
            let microphone = (0..<layout.micChannels).map { _ in mixExactnessNoise(count: layout.micFrames, seed: &seed) }
            let system = (0..<2).map { _ in mixExactnessNoise(count: layout.systemFrames, seed: &seed) }
            let micURL = directory.appendingPathComponent("microphone.wav")
            let systemURL = directory.appendingPathComponent("system_audio.wav")
            let playbackURL = directory.appendingPathComponent("playback.wav")
            do {
                try writeMixExactnessWAV(channels: microphone, to: micURL)
                try writeMixExactnessWAV(channels: system, to: systemURL)
                try await AVFoundationMeetingAudioPlaybackMixer().createPlaybackWAV(
                    microphoneURL: micURL, systemURL: systemURL, destinationURL: playbackURL, fileManager: .default)
                let output = try readMixExactnessWAV(from: playbackURL)
                let frames = max(layout.micFrames, layout.systemFrames)
                assertEqual(output.count, 2, "playback keeps two channels")
                var mismatches = 0
                for channel in 0..<output.count {
                    assertEqual(output[channel].count, frames, "playback spans the longer track")
                    let mic = microphone[min(channel, microphone.count - 1)]
                    for frame in 0..<min(frames, output[channel].count) {
                        let s: Float = frame < system[channel].count ? system[channel][frame] : 0
                        let m: Float = frame < mic.count ? mic[frame] : 0
                        let expected = min(0.98, max(-0.98, (s * 0.95) + (m * 0.90)))
                        if output[channel][frame].bitPattern != expected.bitPattern { mismatches += 1 }
                    }
                }
                assertEqual(mismatches, 0, "every sample matches the gain-and-clamp formula bit for bit")
            } catch {
                assertTrue(false, "mix fixture failed: \(error)")
            }
        }
    }

    await runSuite("MeetingAudioPlaybackMixer never passes non-finite input to playback") {
        let directory = makeMixExactnessDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var seed: UInt64 = 0xDEAD_BEEF
        var microphone = mixExactnessNoise(count: 9_000, seed: &seed)
        var system = mixExactnessNoise(count: 9_000, seed: &seed)
        let specials: [Float] = [.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude]
        for (index, value) in specials.enumerated() {
            microphone[index * 1_501] = value
            system[index * 1_777 + 3] = value
            system[index * 1_501] = specials[(index + 2) % specials.count]
        }
        let micURL = directory.appendingPathComponent("microphone.wav")
        let systemURL = directory.appendingPathComponent("system_audio.wav")
        let playbackURL = directory.appendingPathComponent("playback.wav")
        do {
            try writeMixExactnessWAV(channels: [microphone], to: micURL)
            try writeMixExactnessWAV(channels: [system], to: systemURL)
            try await AVFoundationMeetingAudioPlaybackMixer().createPlaybackWAV(
                microphoneURL: micURL, systemURL: systemURL, destinationURL: playbackURL, fileManager: .default)
            let output = try readMixExactnessWAV(from: playbackURL)
            assertEqual(output.first?.count ?? 0, 9_000, "playback keeps every frame")
            let bad = output.flatMap { $0 }.filter { !$0.isFinite || abs($0) > 0.98 }.count
            assertEqual(bad, 0, "every playback sample is finite and within the limiter")
        } catch {
            assertTrue(false, "non-finite fixture failed: \(error)")
        }
    }

    runSuite("FileManager.restrictFileToOwnerOnly handles extra mode bits, symlinks and dangling symlinks") {
        let directory = makeMixExactnessDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileManager = FileManager.default
        let target = directory.appendingPathComponent("target.m4a")
        let setuid = directory.appendingPathComponent("setuid.m4a")
        let link = directory.appendingPathComponent("link.m4a")
        let dangling = directory.appendingPathComponent("dangling.m4a")
        fileManager.createFile(atPath: target.path, contents: Data([1, 2, 3]))
        fileManager.createFile(atPath: setuid.path, contents: Data([4]))
        chmod(target.path, 0o644)
        chmod(setuid.path, 0o4600)
        try? fileManager.createSymbolicLink(at: link, withDestinationURL: target)
        try? fileManager.createSymbolicLink(at: dangling, withDestinationURL: directory.appendingPathComponent("missing.m4a"))

        fileManager.restrictFileToOwnerOnly(at: setuid)
        assertEqual(mixExactnessMode(setuid.path), 0o600, "special bits are cleared to plain 0600")
        fileManager.restrictFileToOwnerOnly(at: link)
        assertEqual(mixExactnessMode(target.path), 0o600, "a symlinked file's target is tightened")
        fileManager.restrictFileToOwnerOnly(at: target)
        assertEqual(mixExactnessMode(target.path), 0o600, "an already-private file stays 0600")
        fileManager.restrictFileToOwnerOnly(at: dangling)
        assertTrue(!fileManager.fileExists(atPath: directory.appendingPathComponent("missing.m4a").path),
            "a dangling symlink creates nothing")
        fileManager.restrictFileToOwnerOnly(at: directory.appendingPathComponent("absent.m4a"))
        assertTrue(!fileManager.fileExists(atPath: directory.appendingPathComponent("absent.m4a").path),
            "a missing path creates nothing")
    }
}

private func makeMixExactnessDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("MeetingAudioPlaybackMixExactnessTests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func mixExactnessMode(_ path: String) -> Int {
    var status = stat()
    return lstat(path, &status) == 0 ? Int(status.st_mode & 0o7777) : -1
}

/// Deterministic xorshift noise in +/-1.3 so both limiter polarities are hit.
private func mixExactnessNoise(count: Int, seed: inout UInt64) -> [Float] {
    (0..<count).map { _ in
        seed ^= seed << 13
        seed ^= seed >> 7
        seed ^= seed << 17
        return (Float(seed >> 40) / Float(1 << 24) * 2 - 1) * 1.3
    }
}

private func writeMixExactnessWAV(channels: [[Float]], to url: URL) throws {
    let frameCount = channels[0].count
    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                     channels: AVAudioChannelCount(channels.count), interleaved: false),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)),
          let destination = buffer.floatChannelData else {
        throw MeetingAudioStorageError.mixBufferAllocationFailed
    }
    buffer.frameLength = AVAudioFrameCount(frameCount)
    for (channel, samples) in channels.enumerated() {
        for (frame, sample) in samples.enumerated() { destination[channel][frame] = sample }
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings,
                               commonFormat: format.commonFormat, interleaved: format.isInterleaved)
    try file.write(from: buffer)
}

private func readMixExactnessWAV(from url: URL) throws -> [[Float]] {
    let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                        frameCapacity: AVAudioFrameCount(file.length)) else {
        throw MeetingAudioStorageError.mixBufferAllocationFailed
    }
    try file.read(into: buffer)
    guard let data = buffer.floatChannelData else { return [] }
    return (0..<Int(buffer.format.channelCount)).map {
        Array(UnsafeBufferPointer(start: data[$0], count: Int(buffer.frameLength)))
    }
}
