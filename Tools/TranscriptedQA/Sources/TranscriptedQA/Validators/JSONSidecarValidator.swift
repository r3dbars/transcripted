import Foundation

struct JSONSidecarValidator {
    let directory: URL

    func validate() -> [ValidationResult] {
        var results: [ValidationResult] = []
        let fm = FileManager.default

        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("Call_") }) else {
            return [.fail("artifact/dir-readable", target: directory.path, detail: "Cannot read directory")]
        }

        if files.isEmpty {
            return [.warn("artifact/files-exist", target: directory.path, detail: "No JSON sidecar files found")]
        }

        for file in files {
            let name = file.lastPathComponent
            guard let data = try? Data(contentsOf: file),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                results.append(.fail("artifact/json-valid", target: name, detail: "Cannot parse as JSON"))
                continue
            }

            results.append(.pass("artifact/json-valid", target: name))

            // Version
            if let version = json["version"] as? String, version == "1.0" {
                results.append(.pass("artifact/json-version", target: name))
            } else {
                results.append(.fail("artifact/json-version", target: name, detail: "Expected version 1.0"))
            }

            // Recording block
            if let recording = json["recording"] as? [String: Any] {
                // Engines
                if let engines = recording["engines"] as? [String: String] {
                    if engines["stt"] == "parakeet-tdt-v3" {
                        results.append(.pass("artifact/json-engine-stt", target: name))
                    } else {
                        results.append(.fail("artifact/json-engine-stt", target: name, detail: "Expected parakeet-tdt-v3"))
                    }
                    if engines["diarization"] == "pyannote-offline" {
                        results.append(.pass("artifact/json-engine-diarize", target: name))
                    } else {
                        results.append(.fail("artifact/json-engine-diarize", target: name, detail: "Expected pyannote-offline"))
                    }
                }

                // Duration
                if let duration = recording["duration_seconds"] as? Int, duration >= 0 {
                    results.append(.pass("artifact/json-duration", target: name))
                } else {
                    results.append(.fail("artifact/json-duration", target: name, detail: "Missing or negative duration_seconds"))
                }
            } else {
                results.append(.fail("artifact/json-recording", target: name, detail: "Missing recording block"))
            }

            // Utterances sorted by start
            if let utterances = json["utterances"] as? [[String: Any]] {
                var sorted = true
                var prevStart: Double = -1
                for utt in utterances {
                    if let start = utt["start"] as? Double {
                        if start < prevStart { sorted = false; break }
                        prevStart = start
                    }
                }
                if sorted {
                    results.append(.pass("artifact/json-utterances-sorted", target: name))
                } else {
                    results.append(.fail("artifact/json-utterances-sorted", target: name, detail: "Utterances not sorted by start time"))
                }

                // Speaker refs valid
                let speakers = json["speakers"] as? [[String: Any]] ?? []
                let speakerIds = Set(speakers.compactMap { $0["id"] as? String })
                let uttSpeakerIds = Set(utterances.compactMap { $0["speaker_id"] as? String })
                let missing = uttSpeakerIds.subtracting(speakerIds)
                if missing.isEmpty {
                    results.append(.pass("artifact/json-speaker-refs", target: name))
                } else {
                    results.append(.fail("artifact/json-speaker-refs", target: name, detail: "Utterances reference unknown speakers: \(missing)"))
                }
            }

            // Corresponding .md exists
            let mdFile = file.deletingPathExtension().appendingPathExtension("md")
            if fm.fileExists(atPath: mdFile.path) {
                results.append(.pass("artifact/md-match", target: name))
            } else {
                results.append(.fail("artifact/md-match", target: name, detail: "No corresponding .md file"))
            }
        }

        return results
    }
}
