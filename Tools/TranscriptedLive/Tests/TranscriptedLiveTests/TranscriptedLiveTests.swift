import Foundation
import Testing
@testable import TranscriptedLiveCore

@Suite struct WAVTailTests {
    /// The shape AVAudioFile leaves on disk mid-recording: JUNK padding, a
    /// Float32 `fmt `, and a `data` chunk still declared as 0 bytes.
    private func liveHeader(channels: UInt16 = 1, sampleRate: UInt32 = 48_000) -> Data {
        var data = Data()
        func append(_ string: String) { data.append(contentsOf: Array(string.utf8)) }
        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        append("RIFF"); append32(0); append("WAVE")
        append("JUNK"); append32(28); data.append(Data(count: 28))
        append("fmt "); append32(16)
        append16(3); append16(channels); append32(sampleRate)
        append32(sampleRate * UInt32(channels) * 4); append16(channels * 4); append16(32)
        append("data"); append32(0)
        return data
    }

    private func floats(_ values: [Float]) -> Data {
        values.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    @Test func readsOnlyWhatWasAppendedSinceTheLastRead() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tail-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try liveHeader().write(to: url)

        let tail = WAVTail(url: url)
        #expect(try tail.readNewMonoSamples() == [])

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: floats([0.1, 0.2, 0.3]))
        #expect(try tail.readNewMonoSamples() == [0.1, 0.2, 0.3])

        // Half a frame is not read until the rest lands.
        try handle.write(contentsOf: floats([0.4]).prefix(2))
        #expect(try tail.readNewMonoSamples() == [])
        try handle.write(contentsOf: floats([0.4]).suffix(2))
        try handle.close()
        #expect(try tail.readNewMonoSamples() == [0.4])
        #expect(tail.framesRead == 4)
    }

    @Test func downmixesStereoToMono() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tail-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try (liveHeader(channels: 2) + floats([0.2, 0.4, -1, 1])).write(to: url)

        let samples = try WAVTail(url: url).readNewMonoSamples()
        #expect(samples?.count == 2)
        #expect(abs((samples?[0] ?? 0) - 0.3) < 0.0001)
        #expect(samples?[1] == 0)
    }

    @Test func waitsForAHeaderThatIsNotOnDiskYet() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tail-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try liveHeader().prefix(40).write(to: url)
        #expect(try WAVTail(url: url).readNewMonoSamples() == nil)
    }
}

@Suite struct TranscriptSinkTests {
    @Test func emitsOnlyTheTextAfterTheLastUtterance() {
        let sink = TranscriptSink()
        sink.onPartial("so the calendar")
        #expect(sink.partial == "so the calendar")
        sink.onEou("so the calendar thing works")
        #expect(sink.drainFinals() == ["so the calendar thing works"])
        sink.onPartial("so the calendar thing works could it skip")
        #expect(sink.partial == "could it skip")
        sink.onEou("so the calendar thing works could it skip review")
        #expect(sink.drainFinals() == ["could it skip review"])
    }

    @Test func aForcedSplitKeepsTheLastWordPending() {
        let sink = TranscriptSink()
        sink.onPartial("we compared both models on twelve compar")
        #expect(sink.forceFinal(keepingLastWord: true) == "we compared both models on twelve")
        sink.onPartial("we compared both models on twelve comparisons today")
        #expect(sink.partial == "comparisons today")
    }
}

@Suite struct EchoFilterTests {
    @Test func dropsTheMicCopyOfWhatTheCallJustSaid() {
        let filter = EchoFilter()
        filter.holdYou(LiveUtterance(t: 7, speaker: "you", text: "they found the bottleneck and they iterated"), micPosition: 12)
        #expect(filter.release(systemPosition: 13) == [])  // still waiting on system audio
        filter.addThem(LiveUtterance(t: 7, speaker: "them", text: "they found the bottle neck and they iterated it"))
        #expect(filter.release(systemPosition: 16) == [])
        #expect(filter.droppedCount == 1)
    }

    @Test func keepsWhatOnlyTheMicHeardAndShortReplies() {
        let filter = EchoFilter()
        filter.addThem(LiveUtterance(t: 5, speaker: "them", text: "does that sound good to you"))
        let reply = LiveUtterance(t: 8, speaker: "you", text: "sounds good")
        let own = LiveUtterance(t: 9, speaker: "you", text: "let me check the speaker review code first")
        filter.holdYou(reply, micPosition: 9)
        filter.holdYou(own, micPosition: 12)
        #expect(filter.release(systemPosition: 20) == [reply, own])
    }

    @Test func releasesImmediatelyWithoutASystemStream() {
        let filter = EchoFilter()
        let line = LiveUtterance(t: 1, speaker: "you", text: "quick note to self about the demo")
        filter.holdYou(line, micPosition: 3)
        #expect(filter.release(systemPosition: nil) == [line])
    }
}

@Suite struct LevelMeterTests {
    @Test func silenceReadsZeroAndALoudToneReadsNearFull() {
        var meter = LevelMeter(stepSeconds: 0.1, capacity: 10)
        meter.add([Float](repeating: 0, count: 1_600), sampleRate: 16_000)
        let tone = (0..<1_600).map { Float(0.9 * sin(Double($0) * 0.2)) }
        meter.add(tone, sampleRate: 16_000)
        #expect(meter.levels.count == 2)
        #expect(meter.levels[0] == 0)
        #expect(meter.levels[1] > 0.9)
    }

    @Test func oneStepPerTenthOfASecondAndOnlyTheNewestAreKept() {
        var meter = LevelMeter(stepSeconds: 0.1, capacity: 4)
        meter.add([Float](repeating: 0.1, count: 16_000), sampleRate: 16_000)
        #expect(meter.levels.count == 4)
        meter.add([Float](repeating: 0.1, count: 799), sampleRate: 16_000)
        #expect(meter.levels.count == 4)
    }

    @Test func quietSpeechSitsBelowLoudSpeech() {
        var meter = LevelMeter(stepSeconds: 0.1, capacity: 4)
        meter.add([Float](repeating: 0.01, count: 4_800), sampleRate: 48_000)
        meter.add([Float](repeating: 0.3, count: 4_800), sampleRate: 48_000)
        #expect(meter.levels[0] < meter.levels[1])
    }
}
