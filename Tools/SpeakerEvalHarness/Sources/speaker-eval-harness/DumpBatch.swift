// dump-batch — like `dump`, but initializes the REAL diarizer ONCE and processes a whole
// directory of WAVs. For corpora with many short clips (VoxCeleb singles: 600 × ~5s) the
// per-invocation model load that `dump` pays would dominate; batching amortizes it.
//
// Identical real pipeline as `dump` (TranscriptedCore.DiarizationService.diarizeOffline →
// FluidAudio PyAnnote + 256-dim WeSpeaker). Idempotent: a non-empty out JSON is skipped,
// so a long batch survives interruption and resumes.

import Foundation
import TranscriptedCore

@available(macOS 14.0, *)
func runDumpBatch(_ args: [String]) async {
    guard let dir = argValue("--audio-dir", in: args),
          let outDir = argValue("--out-dir", in: args) else {
        die("dump-batch requires --audio-dir <dir> --out-dir <dir> [--suffix .wav]")
    }
    let suffix = argValue("--suffix", in: args) ?? ".wav"
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { die("cannot list \(dir)") }
    let wavs = entries.filter { $0.hasSuffix(suffix) }.sorted()
    guard !wavs.isEmpty else { die("no \(suffix) files in \(dir)") }
    try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

    func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

    // Resolve symlinks (VoxCeleb singles symlink into the HF cache); diarizer reads the file.
    let pending = wavs.filter { !fileNonEmpty("\(outDir)/\(($0 as NSString).deletingPathExtension).json") }
    log("[dump-batch] \(wavs.count) files, \(wavs.count - pending.count) cached, \(pending.count) to diarize")
    guard !pending.isEmpty else { log("[dump-batch] all cached — nothing to do"); return }

    let service = await DiarizationService()
    log("[dump-batch] initializing diarizer (one-time)...")
    await service.initialize()
    let ready = await MainActor.run { service.isReady }
    guard ready else { die("diarizer failed to initialize (see logs)") }

    let enc = JSONEncoder()
    var ok = 0, failed = 0
    let t0 = Date()
    for (i, name) in pending.enumerated() {
        let meeting = (name as NSString).deletingPathExtension
        let audioURL = URL(fileURLWithPath: "\(dir)/\(name)").resolvingSymlinksInPath()
        let out = "\(outDir)/\(meeting).json"
        do {
            let segments = try await service.diarizeOffline(audioURL: audioURL)
            let dumped = segments.map {
                SegmentDump(speakerId: $0.speakerId, start: $0.startTime, end: $0.endTime,
                            quality: $0.qualityScore, embedding: $0.embedding)
            }
            let dur = segments.map { $0.endTime }.max() ?? 0
            let raw = RawDump(meeting: meeting, audioPath: audioURL.path, durationSeconds: dur,
                              diarizerSpeakerCount: Set(segments.map { $0.speakerId }).count, segments: dumped)
            try enc.encode(raw).write(to: URL(fileURLWithPath: out))
            ok += 1
        } catch {
            failed += 1
            log("[dump-batch] FAILED \(meeting): \(error.localizedDescription)")
        }
        if (i + 1) % 25 == 0 || i + 1 == pending.count {
            let rate = Date().timeIntervalSince(t0) / Double(i + 1)
            log("[dump-batch] \(i + 1)/\(pending.count) (\(String(format: "%.2f", rate))s/clip, \(ok) ok \(failed) failed)")
        }
    }
    await service.cleanup()
    log("[dump-batch] DONE: \(ok) ok, \(failed) failed, \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
}

func fileNonEmpty(_ path: String) -> Bool {
    guard let a = try? FileManager.default.attributesOfItem(atPath: path),
          let n = a[.size] as? Int else { return false }
    return n > 0
}
