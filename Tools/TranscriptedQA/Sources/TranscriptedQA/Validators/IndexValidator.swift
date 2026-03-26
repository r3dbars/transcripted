import Foundation

struct IndexValidator {
    let directory: URL

    func validate() -> [ValidationResult] {
        var results: [ValidationResult] = []
        let indexPath = directory.appendingPathComponent("transcripted.json")
        let target = "transcripted.json"

        guard FileManager.default.fileExists(atPath: indexPath.path) else {
            return [.warn("index/file-exists", target: target, detail: "transcripted.json not found")]
        }

        guard let data = try? Data(contentsOf: indexPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [.fail("index/json-valid", target: target, detail: "Cannot parse as JSON")]
        }

        results.append(.pass("index/json-valid", target: target))

        // Count match
        if let count = json["transcript_count"] as? Int,
           let transcripts = json["transcripts"] as? [[String: Any]] {
            if count == transcripts.count {
                results.append(.pass("index/count-match", target: target))
            } else {
                results.append(.fail("index/count-match", target: target, detail: "transcript_count=\(count) but array has \(transcripts.count) entries"))
            }

            // Files exist on disk
            var allExist = true
            for transcript in transcripts {
                if let filename = transcript["filename"] as? String {
                    let jsonFile = directory.appendingPathComponent("\(filename).json")
                    if !FileManager.default.fileExists(atPath: jsonFile.path) {
                        results.append(.fail("index/file-on-disk", target: target, detail: "\(filename).json not found on disk"))
                        allExist = false
                    }
                }
            }
            if allExist {
                results.append(.pass("index/files-exist", target: target))
            }
        } else {
            results.append(.fail("index/structure", target: target, detail: "Missing transcript_count or transcripts array"))
        }

        // No duplicate speaker IDs
        if let speakers = json["known_speakers"] as? [[String: Any]] {
            let ids = speakers.compactMap { $0["persistent_id"] as? String }
            let uniqueIds = Set(ids)
            if ids.count == uniqueIds.count {
                results.append(.pass("index/no-duplicate-speakers", target: target))
            } else {
                results.append(.fail("index/no-duplicate-speakers", target: target, detail: "\(ids.count - uniqueIds.count) duplicate speaker IDs"))
            }
        }

        return results
    }
}
