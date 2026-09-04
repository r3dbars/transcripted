import Foundation

public enum RuntimeEventAnalyzer {
    public static func analyze(
        eventsURL: URL,
        windowHours: Double,
        minimumSamples: Int,
        strictGates: Bool,
        now: Date = Date()
    ) throws -> LabAnalysisResult {
        guard FileManager.default.fileExists(atPath: eventsURL.path) else {
            throw LabRunnerError.missingInput(eventsURL.path)
        }

        let text = try readTailText(eventsURL, maximumBytes: 64 * 1024 * 1024)
        let cutoff = windowHours > 0 ? now.addingTimeInterval(-windowHours * 3_600) : nil
        var transcriptionElapsed: [Double] = []
        var transcriptionRTF: [Double] = []
        var fastStart: [Double] = []
        var requestToRecording: [Double] = []
        var startToFirstSample: [Double] = []
        var stopToPaste: [Double] = []
        var stopToDone: [Double] = []
        var fallbackCount = 0
        var errorCount = 0
        var parsedCount = 0

        text.enumerateLines { line, _ in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let event = object["event"] as? String else { return }
            if let cutoff,
               let timestampText = object["timestamp"] as? String,
               let timestamp = parseISO8601(timestampText),
               timestamp < cutoff {
                return
            }
            parsedCount += 1
            let context = object["context"] as? [String: Any] ?? [:]
            switch event {
            case "transcription_complete":
                if let value = context.labDouble("elapsed_s") { transcriptionElapsed.append(value) }
                if let value = context.labDouble("rtf") { transcriptionRTF.append(value) }
            case "dictation_recording_fast_start":
                if let value = context.labDouble("start_ms") { fastStart.append(value) }
                if let value = context.labDouble("request_to_recording_ms") { requestToRecording.append(value) }
            case "dictation_started_after_wait":
                if let value = context.labDouble("request_to_recording_ms") { requestToRecording.append(value) }
            case "audio_samples_detected":
                if let value = context.labDouble("start_to_first_sample_ms") { startToFirstSample.append(value) }
            case "dictation_stop_latency_measured":
                if let value = context.labDouble("stop_to_paste_ms") { stopToPaste.append(value) }
                if let value = context.labDouble("stop_to_done_ms") { stopToDone.append(value) }
            case "dictation_fast_start_fell_back_to_wait", "dictation_recording_retry", "audio_start_deferred":
                fallbackCount += 1
            default:
                break
            }
            if (object["level"] as? String)?.lowercased() == "error" {
                errorCount += 1
            }
        }

        var metrics: [LabMetric] = [
            LabMetric(key: "events.parsed", label: "Events parsed", value: Double(parsedCount), unit: "events"),
            LabMetric(key: "dictation.fallbacks", label: "Start fallbacks / retries", value: Double(fallbackCount), unit: "events", target: 0, direction: .lowerIsBetter),
            LabMetric(key: "events.errors", label: "Error-level events", value: Double(errorCount), unit: "events", direction: .informational),
        ]
        addPercentiles(prefix: "transcription.elapsed", label: "Transcription", values: transcriptionElapsed, unit: "s", targetP95: 0.5, metrics: &metrics)
        addPercentiles(prefix: "transcription.rtf", label: "Transcription RTF", values: transcriptionRTF, unit: "RTF", targetP95: 0.05, metrics: &metrics)
        addPercentiles(prefix: "dictation.fast-start", label: "Dictation fast start", values: fastStart, unit: "ms", targetP95: 250, metrics: &metrics)
        addPercentiles(prefix: "dictation.request-to-recording", label: "Request to recording", values: requestToRecording, unit: "ms", targetP95: 250, metrics: &metrics)
        addPercentiles(prefix: "dictation.first-sample", label: "Start to first sample", values: startToFirstSample, unit: "ms", targetP95: 350, metrics: &metrics)
        addPercentiles(prefix: "dictation.stop-to-paste", label: "Stop to paste", values: stopToPaste, unit: "ms", targetP95: 750, metrics: &metrics)
        addPercentiles(prefix: "dictation.stop-to-done", label: "Stop to done", values: stopToDone, unit: "ms", targetP95: 1_000, metrics: &metrics)

        var dimensions: [LabScoreDimension] = []
        var warnings: [String] = []
        var hardFailures: [String] = []

        let transcriptionScores = [
            LabStatistics.lowerIsBetterScore(value: LabStatistics.percentile(transcriptionElapsed, 0.95), target: 0.5),
            LabStatistics.lowerIsBetterScore(value: LabStatistics.percentile(transcriptionRTF, 0.95), target: 0.05),
        ].compactMap { $0 }
        if transcriptionElapsed.count >= minimumSamples || transcriptionRTF.count >= minimumSamples,
           let score = averageScore(transcriptionScores) {
            dimensions.append(LabScoreDimension(
                key: "transcription-speed",
                label: "Transcription speed",
                score: score,
                weight: 0.30,
                explanation: "p95 decode time and real-time factor against Transcripted's existing budgets."
            ))
        } else {
            warnings.append("Not enough transcription samples to score reliably (need \(minimumSamples)).")
        }

        let startScores = [
            LabStatistics.lowerIsBetterScore(value: LabStatistics.percentile(fastStart, 0.95), target: 250),
            LabStatistics.lowerIsBetterScore(value: LabStatistics.percentile(requestToRecording, 0.95), target: 250),
            LabStatistics.lowerIsBetterScore(value: LabStatistics.percentile(startToFirstSample, 0.95), target: 350),
        ].compactMap { $0 }
        if max(fastStart.count, requestToRecording.count, startToFirstSample.count) >= minimumSamples,
           let score = averageScore(startScores) {
            dimensions.append(LabScoreDimension(
                key: "dictation-start",
                label: "Dictation start",
                score: score,
                weight: 0.30,
                explanation: "ready-engine start, request-to-recording, and first-audio-sample p95."
            ))
        } else {
            warnings.append("Not enough dictation-start samples to score reliably (need \(minimumSamples)).")
        }

        let stopScores = [
            LabStatistics.lowerIsBetterScore(value: LabStatistics.percentile(stopToPaste, 0.95), target: 750),
            LabStatistics.lowerIsBetterScore(value: LabStatistics.percentile(stopToDone, 0.95), target: 1_000),
        ].compactMap { $0 }
        if max(stopToPaste.count, stopToDone.count) >= minimumSamples,
           let score = averageScore(stopScores) {
            dimensions.append(LabScoreDimension(
                key: "dictation-stop",
                label: "Dictation stop",
                score: score,
                weight: 0.25,
                explanation: "stop-to-paste and full stop-pipeline p95."
            ))
        } else {
            warnings.append("Not enough dictation-stop samples to score reliably (need \(minimumSamples)).")
        }

        let reliabilityScore = max(0, 100 - fallbackCount * 20)
        dimensions.append(LabScoreDimension(
            key: "runtime-reliability",
            label: "Runtime reliability",
            score: reliabilityScore,
            weight: 0.15,
            explanation: "Fast-start fallback, retry, and deferred-start events."
        ))
        if strictGates && fallbackCount > 0 {
            hardFailures.append("Found \(fallbackCount) dictation fallback/retry event(s) in the selected window.")
        }

        let scorecard = LabScorecard.weighted(
            dimensions: dimensions,
            hardGateFailures: hardFailures,
            warnings: warnings
        )
        let summary = "Scored \(parsedCount) runtime events from the last \(Int(windowHours)) hours. \(fallbackCount) dictation fallback/retry events were observed."
        return LabAnalysisResult(
            summary: summary,
            metrics: metrics,
            scorecard: scorecard,
            artifacts: [LabArtifact(label: "Runtime events", path: eventsURL.path)]
        )
    }

