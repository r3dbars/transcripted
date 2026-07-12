import Foundation

/// Shared truncate-in-place rotation for growing plain-text/JSONL log files.
///
/// This is the "keep only the most recent N lines" strategy: read the whole
/// file, drop everything but the newest `keepLines`, and atomically rewrite
/// it under the same path (no renamed generation, unlike
/// `ObservabilityLogRotation`'s rename-to-`.1` strategy). Both `FileLogger`
/// (line-count gated, checked periodically during writes) and the app-log
/// sink (byte-size gated, checked once at session start) used to hand-roll
/// this same read/filter/suffix/rewrite/re-chmod sequence independently;
/// this type is the single implementation both now call.
///
/// Callers own the "should I trim" decision — pass `maxLines` when the
/// caller wants that decision made here (by line count, matching
/// `FileLogger`'s original behavior), or leave it `nil` when the caller has
/// already gated on a different signal (e.g. byte size) and just wants the
/// unconditional tail-rewrite performed.
public enum LogTailTrimmer {
    /// Rewrites the file at `path` to keep only its most recent `keepLines`
    /// lines, if trimming is needed.
    ///
    /// - Parameters:
    ///   - path: Path to the log file. No-op if the file cannot be read.
    ///   - maxLines: If non-nil, trimming only happens once the (optionally
    ///     filtered) line count exceeds this value — matching a periodic,
    ///     count-gated caller. If nil, the rewrite always happens, for
    ///     callers that already decided trimming is needed via their own
    ///     threshold (e.g. file size) before calling.
    ///   - keepLines: Number of trailing lines to retain.
    ///   - filterEmptyLines: Whether to drop empty lines before counting/
    ///     keeping (matches `FileLogger`'s behavior; the app-log sink does
    ///     not filter).
    ///   - appendsTrailingNewline: Whether the rewritten content ends with a
    ///     trailing newline (matches `FileLogger`'s JSONL format; the
    ///     app-log sink's plain-text format does not add one).
    /// - Returns: `true` if the file was rewritten.
    @discardableResult
    public static func trimIfNeeded(
        at path: String,
        maxLines: Int?,
        keepLines: Int,
        filterEmptyLines: Bool,
        appendsTrailingNewline: Bool
    ) -> Bool {
        guard let data = FileManager.default.contents(atPath: path),
              let content = String(data: data, encoding: .utf8) else {
            return false
        }

        var lines = content.components(separatedBy: "\n")
        if filterEmptyLines {
            lines = lines.filter { !$0.isEmpty }
        }

        if let maxLines, lines.count <= maxLines {
            return false
        }

        let kept = Array(lines.suffix(keepLines))
        let newContent = appendsTrailingNewline
            ? kept.joined(separator: "\n") + "\n"
            : kept.joined(separator: "\n")

        do {
            try newContent.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            fputs("⚠️ LOGGER | log tail trim write failed: \(error.localizedDescription)\n", stderr)
            return false
        }

        // Security: atomic rewrite creates a replacement inode that may inherit
        // default permissions (for example 0644). Re-tighten after every trim
        // so sensitive logs never drift from owner-only access.
        FileManager.default.restrictToOwnerOnly(atPath: path)

        return true
    }
}
