import Foundation

public enum LabShell {
    public static func quote(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_./:-"))
        if value.unicodeScalars.allSatisfy({ safe.contains($0) }) {
            return value
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func safeLabel(_ value: String) -> String {
        let lowered = value.lowercased()
        let mapped = lowered.map { character -> Character in
            if character.isLetter || character.isNumber || character == "-" || character == "_" {
                return character
            }
            return "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? "run" : String(collapsed.prefix(64))
    }
}

public enum LabRepositoryLocator {
    public static func locate(
        startingAt start: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        if let explicit = environment["TRANSCRIPTED_REPO"], !explicit.isEmpty {
            let candidate = URL(fileURLWithPath: explicit).standardizedFileURL
            if isTranscriptedRepository(candidate, fileManager: fileManager) {
                return candidate
            }
        }

        var candidate = start.standardizedFileURL
        while true {
            if isTranscriptedRepository(candidate, fileManager: fileManager) {
                return candidate
            }
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path { break }
            candidate = parent
        }
        return nil
    }

    public static func isTranscriptedRepository(_ url: URL, fileManager: FileManager = .default) -> Bool {
        let guide = url.appendingPathComponent("AGENTS.md").path
        let qaBench = url.appendingPathComponent("scripts/ops/transcripted-qa-bench.sh").path
        let speakerHarness = url.appendingPathComponent("Tools/SpeakerEvalHarness/Package.swift").path
        return fileManager.fileExists(atPath: guide)
            && fileManager.fileExists(atPath: qaBench)
            && fileManager.fileExists(atPath: speakerHarness)
    }
}

public enum LabPaths {
    public static func applicationSupportRoot(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/Transcripted Lab", isDirectory: true)
    }

    public static func reportsRoot(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        applicationSupportRoot(homeDirectory: homeDirectory).appendingPathComponent("Runs", isDirectory: true)
    }

    public static func artifactsRoot(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        applicationSupportRoot(homeDirectory: homeDirectory).appendingPathComponent("Artifacts", isDirectory: true)
    }
}

public enum LabText {
    public static func tail(_ text: String, limit: Int = 40_000) -> String {
        guard text.count > limit else { return text }
        return "…\n" + String(text.suffix(limit))
    }

    public static func sanitized(
        _ text: String,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String {
        text.replacingOccurrences(of: homeDirectory.path, with: "~")
    }
}

public enum LabStatistics {
    public static func percentile(_ values: [Double], _ quantile: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let clamped = min(1, max(0, quantile))
        let index = Int((Double(sorted.count - 1) * clamped).rounded())
        return sorted[index]
    }

    public static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    public static func lowerIsBetterScore(value: Double?, target: Double) -> Int? {
        guard let value, value.isFinite, value >= 0, target > 0 else { return nil }
        if value <= target { return 100 }
        return max(0, min(100, Int((target / value * 100).rounded())))
    }

    public static func higherIsBetterScore(value: Double?, target: Double = 1) -> Int? {
        guard let value, value.isFinite, target > 0 else { return nil }
        return max(0, min(100, Int((value / target * 100).rounded())))
    }
}

extension Dictionary where Key == String, Value == Any {
    func labDouble(_ key: String) -> Double? {
        guard let value = self[key] else { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    func labString(_ key: String) -> String? {
        if let value = self[key] as? String { return value }
        if let value = self[key] as? NSNumber { return value.stringValue }
        return nil
    }
}
