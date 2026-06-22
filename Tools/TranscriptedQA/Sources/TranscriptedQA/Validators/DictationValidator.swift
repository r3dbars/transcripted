import Foundation

struct DictationValidator {
    let directory: URL

    func validate() -> [ValidationResult] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return [.warn("dictation/dir-readable", target: directory.path, detail: "Dictations directory does not exist")]
        }

        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "md" && isDictationDayFilename($0.lastPathComponent) })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) else {
            return [.fail("dictation/dir-readable", target: directory.path, detail: "Cannot read directory")]
        }

        if files.isEmpty {
            return [.warn("dictation/files-exist", target: directory.path, detail: "No dictation markdown files found")]
        }

        var results: [ValidationResult] = [
            .pass("dictation/files-exist", target: directory.lastPathComponent)
        ]

        for file in files {
            let name = file.lastPathComponent
            guard let content = try? String(contentsOf: file, encoding: .utf8) else {
                results.append(.fail("dictation/readable", target: name, detail: "Cannot read file"))
                continue
            }

            let yaml = YAMLParser(content: content)
            if yaml.hasFrontmatter {
                results.append(.pass("dictation/yaml-present", target: name))
            } else {
                results.append(.fail("dictation/yaml-present", target: name, detail: "No YAML frontmatter found"))
                continue
            }

            if yaml.value(for: "capture_type") == "dictation_day" {
                results.append(.pass("dictation/capture-type", target: name))
            } else {
                results.append(.fail("dictation/capture-type", target: name, detail: "Expected capture_type dictation_day"))
            }

            if yaml.hasKey("date") {
                results.append(.pass("dictation/date-present", target: name))
            } else {
                results.append(.fail("dictation/date-present", target: name, detail: "Missing date frontmatter"))
            }

            if yaml.body.contains("Entry ID:") {
                results.append(.pass("dictation/entry-ids", target: name))
            } else {
                results.append(.warn("dictation/entry-ids", target: name, detail: "No dictation entry IDs found"))
            }

            if yaml.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                results.append(.fail("dictation/body-nonempty", target: name, detail: "No dictation body content"))
            } else {
                results.append(.pass("dictation/body-nonempty", target: name))
            }
        }

        return results
    }

    private func isDictationDayFilename(_ filename: String) -> Bool {
        filename.hasPrefix("Dictations_") && filename.hasSuffix(".md")
    }
}
