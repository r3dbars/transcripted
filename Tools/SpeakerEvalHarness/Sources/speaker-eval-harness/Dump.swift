// Dump.swift — `speaker-eval-harness dump`
//
// Diarize one audio file with the app's own DiarizationService and write every
// segment + its speaker embedding to JSON. This is the expensive stage; the lab
// caches one dump per (meeting, variant) and replays it many times.
//
// A variant is (diarizer backend × embedding model):
//   --backend  pyannote (default, FluidAudio OfflineDiarizerManager — what ships today)
//              nemotron (NVIDIA Nemotron 3 Diarization; preset via env
//                        TRANSCRIPTED_NEMOTRON_PRESET, e.g. fast128 | fast32 | offline | low)
//   --embedder native   (whatever the backend emits: WeSpeaker 256-d for both backends)
//              eres2net (re-embed every segment with the ERes2Net 192-d CoreML model,
//                        loaded from --eres2net-model or the FluidAudio Models cache)
//
// The dump never silently falls back: if eres2net is requested and the model can't
// load, the command fails, so a cached dump always means what its variant says.

import Foundation
import AVFoundation
import TranscriptedCore

enum DumpEmbedderChoice: String, CaseIterable {
    case native
    case eres2net
}

/// Where the app stages the ERes2Net model for local builds (see build.sh and
/// ERes2NetDiarizationE2ETests): the shared FluidAudio Models cache.
func defaultERes2NetModelPath() -> String? {
    guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
        return nil
    }
    return appSupport
        .appendingPathComponent("FluidAudio/Models/eres2net-embedding/Model.mlmodelc")
        .path
}

/// Duration of the audio file in seconds, read from its header (no decode).
func audioDurationSeconds(_ url: URL) -> Double? {
    guard let file = try? AVAudioFile(forReading: url) else { return nil }
    let rate = file.fileFormat.sampleRate
    guard rate > 0 else { return nil }
    return Double(file.length) / rate
}