    private static func readTailText(_ url: URL, maximumBytes: UInt64) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        if size > maximumBytes {
            try handle.seek(toOffset: size - maximumBytes)
        }
        let data = try handle.readToEnd() ?? Data()
        var text = String(decoding: data, as: UTF8.self)
        if size > maximumBytes, let firstNewline = text.firstIndex(of: "\n") {
            text = String(text[text.index(after: firstNewline)...])
        }
        return text
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func addPercentiles(
        prefix: String,
        label: String,
        values: [Double],
        unit: String,
        targetP95: Double,
        metrics: inout [LabMetric]
    ) {
        guard !values.isEmpty else { return }
        if let value = LabStatistics.percentile(values, 0.50) {
            metrics.append(LabMetric(key: "\(prefix).p50", label: "\(label) p50", value: value, unit: unit, sampleCount: values.count, direction: .lowerIsBetter))
        }
        if let value = LabStatistics.percentile(values, 0.95) {
            metrics.append(LabMetric(key: "\(prefix).p95", label: "\(label) p95", value: value, unit: unit, sampleCount: values.count, target: targetP95, direction: .lowerIsBetter))
        }
        if let value = LabStatistics.percentile(values, 0.99) {
            metrics.append(LabMetric(key: "\(prefix).p99", label: "\(label) p99", value: value, unit: unit, sampleCount: values.count, direction: .lowerIsBetter))
        }
    }
}

