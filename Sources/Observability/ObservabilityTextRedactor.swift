import Foundation

enum ObservabilityTextRedactor {
    // Security: compile-time regex patterns are built via this helper instead of try! so that a
    // future malformed pattern triggers an assertionFailure in debug builds and falls back to a
    // no-op regex in release builds, keeping the redaction path alive rather than crashing it.
    private static func makeRegex(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        if let regex = try? NSRegularExpression(pattern: pattern, options: options) {
            return regex
        }
        assertionFailure("Sanitizer regex failed to compile; pattern will be skipped: \(pattern)")
        // "(?!)" is a negative lookahead that never matches, so substitution is a no-op.
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: "(?!)")
    }

    private static let pathStartRegex = makeRegex(
        #"(?<!https:)(?<!http:)(?<![A-Za-z0-9._%+\-])/(?:System/Volumes/Data/)?(?:Users|Volumes|private/tmp|private/var|var|tmp|Applications|Library|opt)(?=/|$)"#
    )
    private static let userPathRegex = makeRegex(#"/Users/[^/\s]+/"#)
    private static let absolutePathRegex = makeRegex(
        #"(?<!https:)(?<!http:)/(?:System/Volumes/Data/)?(?:Users|private|var|tmp|Volumes|Applications|Library|opt)[^\s"]*"#
    )
    private static let rawURLRegex = makeRegex(#"https?://[^\s"]+"#, options: [.caseInsensitive])
    private static let apiKeyRegex = makeRegex(#"sk-[A-Za-z0-9_-]+"#)
    private static let commonSecretRegex = makeRegex(
        #"\b(?:ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|phc_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|AIza[0-9A-Za-z\-_]{35}|xox[baprs]-[A-Za-z0-9-]{10,}|xoxx-[A-Za-z0-9-]{10,}|eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9._-]{10,}\.[A-Za-z0-9._-]{10,})\b"#
    )
    private static let authSchemeRegex = makeRegex(#"(Bearer|Basic)\s+[A-Za-z0-9._~+\/=-]+"#, options: [.caseInsensitive])
    private static let authorizationAssignmentRegex = makeRegex(
        #"(?i)\b((?:proxy-)?authorization)\s*[:=]\s*(?:basic|bearer)\s+[^\s,;]+"#
    )
    private static let privateKeyBlockRegex = makeRegex(
        #"-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----"#,
        options: [.caseInsensitive]
    )
    private static let privateKeyMarkerRegex = makeRegex(
        #"-----((?:BEGIN|END)) [A-Z0-9 ]*PRIVATE KEY-----"#,
        options: [.caseInsensitive]
    )
    private static let jsonSensitiveAssignmentRegex = makeRegex(
        #""(audio_device|bundle_id|device_name|file_path|input_device_name|meeting_name|meeting_title|microphone_name|output_device_name|raw_url|source_app|source_app_bundle_id|source_app_name|speaker_name|transcript_text|transcript_title)"\s*:\s*"(?:\\.|[^"\\])*""#,
        options: [.caseInsensitive]
    )
    private static let inlineSensitiveAssignmentRegex = makeRegex(
        #"\b(audio_device|bundle_id|device_name|file_path|input_device_name|meeting_name|meeting_title|microphone_name|output_device_name|raw_url|source_app|source_app_bundle_id|source_app_name|speaker_name|transcript_text|transcript_title)\s*=\s*.*?(?=\s+[A-Za-z0-9_.$-]+=|$)"#,
        options: [.caseInsensitive]
    )
    private static let engineDeviceLogRegex = makeRegex(
        #"\((parakeet|whisper),\s*[^)]*\)"#,
        options: [.caseInsensitive]
    )
    private static let secretAssignmentRegex = makeRegex(
        #"(?i)\b((?:access_)?token|refresh_token|api[_-]?key|x-api-key|signature|x-amz-signature|password|passphrase|secret|client[_-]?secret|credential|dsn)\s*[:=]\s*([^\s,;]+)"#
    )
    private static let emailRegex = makeRegex(#"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#, options: [.caseInsensitive])
    private static let localHostnameRegex = makeRegex(#"\b[a-zA-Z0-9._-]+\.local\b"#)
    private static let pathDiagnosticMetadataKeys: Set<String> = [
        "attempt",
        "attempts",
        "code",
        "duration_ms",
        "error",
        "event",
        "failure_kind",
        "operation",
        "outcome",
        "reason",
        "stage",
        "status",
        "trigger",
        "wait_ms",
    ]

    static func redact(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var result = trimmed
        var range = NSRange(result.startIndex..., in: result)
        result = redactFilePaths(in: result)
        range = NSRange(result.startIndex..., in: result)
        result = userPathRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "/Users/****/")
        range = NSRange(result.startIndex..., in: result)
        result = absolutePathRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "[redacted-path]")
        range = NSRange(result.startIndex..., in: result)
        result = rawURLRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "[redacted-url]")
        range = NSRange(result.startIndex..., in: result)
        result = apiKeyRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "sk-****")
        range = NSRange(result.startIndex..., in: result)
        result = commonSecretRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "[redacted-secret]")
        range = NSRange(result.startIndex..., in: result)
        result = authorizationAssignmentRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1=[redacted-secret]")
        range = NSRange(result.startIndex..., in: result)
        result = authSchemeRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1 ****")
        range = NSRange(result.startIndex..., in: result)
        result = privateKeyBlockRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "[redacted-secret]")
        range = NSRange(result.startIndex..., in: result)
        result = privateKeyMarkerRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "[redacted-secret]")
        range = NSRange(result.startIndex..., in: result)
        result = jsonSensitiveAssignmentRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "\"$1\":\"[redacted-sensitive-value]\"")
        range = NSRange(result.startIndex..., in: result)
        result = inlineSensitiveAssignmentRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1=[redacted-sensitive-value]")
        range = NSRange(result.startIndex..., in: result)
        result = engineDeviceLogRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "($1, [redacted-sensitive-value])")
        range = NSRange(result.startIndex..., in: result)
        result = secretAssignmentRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "$1=[redacted-secret]")
        range = NSRange(result.startIndex..., in: result)
        result = emailRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "[redacted-email]")
        range = NSRange(result.startIndex..., in: result)
        result = localHostnameRegex.stringByReplacingMatches(in: result, range: range, withTemplate: "[redacted-host]")
        range = NSRange(result.startIndex..., in: result)
        return result
    }

    private static func redactFilePaths(in text: String) -> String {
        var result = text
        let matches = pathStartRegex.matches(
            in: result,
            range: NSRange(result.startIndex..., in: result)
        )

        for match in matches.reversed() {
            guard let start = Range(match.range, in: result)?.lowerBound else { continue }
            let end = pathEnd(in: result, from: start)
            guard start < end else { continue }
            result.replaceSubrange(start..<end, with: "[redacted-path]")
        }

        return result
    }

    private static func pathEnd(in text: String, from start: String.Index) -> String.Index {
        var index = start

        while index < text.endIndex {
            let character = text[index]
            if isHardPathDelimiter(character) {
                break
            }

            if isSoftPathDelimiter(character),
               softDelimiterEndsPath(in: text, at: index) {
                break
            }

            if character == " " {
                let prefix = text[start..<index]
                let nextToken = nextPathToken(in: text, after: index)
                let pathContinuesLater = pathContinuationAppears(in: text, after: index)
                if nextTokenLooksLikeMetadata(nextToken) && !pathContinuesLater {
                    break
                }
                if pathPrefixLooksLikeFile(prefix)
                    && !nextTokenCouldContinuePath(nextToken)
                    && !pathContinuesLater {
                    break
                }
            }

            index = text.index(after: index)
        }

        return index
    }

    private static func isHardPathDelimiter(_ character: Character) -> Bool {
        character == "\n"
            || character == "\r"
            || character == "\t"
            || character == "\""
    }

    private static func isSoftPathDelimiter(_ character: Character) -> Bool {
        character == ","
            || character == ";"
            || character == ":"
            || character == ")"
            || character == "]"
            || character == "}"
    }

    private static func softDelimiterEndsPath(in text: String, at index: String.Index) -> Bool {
        let nextIndex = text.index(after: index)
        guard nextIndex < text.endIndex else { return true }

        let nextCharacter = text[nextIndex]
        if isHardPathDelimiter(nextCharacter) {
            return true
        }

        if nextCharacter == " " {
            return !nextTokenCouldContinuePath(nextPathToken(in: text, after: index))
        }

        return false
    }

    private static func pathPrefixLooksLikeFile(_ prefix: Substring) -> Bool {
        guard let slash = prefix.lastIndex(of: "/") else { return false }
        let filename = prefix[prefix.index(after: slash)...]
        guard let dot = filename.lastIndex(of: ".") else { return false }
        let ext = filename[filename.index(after: dot)...]
        guard (1...8).contains(ext.count) else { return false }
        return ext.allSatisfy { $0.isLetter || $0.isNumber }
    }

    private static func nextPathToken(in text: String, after spaceIndex: String.Index) -> String {
        var index = text.index(after: spaceIndex)
        while index < text.endIndex, text[index] == " " {
            index = text.index(after: index)
        }

        var token = ""
        while index < text.endIndex {
            let character = text[index]
            if character == " " || isHardPathDelimiter(character) {
                break
            }
            token.append(character)
            index = text.index(after: index)
        }

        return token
    }

    private static func nextTokenCouldContinuePath(_ token: String) -> Bool {
        let normalized = normalizedPathToken(token)
        let lowercased = normalized.lowercased()
        guard !normalized.contains("@"),
              !lowercased.hasPrefix("http://"),
              !lowercased.hasPrefix("https://"),
              !lowercased.hasSuffix(".local") else {
            return false
        }
        return normalized.contains("/") || pathTokenLooksLikeFile(normalized)
    }

    private static func pathContinuationAppears(in text: String, after spaceIndex: String.Index) -> Bool {
        var index = text.index(after: spaceIndex)
        var inspectedTokens = 0

        while index < text.endIndex && inspectedTokens < 8 {
            while index < text.endIndex, text[index] == " " {
                index = text.index(after: index)
            }
            guard index < text.endIndex, !isHardPathDelimiter(text[index]) else {
                return false
            }

            var token = ""
            while index < text.endIndex {
                let character = text[index]
                if character == " " || isHardPathDelimiter(character) {
                    break
                }
                token.append(character)
                index = text.index(after: index)
            }

            if nextTokenCouldContinuePath(token) {
                return true
            }
            inspectedTokens += 1
        }

        return false
    }

    private static func nextTokenLooksLikeMetadata(_ token: String) -> Bool {
        let normalized = normalizedPathToken(token)
        guard !normalized.contains("/"),
              !pathTokenLooksLikeFile(normalized),
              let separator = normalized.firstIndex(of: "=") else {
            return false
        }
        let key = String(normalized[..<separator]).lowercased()
        return pathDiagnosticMetadataKeys.contains(key)
    }

    private static func normalizedPathToken(_ token: String) -> String {
        token.trimmingCharacters(in: CharacterSet(charactersIn: ",;:)]}"))
    }

    private static func pathTokenLooksLikeFile(_ token: String) -> Bool {
        guard let dot = token.lastIndex(of: ".") else { return false }
        let ext = token[token.index(after: dot)...]
        guard (1...8).contains(ext.count) else { return false }
        return ext.allSatisfy { $0.isLetter || $0.isNumber }
    }
}
