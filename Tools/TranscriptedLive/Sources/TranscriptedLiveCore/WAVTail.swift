import Foundation

/// Reads a WAV file that another process is still appending to.
///
/// Transcripted's meeting recorder writes Float32 PCM through AVAudioFile and only
/// patches the RIFF/data sizes on close (see `WAVHeaderRepair` in the app), so a
/// live file declares `data` as 0 bytes while the payload keeps growing. This
/// reader ignores the declared size until it is nonzero, then trusts it, and only
/// ever opens the file read-only.
public final class WAVTail {
    public struct Format: Equatable, Sendable {
        public let sampleRate: Double
        public let channels: Int
        public let bitsPerSample: Int
        public let isFloat: Bool

        public var bytesPerFrame: Int { channels * bitsPerSample / 8 }
    }

    public enum TailError: Error, Equatable {
        case notRIFFWave
        case unsupportedEncoding(tag: UInt16, bits: Int)
    }

    public let url: URL
    public private(set) var format: Format?
    private var dataOffset: UInt64?
    private var declaredDataSize: UInt32 = 0
    private var readOffset: UInt64 = 0

    /// Frames consumed so far, i.e. the audio position of the next read.
    public private(set) var framesRead: Int = 0

    public init(url: URL) {
        self.url = url
    }

    /// Seconds of audio consumed so far.
    public var secondsRead: Double {
        guard let format, format.sampleRate > 0 else { return 0 }
        return Double(framesRead) / format.sampleRate
    }

    /// Returns new mono samples appended since the last call, or `nil` when the
    /// header is not on disk yet. An empty array means no new whole frames.
    public func readNewMonoSamples(maxFrames: Int = 48_000 * 5) throws -> [Float]? {
        if format == nil {
            guard try parseHeader() else { return nil }
        }
        guard let format, let dataOffset else { return nil }

        let fileSize = try currentFileSize()
        // A finalized header caps the payload (metadata chunks may follow it).
        let dataEnd: UInt64 = declaredDataSize > 0
            ? min(fileSize, dataOffset + UInt64(declaredDataSize))
            : fileSize
        let start = dataOffset + readOffset
        guard dataEnd > start else { return [] }

        let frameBytes = UInt64(format.bytesPerFrame)
        let availableFrames = (dataEnd - start) / frameBytes
        let frames = Int(min(availableFrames, UInt64(maxFrames)))
        guard frames > 0 else { return [] }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: start)
        let byteCount = frames * format.bytesPerFrame
        guard let data = try handle.read(upToCount: byteCount), data.count == byteCount else {
            return []
        }

        readOffset += UInt64(byteCount)
        framesRead += frames
        return Self.downmix(data, format: format, frames: frames)
    }

    /// Re-reads the declared data size, e.g. after the writer closed the file.
    public func refreshDeclaredSize() {
        guard format != nil else { return }
        _ = try? parseHeader()
    }

    // MARK: - Header

    private func currentFileSize() throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Returns false while the header (through the `data` chunk header) is not
    /// fully on disk yet.
    private func parseHeader() throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 1 << 16), header.count >= 12 else {
            return false
        }
        let bytes = [UInt8](header)
        guard String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: bytes[8..<12], encoding: .ascii) == "WAVE" else {
            throw TailError.notRIFFWave
        }

        var parsedFormat: Format?
        var position = 12
        while position + 8 <= bytes.count {
            let id = String(bytes: bytes[position..<(position + 4)], encoding: .ascii) ?? ""
            let size = Self.uint32(bytes, at: position + 4)
            let body = position + 8

            if id == "fmt " {
                guard body + 16 <= bytes.count else { return false }
                var tag = Self.uint16(bytes, at: body)
                let channels = Int(Self.uint16(bytes, at: body + 2))
                let sampleRate = Double(Self.uint32(bytes, at: body + 4))
                let bits = Int(Self.uint16(bytes, at: body + 14))
                // WAVE_FORMAT_EXTENSIBLE: the real tag leads the subformat GUID.
                if tag == 0xFFFE, size >= 40, body + 26 <= bytes.count {
                    tag = Self.uint16(bytes, at: body + 24)
                }
                let isFloat = tag == 3
                guard (isFloat && bits == 32) || (tag == 1 && bits == 16), channels > 0 else {
                    throw TailError.unsupportedEncoding(tag: tag, bits: bits)
                }
                parsedFormat = Format(sampleRate: sampleRate, channels: channels, bitsPerSample: bits, isFloat: isFloat)
            } else if id == "data" {
                guard let parsedFormat else { return false }
                format = parsedFormat
                dataOffset = UInt64(body)
                declaredDataSize = size
                return true
            }

            position = body + Int(size) + Int(size & 1)
        }
        return false
    }

    // MARK: - Samples

    static func downmix(_ data: Data, format: Format, frames: Int) -> [Float] {
        var mono = [Float](repeating: 0, count: frames)
        let channels = format.channels
        let scale = 1 / Float(channels)
        data.withUnsafeBytes { raw in
            if format.isFloat {
                let samples = raw.bindMemory(to: Float.self)
                for frame in 0..<frames {
                    var sum: Float = 0
                    for channel in 0..<channels { sum += samples[frame * channels + channel] }
                    mono[frame] = sum * scale
                }
            } else {
                let samples = raw.bindMemory(to: Int16.self)
                for frame in 0..<frames {
                    var sum: Float = 0
                    for channel in 0..<channels {
                        sum += Float(Int16(littleEndian: samples[frame * channels + channel])) / 32_768
                    }
                    mono[frame] = sum * scale
                }
            }
        }
        return mono
    }

    private static func uint16(_ bytes: [UInt8], at index: Int) -> UInt16 {
        UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
    }

    private static func uint32(_ bytes: [UInt8], at index: Int) -> UInt32 {
        UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8
            | UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24
    }
}