@available(macOS 14.0, *)
func runDump(_ args: [String]) async {
    let usage = "dump requires --audio <wav|m4a> --out <raw.json> [--meeting NAME] "
        + "[--backend \(DiarizationBackend.allCases.map { $0.rawValue }.joined(separator: "|"))] "
        + "[--embedder native|eres2net] [--eres2net-model <Model.mlmodelc>]"
    guard let audio = argValue("--audio", in: args), let out = argValue("--out", in: args) else {
        die(usage)
    }
    let audioURL = URL(fileURLWithPath: audio)
    guard FileManager.default.fileExists(atPath: audioURL.path) else { die("audio not found: \(audio)") }
    let meeting = argValue("--meeting", in: args) ?? audioURL.deletingPathExtension().lastPathComponent

    let backendRaw = (argValue("--backend", in: args) ?? DiarizationBackend.pyannote.rawValue).lowercased()
    guard let backend = DiarizationBackend(rawValue: backendRaw) else {
        die("unknown --backend \(backendRaw); \(usage)")
    }
    let embedderRaw = (argValue("--embedder", in: args) ?? DumpEmbedderChoice.native.rawValue).lowercased()
    guard let embedderChoice = DumpEmbedderChoice(rawValue: embedderRaw) else {
        die("unknown --embedder \(embedderRaw); \(usage)")
    }

    let segmentEmbedder: (any SpeakerSegmentEmbedder)?
    switch embedderChoice {
    case .native:
        segmentEmbedder = nil
    case .eres2net:
        guard let modelPath = argValue("--eres2net-model", in: args) ?? defaultERes2NetModelPath() else {
            die("cannot resolve the ERes2Net model path; pass --eres2net-model <Model.mlmodelc>")
        }
        guard FileManager.default.fileExists(atPath: modelPath) else {
            die("ERes2Net model not found at \(modelPath); pass --eres2net-model <Model.mlmodelc> "
                + "(convert it with scripts/convert_eres2net_fused.py)")
        }
        guard let loaded = ERes2NetEmbedder(modelURL: URL(fileURLWithPath: modelPath)) else {
            die("ERes2Net model failed to load at \(modelPath)")
        }
        segmentEmbedder = loaded
    }
    // Effective fingerprint model recorded in the dump. Both backends' native
    // embedding is FluidAudio's WeSpeaker (the contract for .nemotron without an
    // injected embedder), so "native" is recorded as "wespeaker".
    let embedderId = segmentEmbedder?.identifier ?? "wespeaker"
    let nemotronPreset: String? = backend == .nemotron
        ? (ProcessInfo.processInfo.environment["TRANSCRIPTED_NEMOTRON_PRESET"] ?? "default")
        : nil

    let service = await DiarizationService(segmentEmbedder: segmentEmbedder, backend: backend)
    FileHandle.standardError.write(Data((
        "[dump] \(meeting): initializing \(backend.rawValue) diarizer + \(embedderId) embedder "
        + "(may download models on first run)...\n").utf8))
    let initStart = Date()
    await service.initialize()
    let initSeconds = Date().timeIntervalSince(initStart)
    let ready = await MainActor.run { service.isReady }
    guard ready else { die("diarizer (\(backend.rawValue)) failed to initialize (see logs)") }

    FileHandle.standardError.write(Data("[dump] \(meeting): diarizing...\n".utf8))
    let t0 = Date()
    let segments: [SpeakerSegment]
    do {
        segments = try await service.diarizeOffline(audioURL: audioURL)
    } catch {
        die("diarization failed: \(error.localizedDescription)")
    }
    let elapsed = Date().timeIntervalSince(t0)

    let dumped = segments.map {
        SegmentDump(speakerId: $0.speakerId, start: $0.startTime, end: $0.endTime,
                    quality: $0.qualityScore, embedding: $0.embedding)
    }
    let withEmb = dumped.filter { ($0.embedding?.isEmpty == false) }.count
    let dims = Set(dumped.compactMap { $0.embedding?.count }.filter { $0 > 0 })
    if dims.count > 1 {
        FileHandle.standardError.write(Data("[dump] \(meeting): WARNING mixed embedding dims \(dims.sorted())\n".utf8))
    }
    let dim = dumped.compactMap { $0.embedding?.count }.first { $0 > 0 } ?? 0
    let lastSegmentEnd = segments.map { $0.endTime }.max() ?? 0
    let audioSeconds = audioDurationSeconds(audioURL)
    let raw = RawDump(
        meeting: meeting,
        audioPath: audioURL.path,
        durationSeconds: lastSegmentEnd,
        diarizerSpeakerCount: Set(segments.map { $0.speakerId }).count,
        segments: dumped,
        backend: backend.rawValue,
        embedder: embedderId,
        embeddingDimension: dim,
        diarizeSeconds: elapsed,
        audioSeconds: audioSeconds,
        initSeconds: initSeconds,
        nemotronPreset: nemotronPreset
    )

    let enc = JSONEncoder()
    do {
        let url = URL(fileURLWithPath: out)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try enc.encode(raw).write(to: url, options: .atomic)
    } catch {
        die("failed to write \(out): \(error.localizedDescription)")
    }

    let rtf = (audioSeconds ?? 0) > 0 && elapsed > 0 ? (audioSeconds ?? 0) / elapsed : 0
    FileHandle.standardError.write(Data((
        "[dump] \(meeting): backend=\(backend.rawValue) embedder=\(embedderId) "
        + "\(segments.count) segments, \(raw.diarizerSpeakerCount) raw clusters, "
        + "\(withEmb)/\(segments.count) embedded (dim=\(dim)), \(String(format: "%.1f", elapsed))s "
        + "(\(String(format: "%.0f", rtf))x realtime) -> \(out)\n").utf8))
    await service.cleanup()
}
