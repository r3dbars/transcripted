import Foundation

/// Bounded byte-level preflight shared by single-identity and batched alias scans.
/// Ambiguous input requires the caller's full read; only a closed header can rule
/// out all candidates. No text decoding or transcript-body scan is performed.
enum TranscriptFrontmatterScanner {
    enum Result {
        case matched
        case notMatched
        case needsFullRead
    }

    static func scan(at url: URL, for needles: [String]) -> Result {
        guard !needles.isEmpty else { return .notMatched }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .needsFullRead }
        defer { try? handle.close() }

        let needleBytes = needles.map { Data($0.utf8) }
        let openDelimiter = Data("---\n".utf8)
        let closeDelimiter = Data("\n---\n".utf8)
        let chunkSize = 64 * 1024
        let maxScanBytes = 1024 * 1024
        var buffer = Data()

        while buffer.count < maxScanBytes {
            guard let chunk = autoreleasepool(invoking: { try? handle.read(upToCount: chunkSize) }),
                  !chunk.isEmpty else {
                return .needsFullRead
            }
            buffer.append(chunk)

            if buffer.count >= openDelimiter.count, !buffer.starts(with: openDelimiter) {
                return .needsFullRead
            }

            // Mirrors frontmatterContentRange: the frontmatter ends at the first
            // "\n---\n" after the opening "---\n".
            if buffer.count > openDelimiter.count,
               let closeRange = buffer.range(of: closeDelimiter, in: openDelimiter.count..<buffer.count) {
                return needleBytes.contains { buffer[..<closeRange.lowerBound].range(of: $0) != nil }
                    ? .matched
                    : .notMatched
            }
        }
        return .needsFullRead
    }
}
