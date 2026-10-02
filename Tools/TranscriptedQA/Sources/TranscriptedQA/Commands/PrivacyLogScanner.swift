import Foundation

enum PrivacyLogScanner {
    private static let sensitiveKeys = Set([
        "transcript",
        "transcript_text",
        "raw_transcript",
        "audio_path",
        "audio_url",
        "meeting_title",
        "speaker_name",
        "speaker_names",
        "email",
        "token",
        "authorization",
        "password",
        "secret",
        "url",
        "file_path",
        "absolute_path",
        "device_name",
        "source_app",
    ])

    static func findings(in content: String, allowedPathPrefixes: [String] = []) -> [String] {
        var findings: [String] = []
        let normalizedAllowedPathPrefixes = normalizeAllowedPathPrefixes(allowedPathPrefixes)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: true)
        for (index, lineSlice) in lines.enumerated() {
            let line = String(lineSlice)
            if let jsonFinding = jsonFinding(
                in: line,
                lineNumber: index + 1,
                allowedPathPrefixes: normalizedAllowedPathPrefixes
            ) {
                findings.append(jsonFinding)
                continue
            }
            if containsEmail(line) {
                findings.append("line \(index + 1) contains an email-like value")
            }
            if containsTokenAssignment(line) {
                findings.append("line \(index + 1) contains a token/secret-looking assignment")
            }
            if containsDisallowedLocalPath(line, allowedPathPrefixes: normalizedAllowedPathPrefixes) {
                findings.append("line \(index + 1) contains an absolute local path")
            }
        }
        return findings
    }

    private static func jsonFinding(
        in line: String,
        lineNumber: Int,
        allowedPathPrefixes: [String]
    ) -> String? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }
        if let key = firstSensitiveKey(in: object) {
            return "line \(lineNumber) contains sensitive key \(key)"
        }
        if containsSensitiveValue(in: object, allowedPathPrefixes: allowedPathPrefixes) {
            return "line \(lineNumber) contains an email, URL, or absolute local path"
        }
        return nil
    }

    private static func firstSensitiveKey(in object: Any) -> String? {
        if let dictionary = object as? [String: Any] {
            for (key, value) in dictionary {
                if sensitiveKeys.contains(normalized(key)) {
                    return key
                }
                if let nested = firstSensitiveKey(in: value) {
                    return nested
                }
            }
        }
        if let array = object as? [Any] {
            for value in array {
                if let nested = firstSensitiveKey(in: value) {
                    return nested
                }
            }
        }
        return nil
    }

    private static func containsSensitiveValue(
        in object: Any,
        allowedPathPrefixes: [String]
    ) -> Bool {
        if let string = object as? String {
            return containsEmail(string) || containsDisallowedLocalPath(string, allowedPathPrefixes: allowedPathPrefixes)
        }
        if let dictionary = object as? [String: Any] {
            return dictionary.values.contains { containsSensitiveValue(in: $0, allowedPathPrefixes: allowedPathPrefixes) }
        }
        if let array = object as? [Any] {
            return array.contains { containsSensitiveValue(in: $0, allowedPathPrefixes: allowedPathPrefixes) }
        }
        return false
    }

    private static func normalizeAllowedPathPrefixes(_ prefixes: [String]) -> [String] {
        Array(
            Set(
                prefixes
                    .filter { !$0.isEmpty }
                    .map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            )
        ).sorted()
    }

    private static func containsDisallowedLocalPath(
        _ value: String,
        allowedPathPrefixes: [String]
    ) -> Bool {
        let pattern = #"(file://[^\s`"']+|/(?:Users|Volumes|private|tmp)/[^\s`"']+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return value.contains("/Users/") || value.contains("file://")
        }

        let fullRange = NSRange(value.startIndex..<value.endIndex, in: value)
        for match in regex.matches(in: value, range: fullRange) {
            guard let range = Range(match.range, in: value) else { continue }
            let normalized = normalizedLocalPath(String(value[range]))
            if isAllowedLocalPath(normalized, allowedPathPrefixes: allowedPathPrefixes) {
                continue
            }
            return true
        }
        return false
    }

    private static func normalizedLocalPath(_ candidate: String) -> String {
        let trimmed = candidate.trimmingCharacters(in: CharacterSet(charactersIn: ",;:.)]"))
        if trimmed.hasPrefix("file://"),
           let url = URL(string: trimmed),
           url.isFileURL {
            return url.standardizedFileURL.path
        }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    private static func isAllowedLocalPath(
        _ path: String,
        allowedPathPrefixes: [String]
    ) -> Bool {
        allowedPathPrefixes.contains { prefix in
            path == prefix || path.hasPrefix(prefix + "/")
        }
    }

    private static func normalized(_ value: String) -> String {
        value
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .lowercased()
    }

    private static func containsEmail(_ value: String) -> Bool {
        value.range(of: #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func containsTokenAssignment(_ value: String) -> Bool {
        value.range(of: #"(?i)(token|api[_-]?key|authorization|bearer|secret|password)\s*[:=]"#, options: .regularExpression) != nil
    }
}
