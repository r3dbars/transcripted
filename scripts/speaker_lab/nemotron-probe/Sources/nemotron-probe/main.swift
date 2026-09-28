// nemotron-probe <variant> <set dir>...: Nemotron 3 Diarization (FluidAudio 0.17.x) over each
// meeting's system.wav, saved as <meeting>/e2e_nemotron3-<variant>.json for score.py --e2e.
import FluidAudio
import Foundation

struct Seg: Codable { let speaker: Int; let start: Double; let end: Double }
struct Out: Codable { let meeting: String; let model: String; let processingSeconds: Double; let speakers: Int; let segments: [Seg] }
struct Series: Codable { struct M: Codable { let id: String }; let meetings: [M] }

let args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2, let config = Nemotron3Config.preset(named: args[0]) else {
    FileHandle.standardError.write(Data("usage: nemotron-probe <offline|fast128|...> <set dir>...\n".utf8)); exit(2)
}
let variant = args[0]
let models = try await Nemotron3Models.loadFromHuggingFace(config: config, computeUnits: .all)
let diarizer = Nemotron3Diarizer(config: config, models: models)
for setPath in args.dropFirst() {
    let setDir = URL(fileURLWithPath: setPath, isDirectory: true)
    let series = try JSONDecoder().decode(Series.self, from: Data(contentsOf: setDir.appendingPathComponent("series.json")))
    for m in series.meetings {
        let dir = setDir.appendingPathComponent(m.id, isDirectory: true)
        let out = dir.appendingPathComponent("e2e_nemotron3-\(variant).json")
        if FileManager.default.fileExists(atPath: out.path) { continue }
        do {
            let audio = try AudioConverter().resampleAudioFile(path: dir.appendingPathComponent("system.wav").path)
            let t0 = Date()
            let (probs, frames) = try diarizer.processComplete(audio, speechMask: nil)
            let segs = Nemotron3Diarizer.segments(probabilities: probs, frameCount: frames)
                .map { Seg(speaker: $0.speakerIndex, start: Double($0.startSeconds), end: Double($0.endSeconds)) }
                .sorted { $0.start < $1.start }
            let o = Out(meeting: m.id, model: "nemotron3-\(variant)", processingSeconds: Date().timeIntervalSince(t0),
                        speakers: Set(segs.map(\.speaker)).count, segments: segs)
            try JSONEncoder().encode(o).write(to: out)
            print("[nemotron3-\(variant)] \(m.id): \(o.speakers) speakers, \(String(format: "%.1f", o.processingSeconds))s")
        } catch {
            FileHandle.standardError.write(Data("[nemotron3] \(m.id): \(error)\n".utf8))
        }
    }
}