public enum DictationBenchmarkAnalyzer {
    public static func analyze(resultURL: URL, summaryURL: URL?) throws -> LabAnalysisResult {
        guard FileManager.default.fileExists(atPath: resultURL.path) else {
            throw LabRunnerError.reportNotFound(resultURL.path)
        }
        let text = try String(contentsOf: resultURL, encoding: .utf8)
        var cases: [[String: Any]] = []
        var runStart: [String: Any] = [:]
        text.enumerateLines { line, _ in
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            if object["record_type"] as? String == "run_start" {
                runStart = object
            } else if object["record_type"] as? String == "case_result" {
                cases.append(object)
            }
        }
        guard !cases.isEmpty else {
            throw LabRunnerError.reportNotFound("No case_result rows in \(resultURL.path)")
        }

        let stopToText = cases.compactMap { $0.labDouble("stop_to_text_s") }
        let stopToDelivery = cases.compactMap { $0.labDouble("stop_to_delivery_s") }
        let decode = cases.compactMap { $0.labDouble("decode_s") }
        let rtfs = cases.compactMap { row -> Double? in
            guard let decode = row.labDouble("decode_s"), let duration = row.labDouble("audio_duration_s"), duration > 0 else { return nil }
            return decode / duration
        }

        var hardFailures: [String] = []
        var warnings: [String] = ["This lane measures speed, delivery integrity, and output stability. It does not calculate word error rate."]
        var hashesByCase: [String: Set<String>] = [:]
        var expectedSpeechFailures = 0
        var silenceFailures = 0
        for row in cases {
            let id = row.labString("case_id") ?? "unknown"
            let noSpeech = (row["no_speech"] as? Bool) ?? false
            let saved = (row["saved"] as? Bool) ?? false
            let isSilence = id.contains("silence")
            if isSilence {
                if !noSpeech { silenceFailures += 1 }
            } else {
                if noSpeech || !saved { expectedSpeechFailures += 1 }
                if let hash = row.labString("text_hash"), !hash.isEmpty {
                    hashesByCase[id, default: []].insert(hash)
                }
            }
        }
        let unstableCases = hashesByCase.filter { $0.value.count > 1 }.map(\.key).sorted()
        if expectedSpeechFailures > 0 {
            hardFailures.append("\(expectedSpeechFailures) speech case(s) produced no final saved text.")
        }
        if silenceFailures > 0 {
            hardFailures.append("\(silenceFailures) silence case(s) produced text.")
        }
        if !unstableCases.isEmpty {
            hardFailures.append("Output changed across identical repetitions for: \(unstableCases.joined(separator: ", ")).")
        }

        var metrics: [LabMetric] = []
        if let value = runStart.labDouble("model_init_s") {
            metrics.append(LabMetric(key: "model.init", label: "Model initialization", value: value, unit: "s", direction: .lowerIsBetter))
        }
        addBenchPercentiles(prefix: "stop-to-text", label: "Stop to text", values: stopToText, unit: "s", target: 0.5, metrics: &metrics)
        addBenchPercentiles(prefix: "stop-to-delivery", label: "Stop to delivery", values: stopToDelivery, unit: "s", target: 0.75, metrics: &metrics)
        addBenchPercentiles(prefix: "decode", label: "Decode", values: decode, unit: "s", target: 0.5, metrics: &metrics)
        addBenchPercentiles(prefix: "rtf", label: "Decode RTF", values: rtfs, unit: "RTF", target: 0.05, metrics: &metrics)
        metrics.append(LabMetric(key: "cases.total", label: "Case evaluations", value: Double(cases.count), unit: "cases"))
        metrics.append(LabMetric(key: "cases.unstable", label: "Unstable cases", value: Double(unstableCases.count), unit: "cases", target: 0, direction: .lowerIsBetter))

        let speedParts = [
            LabStatistics.lowerIsBetterScore(value: LabStatistics.percentile(stopToText, 0.95), target: 0.5),
            LabStatistics.lowerIsBetterScore(value: LabStatistics.percentile(rtfs, 0.95), target: 0.05),
        ].compactMap { $0 }
        let deliveryParts = [
            LabStatistics.lowerIsBetterScore(value: LabStatistics.percentile(stopToDelivery, 0.95), target: 0.75),
        ].compactMap { $0 }
        let integrityScore = hardFailures.isEmpty ? 100 : 0
        var dimensions: [LabScoreDimension] = []
        if let score = averageScore(speedParts) {
            dimensions.append(LabScoreDimension(key: "dictation-speed", label: "Dictation speed", score: score, weight: 0.45, explanation: "p95 stop-to-text and decode real-time factor."))
        }
        if let score = averageScore(deliveryParts) {
            dimensions.append(LabScoreDimension(key: "delivery-speed", label: "Delivery speed", score: score, weight: 0.25, explanation: "p95 stop-to-delivery."))
        }
        dimensions.append(LabScoreDimension(key: "text-integrity", label: "Text integrity", score: integrityScore, weight: 0.30, explanation: "Speech produces saved text, silence stays silent, and repeated cases keep stable output hashes."))

        if decode.isEmpty {
            warnings.append("This variant did not emit a separate decode stage; stop-to-text remains the end-to-end speed measure.")
        }
        var artifacts = [LabArtifact(label: "Raw dictation results", path: resultURL.path)]
        if let summaryURL, FileManager.default.fileExists(atPath: summaryURL.path) {
            artifacts.append(LabArtifact(label: "Dictation summary", path: summaryURL.path))
        }
        return LabAnalysisResult(
            summary: "Ran \(cases.count) dictation case evaluations. p95 stop-to-text was \(format(LabStatistics.percentile(stopToText, 0.95)))s.",
            metrics: metrics,
            scorecard: LabScorecard.weighted(dimensions: dimensions, hardGateFailures: hardFailures, warnings: warnings),
            artifacts: artifacts
        )
    }

