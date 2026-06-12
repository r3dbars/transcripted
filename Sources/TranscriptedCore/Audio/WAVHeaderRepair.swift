import Foundation

enum WAVHeaderRepairError: Error {
    case unreadableHeader
    case notRIFFWave
    case unsupportedEncoding
    case missingDataChunk
}

/// Repairs WAV files whose writer never finalized the RIFF/data chunk sizes.
///
/// AVAudioFile only patches the header size fields when the file is closed. A
/// writer that crashed — or whose deinit ran after a reader already opened the
/// file — leaves the `data` chunk declared as 0 bytes, so readers see a
/// zero-length file even though the PCM payload is intact on disk. PCM frames
/// are fixed-size and append-only, so the true sizes can always be recomputed
/// from the actual file size.
enum WAVHeaderRepair {
    /// Chunk headers always precede the payload; AVAudioFile places `data` at
    /// 4KB via JUNK/FLLR padding. Scanning further than this means the file is
    /// not a WAV this app wrote.
    private static let headerScanLimit = 1 << 20

    struct HeaderInfo {
        let fileSize: Int
        let riffDeclaredSize: UInt32
        let dataSizeFieldOffset: Int
        let dataDeclaredSize: UInt32
        /// Payload bytes actually on disk, aligned down to whole PCM frames.
        let dataActualSize: Int

        var needsRepair: Bool {
            // Only the two states a crashed/truncated writer produces. A
            // declared size that is nonzero but smaller than the remaining
            // bytes is legal — metadata chunks may follow the data chunk —
            // and "repairing" it would decode that metadata as PCM.
            if dataDeclaredSize == 0 { return dataActualSize > 0 }
            return Int(dataDeclaredSize) > dataActualSize
        }
    }

    /// Patches the RIFF and `data` size fields from the actual file size.
    /// Returns `true` when the file was modified, `false` when it was already
    /// consistent. Throws when the file is not parseable PCM RIFF/WAVE.
    @discardableResult
    static func repairIfNeeded(at url: URL) throws -> Bool {
        let info = try probe(at: url)
        guard info.needsRepair else { return false }

        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }

        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: uint32LE(UInt32(clamping: info.fileSize - 8)))
        try handle.seek(toOffset: UInt64(info.dataSizeFieldOffset))
        try handle.write(contentsOf: uint32LE(UInt32(clamping: info.dataActualSize)))
        try handle.synchronize()
        return true
    }

    static func probe(at url: URL) throws -> HeaderInfo {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let fileSize = (attributes[.size] as? NSNumber)?.intValue, fileSize >= 44 else {
            throw WAVHeaderRepairError.unreadableHeader
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: min(fileSize, headerScanLimit)),
              header.count >= 44 else {
            throw WAVHeaderRepairError.unreadableHeader
        }

        guard fourCC(header, at: 0) == "RIFF", fourCC(header, at: 8) == "WAVE" else {
            throw WAVHeaderRepairError.notRIFFWave
        }
        let riffDeclaredSize = uint32(header, at: 4)

        var formatCode = 0
        var blockAlign = 0
        var offset = 12
        while offset + 8 <= header.count {
            let chunkID = fourCC(header, at: offset)
            let declaredSize = Int(uint32(header, at: offset + 4))

            if chunkID == "fmt ", offset + 8 + 16 <= header.count {
                formatCode = Int(uint16(header, at: offset + 8))
                blockAlign = Int(uint16(header, at: offset + 8 + 12))
            }

            if chunkID == "data" {
                // Linear PCM (1), IEEE float (3), or WAVE_FORMAT_EXTENSIBLE.
                guard blockAlign > 0, [1, 3, 0xFFFE].contains(formatCode) else {
                    throw WAVHeaderRepairError.unsupportedEncoding
                }
                let dataStart = offset + 8
                guard dataStart <= fileSize else {
                    throw WAVHeaderRepairError.missingDataChunk
                }
                let payload = fileSize - dataStart
                return HeaderInfo(
                    fileSize: fileSize,
                    riffDeclaredSize: riffDeclaredSize,
                    dataSizeFieldOffset: offset + 4,
                    dataDeclaredSize: uint32(header, at: offset + 4),
                    dataActualSize: payload - payload % blockAlign
                )
            }

            offset += 8 + declaredSize + (declaredSize & 1)
        }

        throw WAVHeaderRepairError.missingDataChunk
    }

    private static func fourCC(_ data: Data, at offset: Int) -> String {
        guard offset + 4 <= data.count else { return "" }
        return String(decoding: data.subdata(in: offset..<offset + 4), as: UTF8.self)
    }

    private static func uint32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
    }

    private static func uint16(_ data: Data, at offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self) }
    }

    private static func uint32LE(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
