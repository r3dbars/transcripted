import Foundation

struct CustomDictionaryEntry: Equatable {
    let spoken: String
    let replacement: String
}

enum CustomDictionaryPreferences {
    private static let rawTextKey = "customDictionaryRawText"
    private static let maxEntries = 200
    private static let maxLineLength = 140
    static let maxRawTextLength = 12_000

    static func rawText(userDefaults: UserDefaults = .standard) -> String {
        userDefaults.string(forKey: rawTextKey) ?? ""
    }

    static func setRawText(_ rawText: String, userDefaults: UserDefaults = .standard) {
        userDefaults.set(clampedRawText(rawText), forKey: rawTextKey)
    }

    static func entries(userDefaults: UserDefaults = .standard) -> [CustomDictionaryEntry] {
        entries(from: rawText(userDefaults: userDefaults))
    }

    static func entries(from rawText: String) -> [CustomDictionaryEntry] {
        var entries: [CustomDictionaryEntry] = []
        var seenSources = Set<String>()

        for rawLine in clampedRawText(rawText).components(separatedBy: .newlines) {
            guard let entry = entry(from: rawLine) else { continue }
            let key = normalizedMatchKey(entry.spoken)
            guard !seenSources.contains(key) else { continue }

            entries.append(entry)
            seenSources.insert(key)

            if entries.count >= maxEntries {
                break
            }
        }

        return entries
    }

    static func clampedRawText(_ rawText: String) -> String {
        String(rawText.prefix(maxRawTextLength))
    }

    private static func entry(from rawLine: String) -> CustomDictionaryEntry? {
        let line = stripCommonBulletPrefix(rawLine)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !line.isEmpty else { return nil }

        let limitedLine = String(line.prefix(maxLineLength))
        let parts = splitCorrection(limitedLine)
        let spoken = normalizedTerm(parts.spoken)
        let replacement = normalizedTerm(parts.replacement)

        guard !spoken.isEmpty, !replacement.isEmpty else { return nil }
        return CustomDictionaryEntry(spoken: spoken, replacement: replacement)
    }

    private static func splitCorrection(_ line: String) -> (spoken: String, replacement: String) {
        for delimiter in ["->", "=>", "="] {
            if let range = line.range(of: delimiter) {
                return (
                    String(line[..<range.lowerBound]),
                    String(line[range.upperBound...])
                )
            }
        }

        return (line, line)
    }

    private static func stripCommonBulletPrefix(_ line: String) -> String {
        var result = line.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["- ", "* ", "• "] {
            if result.hasPrefix(prefix) {
                result.removeFirst(prefix.count)
                break
            }
        }
        return result
    }

    private static func normalizedTerm(_ term: String) -> String {
        term
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func normalizedMatchKey(_ term: String) -> String {
        normalizedTerm(term).lowercased()
    }
}

enum CustomDictionaryTextProcessor {
    private struct CompiledEntry {
        let regex: NSRegularExpression
        let template: String

        init?(entry: CustomDictionaryEntry) {
            guard let regex = try? NSRegularExpression(
                pattern: CustomDictionaryTextProcessor.pattern(for: entry.spoken),
                options: [.caseInsensitive]
            ) else {
                return nil
            }
            self.regex = regex
            self.template = NSRegularExpression.escapedTemplate(for: entry.replacement)
        }

        func apply(to text: String) -> String {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return regex.stringByReplacingMatches(
                in: text,
                options: [],
                range: range,
                withTemplate: template
            )
        }
    }

    private struct CompiledDictionary {
        let entries: [CustomDictionaryEntry]
        let compiledEntries: [CompiledEntry]
    }

    // Compiling one regex per entry on every dictation segment and meeting
    // transcript chunk is the expensive part of this processor, so the sorted +
    // compiled form is cached and reused while the dictionary is unchanged.
    // There is no change notification for the underlying preference; keying the
    // cache on the parsed entries value keeps it correct because the entries
    // change exactly when the persisted raw text does. Guarded by a lock since
    // dictation, meetings, and the Settings preview can call in concurrently.
    private static let cacheLock = NSLock()
    private static nonisolated(unsafe) var cachedDictionary: CompiledDictionary?

    static func apply(
        to text: String,
        entries: [CustomDictionaryEntry] = CustomDictionaryPreferences.entries()
    ) -> String {
        guard !text.isEmpty, !entries.isEmpty else { return text }

        return compiledEntries(for: entries).reduce(text) { currentText, compiledEntry in
            compiledEntry.apply(to: currentText)
        }
    }

    private static func compiledEntries(for entries: [CustomDictionaryEntry]) -> [CompiledEntry] {
        cacheLock.lock()
        defer { cacheLock.unlock() }

        if let cached = cachedDictionary, cached.entries == entries {
            return cached.compiledEntries
        }

        let compiledEntries = entries
            .sorted { lhs, rhs in
                lhs.spoken.count == rhs.spoken.count
                    ? lhs.spoken.localizedCaseInsensitiveCompare(rhs.spoken) == .orderedAscending
                    : lhs.spoken.count > rhs.spoken.count
            }
            .compactMap(CompiledEntry.init(entry:))

        cachedDictionary = CompiledDictionary(entries: entries, compiledEntries: compiledEntries)
        return compiledEntries
    }

    private static func pattern(for spoken: String) -> String {
        let corePattern = spoken
            .split(whereSeparator: \.isWhitespace)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: #"\s+"#)

        let leadingBoundary = needsLeadingBoundary(spoken) ? #"(?<![\p{L}\p{N}_])"# : ""
        let trailingBoundary = needsTrailingBoundary(spoken) ? #"(?![\p{L}\p{N}_])"# : ""
        return leadingBoundary + corePattern + trailingBoundary
    }

    private static func needsLeadingBoundary(_ term: String) -> Bool {
        guard let scalar = term.unicodeScalars.first else { return false }
        return isWordScalar(scalar)
    }

    private static func needsTrailingBoundary(_ term: String) -> Bool {
        guard let scalar = term.unicodeScalars.last else { return false }
        return isWordScalar(scalar)
    }

    private static func isWordScalar(_ scalar: UnicodeScalar) -> Bool {
        scalar == "_" || CharacterSet.alphanumerics.contains(scalar)
    }
}