    private static func addBenchPercentiles(prefix: String, label: String, values: [Double], unit: String, target: Double, metrics: inout [LabMetric]) {
        guard !values.isEmpty else { return }
        for (suffix, quantile) in [("p50", 0.50), ("p95", 0.95), ("p99", 0.99)] {
            if let value = LabStatistics.percentile(values, quantile) {
                metrics.append(LabMetric(
                    key: "dictation.\(prefix).\(suffix)",
                    label: "\(label) \(suffix)",
                    value: value,
                    unit: unit,
                    sampleCount: values.count,
                    target: suffix == "p95" ? target : nil,
                    direction: .lowerIsBetter
                ))
            }
        }
    }
}

public enum SpeakerSweepAnalyzer {
    public static func analyze(configuration: LabRunConfiguration) throws -> LabAnalysisResult {
        let reportDirectory = URL(fileURLWithPath: configuration.repositoryPath, isDirectory: true)
            .appendingPathComponent("data/eval/\(configuration.speakerCorpus.rawValue)/reports", isDirectory: true)
        let consolidation = Set(configuration.consolidationThresholds.split(whereSeparator: \.isWhitespace).map { canonicalThreshold(String($0)) })
        let matches = Set(configuration.matchThresholds.split(whereSeparator: \.isWhitespace).map { canonicalThreshold(String($0)) })
        let files = (try? FileManager.default.contentsOfDirectory(at: reportDirectory, includingPropertiesForKeys: nil)) ?? []
        var candidates: [SpeakerCandidate] = []
        for file in files where file.pathExtension == "json" && file.lastPathComponent.hasPrefix("cons_") {
            guard let candidate = try? decodeCandidate(file) else { continue }
            if !consolidation.isEmpty && !consolidation.contains(canonicalThreshold(candidate.consolidation)) { continue }
            if !matches.isEmpty && !matches.contains(canonicalThreshold(candidate.match)) { continue }
            candidates.append(candidate)
        }
        guard !candidates.isEmpty else {
            throw LabRunnerError.reportNotFound("No speaker score JSON files matched the configured sweep in \(reportDirectory.path)")
        }

        let best = candidates.sorted(by: candidateIsBetter).first!
        var hardFailures: [String] = []
        if best.falseMergeCount > 0 {
            hardFailures.append("Best candidate still made \(best.falseMergeCount) cross-person false merge(s).")
        }
        var warnings = ["Threshold Sweep measures diarization, fragmentation, false merges, and cross-meeting re-identification. Run ASK / SUGGEST / AUTO research to measure false automatic names and profile contamination directly."]
        if best.trueSpeakerCount != best.profilesAtEnd {
            warnings.append("Best candidate ended with \(best.profilesAtEnd) profiles for \(best.trueSpeakerCount) true speakers.")
        }

        let safetyScore = best.falseMergeCount == 0 ? 100 : max(0, 100 - best.falseMergeCount * 35)
        let reIDScore = LabStatistics.higherIsBetterScore(value: best.reID, target: 1) ?? 0
        let fragmentationScore = max(0, min(100, Int((100 - abs(best.fragmentation - 1) * 50).rounded())))
        let diarizationScore = max(0, min(100, Int(((1 - best.der) * 100).rounded())))
        let dimensions = [
            LabScoreDimension(key: "speaker-safety", label: "Speaker safety", score: safetyScore, weight: 0.40, explanation: "Cross-person false merges. Any false merge is a hard failure."),
            LabScoreDimension(key: "speaker-reid", label: "Cross-meeting re-ID", score: reIDScore, weight: 0.25, explanation: "How often recurring speakers map back to the correct stored identity after first appearance."),
            LabScoreDimension(key: "speaker-fragmentation", label: "Identity stability", score: fragmentationScore, weight: 0.20, explanation: "How close the system stays to one profile per real person."),
            LabScoreDimension(key: "diarization", label: "Diarization", score: diarizationScore, weight: 0.15, explanation: "One minus mean diarization error rate."),
        ]
        let metrics = [
            LabMetric(key: "speaker.false-merges", label: "False merges", value: Double(best.falseMergeCount), unit: "merges", target: 0, direction: .lowerIsBetter),
            LabMetric(key: "speaker.reid", label: "Re-ID after first appearance", value: best.reID, unit: "rate", target: 1, direction: .higherIsBetter),
            LabMetric(key: "speaker.fragmentation", label: "Profiles per person", value: best.fragmentation, unit: "profiles/person", target: 1, direction: .target),
            LabMetric(key: "speaker.der", label: "Mean DER", value: best.der, unit: "rate", target: 0, direction: .lowerIsBetter),
            LabMetric(key: "speaker.profiles", label: "Profiles at end", value: Double(best.profilesAtEnd), unit: "profiles", target: Double(best.trueSpeakerCount), direction: .target),
            LabMetric(key: "speaker.true-speakers", label: "True speakers", value: Double(best.trueSpeakerCount), unit: "speakers"),
            LabMetric(key: "speaker.consolidation", label: "Best consolidation threshold", value: Double(best.consolidation) ?? -1, unit: best.consolidation == "none" ? "none" : "cosine"),
            LabMetric(key: "speaker.match", label: "Best match threshold", value: Double(best.match) ?? 0, unit: "cosine"),
        ]
        let sweep = reportDirectory.appendingPathComponent("SWEEP.md")
        return LabAnalysisResult(
            summary: "Best safe-first speaker candidate: consolidation \(best.consolidation), match \(best.match), false merges \(best.falseMergeCount), re-ID \(format(best.reID)).",
            metrics: metrics,
            scorecard: LabScorecard.weighted(dimensions: dimensions, hardGateFailures: hardFailures, warnings: warnings),
            artifacts: [
                LabArtifact(label: "Best speaker score JSON", path: best.path),
                LabArtifact(label: "Speaker sweep", path: sweep.path),
            ]
        )
    }

