import Foundation

/// Generic privacy redaction for free-form diagnostic text.
///
/// Callers keep their own metadata/key policies and pass only the path-boundary
/// keys that belong to their existing text format. This keeps the sensitive
/// value patterns in one place without making local logs, Sentry, or analytics
/// share a payload schema.
public enum PrivacyTextRedactor {
    private static let redactedSensitiveValue = "[redacted-sensitive-value]"
    private static let redactedPath = "[redacted-path]"
    private static let redactedURL = "[redacted-url]"
    private static let redactedEmail = "[redacted-email]"
    private static let redactedSecret = "[redacted-secret]"

    private static let pathStartRegex = makeRegex(
        #"(?<!https:)(?<!http:)(?<![A-Za-z0-9._%+\-])/(?:System/Volumes/Data/)?(?:Users|Volumes|private/tmp|private/var|var|tmp|Applications|Library|opt)(?=/|$)"#
    )
    private static let userPathRegex = makeRegex(#"/Users/[^/\s]+/"#)
    private static let absolutePathRegex = makeRegex(
        #"(?<!https:)(?<!http:)/(?:System/Volumes/Data/)?(?:Users|private|var|tmp|Volumes|Applications|Library|opt)[^\s\"]*"#
    )
    private static let rawURLRegex = makeRegex(#"https?://[^\s\"]+"#, options: [.caseInsensitive])
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
        #"\"(audio_device|audio_path|bundle_id|default_input_name|default_output_name|device_name|download_url|file_path|input_device_name|input_name|meeting_name|meeting_title|meeting_url|microphone_name|output_device_name|output_name|prompt_text|raw_url|source_app|source_app_bundle|source_app_bundle_id|source_app_name|speaker_name|title|transcript|transcript_path|transcript_text|transcript_title|url)\"\s*:\s*\"(?:\\.|[^\"\\])*\""#,
        options: [.caseInsensitive]
    )
    private static let inlineSensitiveAssignmentRegex = makeRegex(
        #"\b(audio_device|audio_path|bundle_id|default_input_name|default_output_name|device_name|download_url|file_path|input_device_name|input_name|meeting_name|meeting_title|meeting_url|microphone_name|output_device_name|output_name|prompt_text|raw_url|source_app|source_app_bundle|source_app_bundle_id|source_app_name|speaker_name|title|transcript|transcript_path|transcript_text|transcript_title|url)\s*=\s*.*?(?=\s+[A-Za-z0-9_.$-]+=|$)"#,
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

    /// Redacts free-form text while preserving the caller's existing path
    /// boundary behavior.
    ///
    /// `pathDiagnosticMetadataKeys` decides which `key=value` tokens terminate
    /// an extensionless absolute path. `redactEmbeddedAbsolutePaths` preserves
    /// the app observability redactor's legacy fallback for path-looking text
    /// embedded after another character; Core logging historically leaves that
    /// fallback disabled.
    public static func redact(
        _ text: String,
        pathDiagnosticMetadataKeys: Set<String>,
        redactEmbeddedAbsolutePaths: Bool = false
    ) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return "" }

        result = redactFilePaths(
            in: result,
            pathDiagnosticMetadataKeys: pathDiagnosticMetadataKeys
        )
        if redactEmbeddedAbsolutePaths {
            result = replace(userPathRegex, in: result, with: "/Users/****/")
            result = replace(absolutePathRegex, in: result, with: redactedPath)
        }
        result = replace(rawURLRegex, in: result, with: redactedURL)
        result = replace(apiKeyRegex, in: result, with: "sk-****")
        result = replace(commonSecretRegex, in: result, with: redactedSecret)
        result = replace(authorizationAssignmentRegex, in: result, with: "$1=\(redactedSecret)")
        result = replace(authSchemeRegex, in: result, with: "$1 ****")
        result = replace(privateKeyBlockRegex, in: result, with: redactedSecret)
        result = replace(privateKeyMarkerRegex, in: result, with: redactedSecret)
        result = replace(jsonSensitiveAssignmentRegex, in: result, with: "\"$1\":\"\(redactedSensitiveValue)\"")
        result = replace(inlineSensitiveAssignmentRegex, in: result, with: "$1=\(redactedSensitiveValue)")
        result = replace(engineDeviceLogRegex, in: result, with: "($1, \(redactedSensitiveValue))")
        result = replace(secretAssignmentRegex, in: result, with: "$1=\(redactedSecret)")
        result = replace(emailRegex, in: result, with: redactedEmail)
        result = replace(localHostnameRegex, in: result, with: "[redacted-host]")
        return result
    }

    private static func makeRegex(
        _ pattern: String,
        options: NSRegularExpression.Options = []
    ) -> NSRegularExpression {
        if let regex = try? NSRegularExpression(pattern: pattern, options: options) {
            return regex
        }
        assertionFailure("Privacy text redactor regex failed to compile; pattern will be skipped: \(pattern)")
        // swiftlint:disable:next force_try
        return try! NSRegularExpression(pattern: "(?!)")
    }

    private static func replace(
        _ regex: NSRegularExpression,
        in text: String,
        with template: String
    ) -> String {
        regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }

    private static func redactFilePaths(
        in text: String,
        pathDiagnosticMetadataKeys: Set<String>
    ) -> String {
        var result = text
        let matches = pathStartRegex.matches(
            in: result,
            range: NSRange(result.startIndex..., in: result)
        )

        for match in matches.reversed() {
            guard let start = Range(match.range, in: result)?.lowerBound else { continue }
            let end = pathEnd(
                in: result,
                from: start,
                pathDiagnosticMetadataKeys: pathDiagnosticMetadataKeys
            )
            guard start < end else { continue }
            result.replaceSubrange(start..<end, with: redactedPath)
        }

        return result
    }

    private static func pathEnd(
        in text: String,
        from start: String.Index,
        pathDiagnosticMetadataKeys: Set<String>
    ) -> String.Index {
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
                let token = nextPathToken(in: text, after: index)
                let pathContinuesLater = pathContinuationAppears(in: text, after: index)
                if looksLikeMetadataToken(
                    token,
                    pathDiagnosticMetadataKeys: pathDiagnosticMetadataKeys
                ) && !pathContinuesLater {
                    break
                }
                if pathPrefixLooksLikeFile(prefix)
                    && !nextTokenCouldContinuePath(token)
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

    private static func pathContinuationAppears(
        in text: String,
        after spaceIndex: String.Index
    ) -> Bool {
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

    private static func pathPrefixLooksLikeFile(_ prefix: Substring) -> Bool {
        guard let slash = prefix.lastIndex(of: "/") else { return false }
        return pathTokenLooksLikeFile(String(prefix[prefix.index(after: slash)...]))
    }

    private static func pathTokenLooksLikeFile(_ token: String) -> Bool {
        let normalized = normalizedPathToken(token)
        guard let dot = normalized.lastIndex(of: ".") else { return false }
        let ext = normalized[normalized.index(after: dot)...]
        guard (1...8).contains(ext.count) else { return false }
        return ext.allSatisfy { $0.isLetter || $0.isNumber }
    }

    private static func looksLikeMetadataToken(
        _ token: String,
        pathDiagnosticMetadataKeys: Set<String>
    ) -> Bool {
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
}
