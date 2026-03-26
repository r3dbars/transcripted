import Foundation

struct TranscriptValidator {
    let directory: URL

    func validate() -> [ValidationResult] {
        var results: [ValidationResult] = []
        let fm = FileManager.default

        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "md" && $0.lastPathComponent.hasPrefix("Call_") }) else {
            return [.fail("transcript/dir-readable", target: directory.path, detail: "Cannot read directory")]
        }

        if files.isEmpty {
            return [.warn("transcript/files-exist", target: directory.path, detail: "No transcript files found")]
        }

        for file in files {
            let name = file.lastPathComponent
            guard let content = try? String(contentsOf: file, encoding: .utf8) else {
                results.append(.fail("transcript/readable", target: name, detail: "Cannot read file"))
                continue
            }

            let yaml = YAMLParser(content: content)

            // YAML present
            if yaml.hasFrontmatter {
                results.append(.pass("transcript/yaml-present", target: name))
            } else {
                results.append(.fail("transcript/yaml-present", target: name, detail: "No YAML frontmatter found"))
                continue
            }

            // Required keys
            let requiredKeys = ["date", "time", "duration", "transcription_engine", "diarization_engine"]
            let missingKeys = requiredKeys.filter { !yaml.hasKey($0) }
            if missingKeys.isEmpty {
                results.append(.pass("transcript/yaml-required-keys", target: name))
            } else {
                results.append(.fail("transcript/yaml-required-keys", target: name, detail: "Missing: \(missingKeys.joined(separator: ", "))"))
            }

            // Engine values
            if yaml.value(for: "transcription_engine") == "parakeet_local" {
                results.append(.pass("transcript/yaml-engine-stt", target: name))
            } else {
                results.append(.fail("transcript/yaml-engine-stt", target: name, detail: "Expected parakeet_local, got \(yaml.value(for: "transcription_engine") ?? "nil")"))
            }

            if yaml.value(for: "diarization_engine") == "pyannote_offline" {
                results.append(.pass("transcript/yaml-engine-diarize", target: name))
            } else {
                results.append(.fail("transcript/yaml-engine-diarize", target: name, detail: "Expected pyannote_offline, got \(yaml.value(for: "diarization_engine") ?? "nil")"))
            }

            // Sources
            if let sources = yaml.value(for: "sources") {
                let valid = sources.contains("mic") || sources.contains("system_audio")
                if valid {
                    results.append(.pass("transcript/yaml-sources", target: name))
                } else {
                    results.append(.fail("transcript/yaml-sources", target: name, detail: "Invalid sources: \(sources)"))
                }
            }

            // Capture quality
            if let quality = yaml.value(for: "capture_quality") {
                let validQualities = ["excellent", "good", "fair", "degraded"]
                if validQualities.contains(quality) {
                    results.append(.pass("transcript/yaml-capture-quality", target: name))
                } else {
                    results.append(.fail("transcript/yaml-capture-quality", target: name, detail: "Invalid quality: \(quality)"))
                }
            }

            // Non-negative counts
            for key in ["mic_utterances", "system_utterances", "total_word_count"] {
                if let val = yaml.value(for: key), let num = Int(val), num >= 0 {
                    results.append(.pass("transcript/yaml-count-\(key)", target: name))
                } else if yaml.hasKey(key) {
                    results.append(.fail("transcript/yaml-count-\(key)", target: name, detail: "Invalid or negative value"))
                }
            }

            // Body has content
            let bodyHasContent = yaml.body.contains("## Full Transcript") || yaml.body.contains("## Summary")
            if bodyHasContent {
                results.append(.pass("transcript/body-has-sections", target: name))
            } else {
                results.append(.fail("transcript/body-has-sections", target: name, detail: "Missing expected document sections"))
            }

            // Sidecar exists
            let jsonName = file.deletingPathExtension().appendingPathExtension("json")
            if fm.fileExists(atPath: jsonName.path) {
                results.append(.pass("transcript/sidecar-exists", target: name))
            } else {
                results.append(.fail("transcript/sidecar-exists", target: name, detail: "No .json sidecar found"))
            }

            // File permissions
            if let attrs = try? fm.attributesOfItem(atPath: file.path),
               let perms = attrs[.posixPermissions] as? Int {
                let worldReadable = perms & 0o004 != 0
                if !worldReadable {
                    results.append(.pass("transcript/permissions", target: name))
                } else {
                    results.append(.warn("transcript/permissions", target: name, detail: "File is world-readable (permissions: \(String(perms, radix: 8)))"))
                }
            }
        }

        return results
    }
}