    private static func canonicalThreshold(_ value: String) -> String {
        guard let number = Double(value), number.isFinite else { return value }
        return String(number)
    }

    private struct SpeakerCandidate {
        let path: String
        let consolidation: String
        let match: String
        let der: Double
        let fragmentation: Double
        let falseMergeCount: Int
        let reID: Double
        let profilesAtEnd: Int
        let trueSpeakerCount: Int
    }

    private static func decodeCandidate(_ url: URL) throws -> SpeakerCandidate {
        let data = try Data(contentsOf: url)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = root["config"] as? [String: Any],
              let der = root["der"] as? [String: Any],
              let fragmentation = root["fragmentation"] as? [String: Any],
              let falseMerge = root["false_merge"] as? [String: Any] else {
            throw LabRunnerError.reportNotFound(url.path)
        }
        let curve = root["reid_curve_by_appearance"] as? [String: Any] ?? [:]
        let later = curve.compactMap { key, value -> Double? in
            guard (Int(key) ?? 0) >= 2 else { return nil }
            if let number = value as? NSNumber { return number.doubleValue }
            if let string = value as? String { return Double(string) }
            return nil
        }
        let consolidation: String
        if let value = config["consolidationThreshold"] as? String {
            consolidation = value
        } else if let value = config["consolidationThreshold"] as? NSNumber {
            consolidation = value.stringValue
        } else {
            consolidation = "none"
        }
        let match: String
        if let value = config["matchThreshold"] as? NSNumber {
            match = value.stringValue
        } else {
            match = config["matchThreshold"] as? String ?? "0"
        }
        return SpeakerCandidate(
            path: url.path,
            consolidation: consolidation,
            match: match,
            der: der.labDouble("mean_der") ?? 1,
            fragmentation: fragmentation.labDouble("mean_profiles_per_person") ?? 99,
            falseMergeCount: Int(falseMerge.labDouble("count") ?? 0),
            reID: LabStatistics.mean(later) ?? 0,
            profilesAtEnd: Int(root.labDouble("profiles_at_end") ?? 0),
            trueSpeakerCount: (root["true_speakers"] as? [Any])?.count ?? 0
        )
    }

