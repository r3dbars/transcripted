import Foundation
import TranscriptedCaptureKit

/// Writing day files (`<capture-library>/writing/Writing_<date>.md`), checked
/// against the phase 3 format contract. Writing is opt-in, so a missing folder
/// or a folder with no writing files produces no results rather than a warning.
///
/// Details carry counts and field names only, never the writing itself.
struct WritingValidator {
    let directory: URL

    /// `writing-<yyyyMMdd>-<HHmmss>-<SSS>-<8 hex>`.
    private static let entryIdPattern = try? NSRegularExpression(
        pattern: #"^writing-[0-9]{8}-[0-9]{6}-[0-9]{3}-[0-9a-f]{8}$"#
    )

    func validate() -> [ValidationResult] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return []
        }

        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return [.fail("writing/dir-readable", target: directory.path, detail: "Cannot read directory")]
        }

        // In the flat shared-folder layout the writing folder also holds
        // meetings and dictations; only writing day files are checked here.
        let files = contents
            .filter { $0.pathExtension == "md" && CaptureMarkdown.captureKind(of: $0) == .writingDay }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !files.isEmpty else { return [] }

        var results: [ValidationResult] = [privacyResult("writing/dir-private", url: directory, target: directory.lastPathComponent, expected: "0700")]
        for file in files {
            results += validate(file: file)
        }
        return results
    }

    private func validate(file: URL) -> [ValidationResult] {
        let name = file.lastPathComponent
        guard let content = CaptureMarkdown.readBoundedContents(of: file) else {
            return [.fail("writing/readable", target: name, detail: "Cannot read file")]
        }

        var results: [ValidationResult] = [privacyResult("writing/file-private", url: file, target: name, expected: "0600")]

        let yaml = YAMLParser(content: content)
        guard yaml.hasFrontmatter else {
            results.append(.fail("writing/yaml-present", target: name, detail: "No YAML frontmatter found"))
            return results
        }
        results.append(.pass("writing/yaml-present", target: name))

        if yaml.value(for: "capture_type") == "writing_day" {
            results.append(.pass("writing/capture-type", target: name))
        } else {
            results.append(.fail("writing/capture-type", target: name, detail: "Expected capture_type writing_day"))
        }

        if let date = yaml.value(for: "date") {
            results.append(.pass("writing/date-present", target: name))
            let stem = file.deletingPathExtension().lastPathComponent
            if stem.hasPrefix(CaptureMarkdown.writingDayFilenamePrefix),
               stem.dropFirst(CaptureMarkdown.writingDayFilenamePrefix.count) != Substring(date) {
                results.append(.warn("writing/filename-date", target: name, detail: "Filename date differs from frontmatter date"))
            }
        } else {
            results.append(.fail("writing/date-present", target: name, detail: "Missing date frontmatter"))
        }

        switch yaml.value(for: "format_version").map({ Int($0) }) {
        case .none:
            results.append(.warn("writing/format-version", target: name, detail: "Missing format_version (read as version 1)"))
        case .some(.none):
            results.append(.fail("writing/format-version", target: name, detail: "format_version is not an integer"))
        case .some(.some(let version)) where version < 1:
            results.append(.fail("writing/format-version", target: name, detail: "format_version must be 1 or higher"))
        case .some(.some(let version)) where version > 1:
            results.append(.warn("writing/format-version", target: name, detail: "format_version \(version) is newer than this validator"))
        case .some(.some):
            results.append(.pass("writing/format-version", target: name))
        }

        guard let parsed = CaptureMarkdownParser.parseWritingDay(from: content, markdownURL: file) else {
            results.append(.fail("writing/entries-parse", target: name, detail: "Writing day did not parse"))
            return results
        }
        guard !parsed.entries.isEmpty else {
            results.append(.warn("writing/entries-present", target: name, detail: "No writing entries found"))
            return results
        }
        results.append(.pass("writing/entries-present", target: name))

        results.append(entryCheck("writing/entry-ids", name: name, entries: parsed.entries, what: "without a contract-shaped Entry ID") { entry in
            Self.matchesEntryId(entry.id)
        })
        results.append(entryCheck("writing/captured-timestamps", name: name, entries: parsed.entries, what: "without an ISO 8601 UTC Captured time with milliseconds") { entry in
            Self.isContractTimestamp(entry.createdAt)
        })
        results.append(entryCheck("writing/entry-text", name: name, entries: parsed.entries, what: "under 2 characters of text") { entry in
            entry.text.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
        })

        let overAccepted = parsed.entries.filter { $0.acceptedWordCount > $0.wordCount }.count
        if overAccepted == 0 {
            results.append(.pass("writing/accepted-words", target: name))
        } else {
            results.append(.warn("writing/accepted-words", target: name, detail: "\(overAccepted) entr\(overAccepted == 1 ? "y has" : "ies have") more accepted words than words"))
        }

        return results
    }

    private func entryCheck(
        _ check: String,
        name: String,
        entries: [ParsedWritingDayCapture.Entry],
        what: String,
        isValid: (ParsedWritingDayCapture.Entry) -> Bool
    ) -> ValidationResult {
        let failing = entries.filter { !isValid($0) }.count
        guard failing > 0 else { return .pass(check, target: name) }
        return .fail(check, target: name, detail: "\(failing) of \(entries.count) entries \(what)")
    }

    /// Writing is the most personal thing in the library; the contract says
    /// files are 0600 and the folder 0700. Anything readable by group or
    /// others is flagged.
    private func privacyResult(_ check: String, url: URL, target: String, expected: String) -> ValidationResult {
        guard let permissions = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber else {
            return .warn(check, target: target, detail: "Cannot read permissions")
        }
        let mode = permissions.intValue & 0o777
        guard mode & 0o077 == 0 else {
            return .warn(check, target: target, detail: "Mode \(String(mode, radix: 8)) is readable beyond the owner; expected \(expected)")
        }
        return .pass(check, target: target)
    }

    private static func matchesEntryId(_ id: String) -> Bool {
        guard let entryIdPattern else { return false }
        let range = NSRange(id.startIndex..<id.endIndex, in: id)
        return entryIdPattern.firstMatch(in: id, range: range) != nil
    }

    private static func isContractTimestamp(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return value.hasSuffix("Z") && formatter.date(from: value) != nil
    }
}
