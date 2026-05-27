// ObservabilityTextRedactorTests.swift
// Direct unit tests for the regex-only redaction layer underneath
// AnalyticsPayloadSanitizer / SentryPayloadSanitizer. These tests pin behavior
// that the wrappers obscure (length truncation, key-drop, etc.):
//   - empty / whitespace-only input handling
//   - speaker_name / meeting_title / transcript_text JSON assignment redaction
//   - inline `key=value` form for the same sensitive identifiers
//   - "(parakeet, <device>)" / "(whisper, <device>)" engine device log redaction
//   - speaker names embedded in free text get redacted when wrapped in a
//     JSON-style assignment (the wrappers above would also drop them,
//     but the redactor must scrub the value)
// Privacy: nothing from the sensitive-identifier list should survive.

import Foundation

func testObservabilityTextRedactor() {
    runSuite("ObservabilityTextRedactor returns empty for empty or whitespace-only input") {
        assertEqual(ObservabilityTextRedactor.redact(""), "", "empty input must stay empty")
        assertEqual(ObservabilityTextRedactor.redact("   "), "", "whitespace-only input must collapse to empty")
        assertEqual(ObservabilityTextRedactor.redact("\n\t  \n"), "", "tabs/newlines-only input must collapse to empty")
    }

    runSuite("ObservabilityTextRedactor trims surrounding whitespace before redaction") {
        let result = ObservabilityTextRedactor.redact("   hello world  \n")
        assertEqual(result, "hello world", "leading/trailing whitespace should be stripped")
    }

    runSuite("ObservabilityTextRedactor scrubs JSON-style transcript_text assignments") {
        let input = #"{"transcript_text":"Hello there, this is private speech","other":"safe"}"#
        let redacted = ObservabilityTextRedactor.redact(input)

        assertFalse(redacted.contains("Hello there"), "transcript text content must not survive")
        assertFalse(redacted.contains("private speech"), "transcript text content must not survive")
        assertTrue(redacted.contains("[redacted-sensitive-value]"), "transcript assignment should collapse to a marker")
        assertTrue(redacted.contains("\"other\":\"safe\""), "non-sensitive sibling values should remain")
    }

    runSuite("ObservabilityTextRedactor scrubs JSON-style speaker_name and meeting_title assignments") {
        let input = #"{"speaker_name":"Jane Doe","meeting_title":"Q4 Strategy with Acme","duration_ms":1234}"#
        let redacted = ObservabilityTextRedactor.redact(input)

        assertFalse(redacted.contains("Jane Doe"), "speaker name must not survive")
        assertFalse(redacted.contains("Q4 Strategy"), "meeting title must not survive")
        assertFalse(redacted.contains("Acme"), "meeting title contents must not survive")
        assertTrue(redacted.contains("\"speaker_name\":\"[redacted-sensitive-value]\""), "speaker name assignment marker should remain")
        assertTrue(redacted.contains("\"meeting_title\":\"[redacted-sensitive-value]\""), "meeting title assignment marker should remain")
        assertTrue(redacted.contains("1234"), "numeric fields should remain")
    }

    runSuite("ObservabilityTextRedactor scrubs JSON-style device and file_path assignments") {
        let input = #"{"device_name":"Jane's AirPods Pro","file_path":"/Users/jane/audio.wav","audio_device":"Built-in"}"#
        let redacted = ObservabilityTextRedactor.redact(input)

        assertFalse(redacted.contains("Jane's AirPods"), "device name must not survive")
        assertFalse(redacted.contains("/Users/jane/audio.wav"), "file path must not survive")
        assertFalse(redacted.contains("Built-in"), "audio_device must not survive")
        // The path may also be scrubbed by the path regex, but the assignment marker is the contract.
        assertTrue(redacted.contains("[redacted-sensitive-value]") || redacted.contains("[redacted-path]"),
                   "sensitive device/file assignments should be redacted")
    }

    runSuite("ObservabilityTextRedactor scrubs local paths that contain spaces") {
        let input = "failed to read /Users/jane/Documents/Client Calls/ACME Roadmap.md, /tmp/Meeting Imports/source audio.wav, and /private/tmp/Private Temp Imports/source audio.wav from /Users/jane/Library/Application Support/Transcripted/John's Call (équipe).wav status=retry trigger=hotkey"
        let redacted = ObservabilityTextRedactor.redact(input)

        assertFalse(redacted.contains("Client Calls"), "user folder paths with spaces must not survive")
        assertFalse(redacted.contains("ACME Roadmap.md"), "full user path tail must be scrubbed")
        assertFalse(redacted.contains("Meeting Imports"), "temporary paths with spaces must not survive")
        assertFalse(redacted.contains("Private Temp Imports"), "private temporary paths with spaces must not survive")
        assertFalse(redacted.contains("John's Call"), "apostrophes in app-support filenames must not leak")
        assertFalse(redacted.contains("équipe"), "non-ASCII app-support filename tails must not leak")
        assertTrue(redacted.contains("[redacted-path]"), "path marker should remain")
        assertTrue(redacted.contains("status=retry"), "safe metadata after a path should remain")
        assertTrue(redacted.contains("trigger=hotkey"), "safe metadata after a path should remain")
    }

    runSuite("ObservabilityTextRedactor scrubs user-selected paths with spaces") {
        let input = "imported /Users/jane/Projects/Client Calls/ACME Roadmap.md and /Volumes/External Disk/Meeting Imports/source audio.wav by /Users/jane/Documents/person@example.com/Private Folder/followup.md"
        let redacted = ObservabilityTextRedactor.redact(input)

        assertFalse(redacted.contains("Client Calls"), "custom user folder paths with spaces must not survive")
        assertFalse(redacted.contains("External Disk"), "volume paths with spaces must not survive")
        assertFalse(redacted.contains("source audio.wav"), "volume path tails must not survive")
        assertFalse(redacted.contains("person@example.com"), "emails embedded in paths must not survive")
        assertFalse(redacted.contains("Private Folder"), "path tails after email-like segments must not survive")
        assertTrue(redacted.contains("[redacted-path]"), "path marker should remain")
    }

    runSuite("ObservabilityTextRedactor does not stop early inside legal path names") {
        let input = "failed /Users/jane/Documents/Acme.com Calls/source audio.wav, /Users/jane/Documents/Acme.com, Inc/source.wav, /Users/jane/Documents/v1.0,backup/source.wav, and /Users/jane/Documents/Client [Acme.com]/source status=retry.wav trigger=hotkey"
        let redacted = ObservabilityTextRedactor.redact(input)

        assertFalse(redacted.contains("Acme.com Calls"), "dotted path components before spaces must not leak")
        assertFalse(redacted.contains("Acme.com, Inc"), "punctuated dotted path components must not leak")
        assertFalse(redacted.contains("v1.0,backup"), "punctuation after dotted path components must not leak")
        assertFalse(redacted.contains("Client [Acme.com]"), "bracketed path components must not leak")
        assertFalse(redacted.contains("source audio.wav"), "file names after dotted components must not leak")
        assertFalse(redacted.contains("source.wav"), "file names after punctuated dotted components must not leak")
        assertFalse(redacted.contains("source status=retry.wav"), "file names with key-like tokens must not leak")
        assertTrue(redacted.contains("trigger=hotkey"), "safe metadata after the path should remain")
    }

    runSuite("ObservabilityTextRedactor preserves diagnostics after punctuated filenames") {
        let input = "failed /Users/jane/Documents/Report.pdf, permission denied code=1"
        let redacted = ObservabilityTextRedactor.redact(input)

        assertFalse(redacted.contains("Report.pdf"), "filename before punctuation must not survive")
        assertTrue(redacted.contains("[redacted-path], permission denied code=1"),
                   "diagnostic prose after path punctuation should remain")
    }

    runSuite("ObservabilityTextRedactor keeps key-like tokens inside path tails") {
        let input = "failed /Users/jane/Documents/Project A=1 Notes/source audio.wav status=retry"
        let redacted = ObservabilityTextRedactor.redact(input)

        assertFalse(redacted.contains("A=1 Notes"), "key-like path folder names must not leak")
        assertFalse(redacted.contains("source audio.wav"), "path tails after key-like folders must not leak")
        assertTrue(redacted.contains("status=retry"), "safe metadata after the path should remain")
    }

    runSuite("ObservabilityTextRedactor scrubs inline key=value sensitive assignments") {
        let input = "ctx meeting_title=Private Roadmap speaker_name=Jane Doe trigger=hotkey"
        let redacted = ObservabilityTextRedactor.redact(input)

        assertFalse(redacted.contains("Private Roadmap"), "meeting title value must not survive inline form")
        assertFalse(redacted.contains("Jane Doe"), "speaker name value must not survive inline form")
        assertTrue(redacted.contains("meeting_title=[redacted-sensitive-value]"), "inline meeting_title marker should remain")
        assertTrue(redacted.contains("speaker_name=[redacted-sensitive-value]"), "inline speaker_name marker should remain")
        assertTrue(redacted.contains("trigger=hotkey"), "non-sensitive trigger should remain")
    }

    runSuite("ObservabilityTextRedactor scrubs (parakeet, device) and (whisper, device) tuples") {
        // The engineDeviceLogRegex protects logs like `STT route changed (parakeet, Jane's Mic)`
        // where the engine name is fine but the device name leaks.
        let cases: [(String, String)] = [
            ("STT route (parakeet, Jane's MacBook Microphone)", "STT route (parakeet, [redacted-sensitive-value])"),
            ("Engine restart (whisper, External USB Mic Pro)", "Engine restart (whisper, [redacted-sensitive-value])"),
            ("(WHISPER, Some Device)", "(WHISPER, [redacted-sensitive-value])"),
        ]
        for (input, expected) in cases {
            let redacted = ObservabilityTextRedactor.redact(input)
            assertEqual(redacted, expected, "engine device log should redact device portion for input \(input.debugDescription)")
        }
    }

    runSuite("ObservabilityTextRedactor leaves non-engine tuples alone") {
        // Only parakeet / whisper engine logs should be rewritten. Other tuples
        // (e.g. coordinate pairs, generic logs) should not be over-eagerly redacted.
        let input = "Position (10, 20) recorded"
        let redacted = ObservabilityTextRedactor.redact(input)
        assertEqual(redacted, "Position (10, 20) recorded", "non-engine tuples should pass through unchanged")
    }

    runSuite("ObservabilityTextRedactor scrubs JSON source_app and bundle_id assignments") {
        let input = #"{"source_app":"com.slack.Slack","source_app_name":"Slack","bundle_id":"com.private.app"}"#
        let redacted = ObservabilityTextRedactor.redact(input)

        assertFalse(redacted.contains("com.slack.Slack"), "source_app bundle id must not survive")
        assertFalse(redacted.contains("\"Slack\""), "source_app_name must not survive")
        assertFalse(redacted.contains("com.private.app"), "bundle_id must not survive")
        // All three should collapse to the sensitive marker form.
        assertTrue(redacted.contains("\"source_app\":\"[redacted-sensitive-value]\""),
                   "source_app should collapse to marker")
        assertTrue(redacted.contains("\"source_app_name\":\"[redacted-sensitive-value]\""),
                   "source_app_name should collapse to marker")
        assertTrue(redacted.contains("\"bundle_id\":\"[redacted-sensitive-value]\""),
                   "bundle_id should collapse to marker")
    }

    runSuite("ObservabilityTextRedactor scrubs raw_url JSON assignments") {
        let input = #"{"raw_url":"https://example.com/secret?token=abc"}"#
        let redacted = ObservabilityTextRedactor.redact(input)
        assertFalse(redacted.contains("example.com/secret"), "raw_url value must not survive")
        assertFalse(redacted.contains("token=abc"), "embedded token must not survive")
        // Either path: the URL regex collapses to [redacted-url] or the assignment regex collapses to [redacted-sensitive-value].
        let scrubbed = redacted.contains("[redacted-url]") || redacted.contains("[redacted-sensitive-value]")
        assertTrue(scrubbed, "raw_url should be either URL- or assignment-scrubbed; got \(redacted.debugDescription)")
    }

    runSuite("ObservabilityTextRedactor handles long input without truncating") {
        // The redactor itself does not truncate (that's the sanitizers' job).
        // Make sure a long mixed payload stays full-length, but with all
        // sensitive fragments removed.
        let secret = "person@example.com"
        let chunk = "Filler line without sensitive content. "
        let input = String(repeating: chunk, count: 50) + " trailing email " + secret
        let redacted = ObservabilityTextRedactor.redact(input)

        assertFalse(redacted.contains(secret), "trailing email must be redacted even in long input")
        assertTrue(redacted.contains("[redacted-email]"), "email marker should remain")
        assertTrue(redacted.count > 500, "redactor must not truncate long input; got \(redacted.count) chars")
    }

    runSuite("ObservabilityTextRedactor scrubs case-insensitive JSON sensitive keys") {
        // The jsonSensitiveAssignmentRegex uses [.caseInsensitive], so casing
        // of the key shouldn't matter — only the value must collapse.
        let input = #"{"Speaker_Name":"Jane","TRANSCRIPT_TEXT":"private speech"}"#
        let redacted = ObservabilityTextRedactor.redact(input)

        assertFalse(redacted.contains("\"Jane\""), "uppercased speaker name value must not survive")
        assertFalse(redacted.contains("private speech"), "uppercased transcript text value must not survive")
    }

    runSuite("ObservabilityTextRedactor preserves non-sensitive coarse JSON values") {
        let input = #"{"duration_bucket":"5_14m","trigger":"hotkey","attempt":3}"#
        let redacted = ObservabilityTextRedactor.redact(input)
        assertTrue(redacted.contains("\"duration_bucket\":\"5_14m\""), "coarse bucket should survive")
        assertTrue(redacted.contains("\"trigger\":\"hotkey\""), "coarse trigger should survive")
        assertTrue(redacted.contains("\"attempt\":3"), "numeric attempt counter should survive")
    }
}