    private static func candidateIsBetter(_ lhs: SpeakerCandidate, _ rhs: SpeakerCandidate) -> Bool {
        let left = (
            lhs.falseMergeCount,
            abs(lhs.profilesAtEnd - lhs.trueSpeakerCount),
            -lhs.reID,
            abs(lhs.fragmentation - 1),
            lhs.der
        )
        let right = (
            rhs.falseMergeCount,
            abs(rhs.profilesAtEnd - rhs.trueSpeakerCount),
            -rhs.reID,
            abs(rhs.fragmentation - 1),
            rhs.der
        )
        if left.0 != right.0 { return left.0 < right.0 }
        if left.1 != right.1 { return left.1 < right.1 }
        if left.2 != right.2 { return left.2 < right.2 }
        if left.3 != right.3 { return left.3 < right.3 }
        return left.4 < right.4
    }
}

public enum QAResultsAnalyzer {
    public static func analyze(resultsURL: URL, reportURL: URL, title: String) throws -> LabAnalysisResult {
        guard FileManager.default.fileExists(atPath: resultsURL.path) else {
            throw LabRunnerError.reportNotFound(resultsURL.path)
        }
        let text = try String(contentsOf: resultsURL, encoding: .utf8)
        var pass = 0
        var warn = 0
        var fail = 0
        var skip = 0
        var totalDuration = 0.0
        text.enumerateLines { line, _ in
            let columns = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard columns.count >= 5 else { return }
            switch columns[2] {
            case "PASS": pass += 1
            case "WARN": warn += 1
            case "FAIL": fail += 1
            case "SKIP": skip += 1
            default: break
            }
            totalDuration += Double(columns[4]) ?? 0
        }
        let scored = pass + warn + fail
        let score = scored > 0 ? Int(((Double(pass) + Double(warn) * 0.5) / Double(scored) * 100).rounded()) : nil
        var hardFailures: [String] = []
        if fail > 0 { hardFailures.append("\(fail) blocking QA step(s) failed.") }
        var warnings: [String] = []
        if warn > 0 { warnings.append("\(warn) QA step(s) completed with warnings.") }
        if scored == 0 { warnings.append("No scored QA steps were found.") }
        let dimensions = score.map { [LabScoreDimension(key: "qa", label: title, score: $0, weight: 1, explanation: "PASS counts fully, WARN counts half, and FAIL counts zero.")] } ?? []
        return LabAnalysisResult(
            summary: "\(title): \(pass) passed, \(warn) warned, \(fail) failed, and \(skip) skipped.",
            metrics: [
                LabMetric(key: "qa.pass", label: "Passed steps", value: Double(pass), unit: "steps", direction: .higherIsBetter),
                LabMetric(key: "qa.warn", label: "Warnings", value: Double(warn), unit: "steps", direction: .lowerIsBetter),
                LabMetric(key: "qa.fail", label: "Failed steps", value: Double(fail), unit: "steps", target: 0, direction: .lowerIsBetter),
                LabMetric(key: "qa.skip", label: "Skipped steps", value: Double(skip), unit: "steps"),
                LabMetric(key: "qa.duration", label: "Step duration", value: totalDuration, unit: "s", direction: .informational),
            ],
            scorecard: LabScorecard.weighted(dimensions: dimensions, hardGateFailures: hardFailures, warnings: warnings),
            artifacts: [
                LabArtifact(label: "QA report", path: reportURL.path),
                LabArtifact(label: "QA results", path: resultsURL.path),
            ]
        )
    }
}

