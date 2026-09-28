// dump-e2e: run an end-to-end neural diarizer that ships inside our FluidAudio
// build (NVIDIA Sortformer, or one of the LS-EEND variants) over every meeting's
// system.wav in a speaker-lab set, and save who-spoke-when per meeting as
// <meeting>/e2e_<model>.json. scripts/speaker_lab/score.py --e2e <model> scores
// each model speaker as if it were a naming row, next to the production pipeline.
//
// These models give speaker turns but no voice fingerprints, so on their own
// they can't do cross-meeting naming. The question here is narrower: do they
// split the people on a call better than PyAnnote + VBx?
//
//   speaker-eval-harness dump-e2e --series data/eval/yodas3/sim/<set> --model sortformer
//   models: sortformer | lseend-dihard3 | lseend-callhome | lseend-ami

import FluidAudio
import TranscriptedCore
import Foundation

struct E2ESegment: Codable {
    let speaker: Int
    let start: Double
    let end: Double
}

struct E2EDumpOut: Codable {
    let meeting: String
    let model: String
    let seconds: Double
    let processingSeconds: Double
    let speakers: Int
    let segments: [E2ESegment]
}

@available(macOS 26.0, *)
func runDumpE2E(_ args: [String]) async {
    guard let setPath = argValue("--series", in: args), let model = argValue("--model", in: args) else {
        die("dump-e2e requires --series <set dir> --model <sortformer|lseend-dihard3|lseend-callhome|lseend-ami>")
    }
    let setDir = URL(fileURLWithPath: setPath, isDirectory: true)
    guard let data = try? Data(contentsOf: setDir.appendingPathComponent("series.json")),
          let series = try? JSONDecoder().decode(LabSeries.self, from: data) else {
        die("could not read series.json in \(setPath)")
    }
    let force = args.contains("--force")

    var sortformer: SortformerDiarizer?
    var lseend: LSEENDDiarizer?
    do {
        switch model {
        case "sortformer":
            let config = SortformerConfig.highContextV2_1
            let diarizer = SortformerDiarizer(config: config, timelineConfig: .sortformerDefault)
            diarizer.initialize(models: try await SortformerModels.loadFromHuggingFace(config: config, computeUnits: .all))
            sortformer = diarizer
        case "lseend-dihard3", "lseend-callhome", "lseend-ami":
            let variant: LSEENDVariant = model == "lseend-callhome" ? .callhome : (model == "lseend-ami" ? .ami : .dihard3)
            let loaded = try await LSEENDModel.loadFromHuggingFace(variant: variant, stepSize: .step500ms, computeUnits: .cpuOnly)
            lseend = try LSEENDDiarizer(model: loaded)
        default:
            die("unknown model \(model)")
        }
    } catch {
        die("model load failed: \(error)")
    }

    for meeting in series.meetings {
        let dir = setDir.appendingPathComponent(meeting.id, isDirectory: true)
        let out = dir.appendingPathComponent("e2e_\(model).json")
        if !force, FileManager.default.fileExists(atPath: out.path) { continue }
        let audio = dir.appendingPathComponent("system.wav")
        let t0 = Date()
        var segments: [E2ESegment] = []
        var seconds = 0.0
        do {
            if let sortformer {
                let samples = try AudioConverter().resampleAudioFile(path: audio.path)
                seconds = Double(samples.count) / 16000
                sortformer.reset()
                let result = try sortformer.processComplete(samples)
                segments = result.speakers.values.flatMap(\.finalizedSegments).map {
                    E2ESegment(speaker: $0.speakerIndex, start: Double($0.startTime), end: Double($0.endTime))
                }
            } else if let lseend {
                let timeline = try lseend.processComplete(audioFileURL: audio, keepingEnrolledSpeakers: nil,
                                                          finalizeOnCompletion: true, progressCallback: nil)
                seconds = Double(timeline.finalizedDuration)
                segments = timeline.speakers.values.flatMap(\.finalizedSegments).map {
                    E2ESegment(speaker: $0.speakerIndex, start: Double($0.startTime), end: Double($0.endTime))
                }
            }
        } catch {
            FileHandle.standardError.write(Data("[e2e] \(meeting.id): \(error)\n".utf8))
            continue
        }
        segments.sort { $0.start < $1.start }
        let dump = E2EDumpOut(meeting: meeting.id, model: model, seconds: seconds,
                              processingSeconds: Date().timeIntervalSince(t0),
                              speakers: Set(segments.map(\.speaker)).count, segments: segments)
        if let encoded = try? JSONEncoder().encode(dump) { try? encoded.write(to: out) }
        FileHandle.standardError.write(Data(String(format: "[e2e] %@ %@: %d speakers, %.1fs\n",
                                                   model, meeting.id, dump.speakers, dump.processingSeconds).utf8))
    }
}

// dump-set: the production offline diarizer (whatever TRANSCRIPTED_LAB_KNOBS_FILE
// sets) over every meeting's system.wav, loading models once, saved as
// <meeting>/e2e_raw-<tag>.json in the same shape as dump-e2e. This is the raw
// diarizer output before the pipeline's own post-processing, which is where the
// big-call speaker loss happens (YODAS_LAB_RESULTS.md, finding 1).
@available(macOS 26.0, *)
func runDumpSet(_ args: [String]) async {
    guard let setPath = argValue("--series", in: args), let tag = argValue("--tag", in: args) else {
        die("dump-set requires --series <set dir> --tag <name>")
    }
    let setDir = URL(fileURLWithPath: setPath, isDirectory: true)
    guard let data = try? Data(contentsOf: setDir.appendingPathComponent("series.json")),
          let series = try? JSONDecoder().decode(LabSeries.self, from: data) else {
        die("could not read series.json in \(setPath)")
    }
    let service = await DiarizationService()
    await service.initialize()
    guard await MainActor.run(body: { service.isReady }) else { die("diarizer failed to initialize") }
    for meeting in series.meetings {
        let dir = setDir.appendingPathComponent(meeting.id, isDirectory: true)
        let out = dir.appendingPathComponent("e2e_raw-\(tag).json")
        if FileManager.default.fileExists(atPath: out.path) { continue }
        let t0 = Date()
        do {
            let segments = try await service.diarizeOffline(audioURL: dir.appendingPathComponent("system.wav"))
            let e2e = segments.map { E2ESegment(speaker: $0.speakerId, start: $0.startTime, end: $0.endTime) }
                .sorted { $0.start < $1.start }
            let dump = E2EDumpOut(meeting: meeting.id, model: "raw-\(tag)", seconds: e2e.last?.end ?? 0,
                                  processingSeconds: Date().timeIntervalSince(t0),
                                  speakers: Set(e2e.map(\.speaker)).count, segments: e2e)
            if let encoded = try? JSONEncoder().encode(dump) { try? encoded.write(to: out) }
        } catch {
            FileHandle.standardError.write(Data("[dump-set] \(meeting.id): \(error)\n".utf8))
        }
    }
    FileHandle.standardError.write(Data("[dump-set] \(tag) \(setDir.lastPathComponent) done\n".utf8))
}
