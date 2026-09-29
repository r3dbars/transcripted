#if canImport(TranscriptedWritingCore)
import TranscriptedWritingCore
#endif
import Foundation

/// Runs `WritingSecretScrubber` over day files that are already on disk:
/// builds before the scrubber wrote typed passwords, codes and tokens
/// straight into them, and the agent tools read those files. Each section's
/// text is scrubbed the way a new entry is (its own app, the previous
/// section as context). A section that changes gets its title and counts
/// redone from the clean text; one left with nothing but redactions is
/// removed. Everything else stays byte for byte, and a file with nothing to
/// scrub isn't rewritten. Not part of Tilde.
enum WritingDayFileRescrubber {
    struct Outcome: Equatable, Sendable {
        var filesScanned = 0
        var filesChanged = 0
        var failures = 0

        mutating func record(_ result: FileResult) {
            filesScanned += 1
            switch result {
            case .unchanged: break
            case .changed: filesChanged += 1
            case .failed: failures += 1
            }
        }
    }

    enum FileResult: Equatable, Sendable {
        case unchanged
        case changed(URL)
        case failed
    }

    /// Scrubs every `Writing_*.md` directly inside `directory`, rewriting
    /// only the ones that change.
    static func rescrubAll(in directory: URL, timeZone: TimeZone, locale: Locale) -> Outcome {
        var outcome = Outcome()
        for name in WritingDayFileStore.dayFileNames(in: directory) {
            outcome.record(rescrub(dayFile: name, in: directory, timeZone: timeZone, locale: locale))
        }
        return outcome
    }

    /// Scrubs one day file. A file that changed on disk between the read
    /// and the write is left alone and counts as a failure, so the next
    /// launch tries again.
    static func rescrub(dayFile name: String, in directory: URL, timeZone: TimeZone, locale: Locale) -> FileResult {
        do {
            guard let data = try WritingDayFileStore.contents(ofDayFile: name, in: directory) else { return .unchanged }
            guard let text = String(data: data, encoding: .utf8) else { return .failed }
            guard let scrubbed = rescrubbed(text, timeZone: timeZone, locale: locale) else { return .unchanged }
            let url = try WritingDayFileStore.replace(
                dayFile: name,
                in: directory,
                expected: data,
                with: Data(scrubbed.utf8)
            )
            return .changed(url)
        } catch {
            return .failed
        }
    }

    /// The file with its sections scrubbed, or `nil` when nothing changed.
    static func rescrubbed(_ contents: String, timeZone: TimeZone, locale: Locale) -> String? {
        let lines = contents.components(separatedBy: "\n")
        let starts = lines.indices.filter { lines[$0].hasPrefix("## ") }
        guard let firstStart = starts.first else { return nil }

        var blocks: [[String]] = [trimmingTrailingBlankLines(Array(lines[..<firstStart]))]
        var changed = false
        // The composer's context: each app's last few lines, while the
        // earlier section is within the context window.
        var recent: [String: (capturedAtMilliseconds: Int64?, lines: [String])] = [:]
        for (position, start) in starts.enumerated() {
            let end = position + 1 < starts.count ? starts[position + 1] : lines.count
            let original = trimmingTrailingBlankLines(Array(lines[start..<end]))
            guard let section = Section(original) else {
                blocks.append(original)
                continue
            }
            var context: [String] = []
            if let earlier = recent[section.bundleIdentifier],
               let earlierTime = earlier.capturedAtMilliseconds, let time = section.capturedAtMilliseconds,
               time - earlierTime <= WritingEntryComposer.contextWindowMilliseconds {
                context = earlier.lines
            }
            recent[section.bundleIdentifier] = (
                section.capturedAtMilliseconds,
                Array((context + section.text.components(separatedBy: "\n")).suffix(WritingEntryComposer.contextLineLimit))
            )
            let result = WritingSecretScrubber.scrub(
                section.text,
                appBundleIdentifier: section.bundleIdentifier,
                precedingLines: context
            )
            guard !result.kinds.isEmpty else {
                blocks.append(original)
                continue
            }
            changed = true
            let clean = result.clean.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.isOnlyRedactions || clean.count < WritingEntryComposer.minimumCharacters { continue }
            blocks.append(section.rebuilt(with: clean, timeZone: timeZone, locale: locale))
        }
        guard changed else { return nil }
        let trailing = String(contents.reversed().prefix { $0 == "\n" })
        return blocks.filter { !$0.isEmpty }.map { $0.joined(separator: "\n") }.joined(separator: "\n\n") + trailing
    }

    private static func trimmingTrailingBlankLines(_ lines: [String]) -> [String] {
        var lines = lines
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        return lines
    }

    /// One `## ` section: heading, metadata, blank line, text.
    private struct Section {
        let heading: String
        let metadata: [String]
        /// The text with the `\## ` escape undone.
        let text: String
        let bundleIdentifier: String
        let capturedAtMilliseconds: Int64?

        init?(_ lines: [String]) {
            guard let heading = lines.first,
                  let acceptedIndex = lines.firstIndex(where: { $0.hasPrefix("Accepted words:") }),
                  acceptedIndex + 1 < lines.count,
                  lines[acceptedIndex + 1].isEmpty else { return nil }
            self.heading = heading
            metadata = Array(lines[1...acceptedIndex])
            text = lines[(acceptedIndex + 2)...]
                .map { $0.hasPrefix("\\## ") ? String($0.dropFirst()) : $0 }
                .joined(separator: "\n")
            bundleIdentifier = metadata.lazy.compactMap { line -> String? in
                guard line.hasPrefix("Bundle ID: `"), line.hasSuffix("`") else { return nil }
                return String(line.dropFirst("Bundle ID: `".count).dropLast())
            }.first ?? ""
            capturedAtMilliseconds = metadata.lazy.compactMap { line -> Int64? in
                guard line.hasPrefix("Captured: ") else { return nil }
                return Self.milliseconds(fromISO8601: String(line.dropFirst("Captured: ".count)))
            }.first
        }

        /// Same heading time and metadata, with the title, `Words:` and
        /// `Characters:` redone from `clean`.
        func rebuilt(with clean: String, timeZone: TimeZone, locale: Locale) -> [String] {
            var newHeading = heading
            if let separator = heading.range(of: " - ") {
                let captured = capturedAtMilliseconds.map { Date(timeIntervalSince1970: TimeInterval($0 / 1_000)) }
                    ?? Date(timeIntervalSince1970: 0)
                let title = WritingDayFileFormatter.title(
                    for: clean,
                    capturedAt: captured,
                    timeZone: timeZone,
                    locale: locale
                ).replacingOccurrences(of: "\n", with: " ")
                newHeading = String(heading[..<separator.upperBound]) + title
            }
            let newMetadata = metadata.map { line -> String in
                if line.hasPrefix("Words: ") { return "Words: \(clean.split(whereSeparator: \.isWhitespace).count)" }
                if line.hasPrefix("Characters: ") { return "Characters: \(clean.count)" }
                return line
            }
            return [newHeading] + newMetadata + [""] + [WritingDayFileFormatter.body(clean)]
        }

        private static func milliseconds(fromISO8601 value: String) -> Int64? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: value) else { return nil }
            return Int64((date.timeIntervalSince1970 * 1_000).rounded())
        }
    }
}