public enum SpeakerAutoResearchAnalyzer {
    public static func analyze(stateDirectory: URL) -> LabAnalysisResult {
        let report = stateDirectory.appendingPathComponent("final-report.md")
        let ledger = stateDirectory.appendingPathComponent("results.tsv")
        var artifacts: [LabArtifact] = []
        if FileManager.default.fileExists(atPath: report.path) {
            artifacts.append(LabArtifact(label: "Speaker auto-research report", path: report.path))
        }
        if FileManager.default.fileExists(atPath: ledger.path) {
            artifacts.append(LabArtifact(label: "Speaker experiment ledger", path: ledger.path))
        }
        let complete = FileManager.default.fileExists(atPath: report.path)
        return LabAnalysisResult(
            summary: complete
                ? "Speaker auto-research completed. Open the final report for promoted candidates and holdout evidence."
                : "Speaker auto-research phase completed without a final holdout report.",
            metrics: [],
            scorecard: LabScorecard(
                overallScore: nil,
                dimensions: [],
                hardGateFailures: [],
                warnings: ["The auto-research evaluator owns its promotion gates. Transcripted Lab preserves its report instead of flattening those safety checks into a misleading single score."]
            ),
            artifacts: artifacts
        )
    }
}

func averageScore(_ values: [Int]) -> Int? {
    guard !values.isEmpty else { return nil }
    return Int((Double(values.reduce(0, +)) / Double(values.count)).rounded())
}

func format(_ value: Double?) -> String {
    guard let value else { return "n/a" }
    return String(format: "%.3f", value)
}
