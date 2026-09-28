// Measures WritingSecretScrubber. Built and run by
// scripts/dev/measure-writing-scrubber.sh; see that script for the modes.
// Prints corpus text only for the labelled corpus and the repo sweep, both
// public. `--counts-only DIR` reads real day files and prints numbers only.
import Foundation

struct Corpus: Decodable {
    struct SecretCase: Decodable {
        let category: String, name: String, app: String, context: [String], text: String
        let secrets: [String], knownMiss: Bool
    }
    struct OrdinaryCase: Decodable {
        let category: String, name: String, app: String, context: [String], text: String
        let knownFalsePositive: Bool
    }
    let secrets: [SecretCase]
    let ordinary: [OrdinaryCase]
}

func scrub(_ text: String, _ app: String, _ context: [String] = []) -> WritingSecretScrubber.Result {
    WritingSecretScrubber.scrub(text, appBundleIdentifier: app, precedingLines: context)
}

/// The option this replaced: `SecretRules` as the prompt path uses it.
func baseline(_ text: String) -> String {
    SecretRules.scrub(text, config: .forPromptContext).clean
}

func pct(_ part: Int, _ whole: Int) -> String {
    whole == 0 ? "n/a" : String(format: "%.1f%%", Double(part) * 100 / Double(whole))
}

func runCorpus(_ path: String, verbose: Bool) {
    guard let data = FileManager.default.contents(atPath: path),
          let corpus = try? JSONDecoder().decode(Corpus.self, from: data) else {
        print("could not read corpus at \(path)"); exit(1)
    }
    print("## Labelled corpus (\(path))\n")
    print("| Category | Secret cases | Caught | Missed | Recall | SecretRules alone |")
    print("|---|---:|---:|---:|---:|---:|")
    var byCategory: [String: (total: Int, caught: Int, baseline: Int)] = [:]
    var order: [String] = []
    var missed: [String] = []
    for item in corpus.secrets {
        let result = scrub(item.text, item.app, item.context)
        let caught = item.secrets.allSatisfy { !result.clean.contains($0) }
        if byCategory[item.category] == nil { order.append(item.category) }
        var entry = byCategory[item.category, default: (0, 0, 0)]
        entry.total += 1
        let plain = baseline(item.text)
        if item.secrets.allSatisfy({ !plain.contains($0) }) { entry.baseline += 1 }
        if caught { entry.caught += 1 } else { missed.append("\(item.category): \(item.name)\(item.knownMiss ? " (known miss)" : " (UNEXPECTED)")") }
        byCategory[item.category] = entry
    }
    var total = 0, caught = 0, baselineCaught = 0
    for category in order {
        let entry = byCategory[category]!
        total += entry.total; caught += entry.caught; baselineCaught += entry.baseline
        print("| \(category) | \(entry.total) | \(entry.caught) | \(entry.total - entry.caught) | \(pct(entry.caught, entry.total)) | \(pct(entry.baseline, entry.total)) |")
    }
    print("| **all** | **\(total)** | **\(caught)** | **\(total - caught)** | **\(pct(caught, total))** | **\(pct(baselineCaught, total))** |\n")
    if !missed.isEmpty { print("Missed:\n" + missed.map { "- \($0)" }.joined(separator: "\n") + "\n") }

    var changed: [String] = []
    for item in corpus.ordinary {
        let result = scrub(item.text, item.app, item.context)
        if result.clean != item.text {
            changed.append("\(item.category): \(item.name)\(item.knownFalsePositive ? " (known)" : " (UNEXPECTED)")")
            if verbose { print("  FP \(item.name):\n    in:  \(item.text.debugDescription)\n    out: \(result.clean.debugDescription)") }
        }
    }
    print("Ordinary texts: \(corpus.ordinary.count), changed: \(changed.count) (\(pct(changed.count, corpus.ordinary.count)))")
    if !changed.isEmpty { print(changed.map { "- \($0)" }.joined(separator: "\n")) }
    print("")
}

/// Splits a file into entry-sized chunks: runs of up to 5 non-empty lines.
func chunks(_ text: String) -> [String] {
    var result: [String] = []
    var current: [String] = []
    for line in text.components(separatedBy: "\n") {
        if line.trimmingCharacters(in: .whitespaces).isEmpty || current.count == 5 {
            if !current.isEmpty { result.append(current.joined(separator: "\n")) }
            current = []
            if line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
        }
        current.append(line)
    }
    if !current.isEmpty { result.append(current.joined(separator: "\n")) }
    return result
}

func sweep(label: String, app: String, files: [String], show: Bool) {
    var entries = 0, lines = 0, hitEntries = 0, redactions = 0, baselineHits = 0
    var kinds: [String: Int] = [:]
    var samples: [String] = []
    for file in files {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { continue }
        for chunk in chunks(text) {
            entries += 1
            lines += chunk.components(separatedBy: "\n").count
            if baseline(chunk) != chunk { baselineHits += 1 }
            let result = scrub(chunk, app)
            guard !result.kinds.isEmpty else { continue }
            hitEntries += 1
            redactions += result.kinds.count
            for kind in result.kinds { kinds[kind.rawValue, default: 0] += 1 }
            if show {
                let before = chunk.components(separatedBy: "\n"), after = result.clean.components(separatedBy: "\n")
                let changedLines = zip(before, after).filter { $0 != $1 }.map { "    \($0.0)\n  → \($0.1)" }
                samples.append("  [\(URL(fileURLWithPath: file).lastPathComponent)]\n" + changedLines.joined(separator: "\n"))
            }
        }
    }
    let kindList = kinds.sorted { $0.value > $1.value }.map { "\($0.key) \($0.value)" }.joined(separator: ", ")
    print("| \(label) | \(files.count) | \(entries) | \(lines) | \(hitEntries) (\(pct(hitEntries, entries))) | \(redactions) | \(kindList) | \(baselineHits) (\(pct(baselineHits, entries))) |")
    if show, !samples.isEmpty { FileHandle.standardError.write(Data(("\n### \(label)\n" + samples.joined(separator: "\n") + "\n").utf8)) }
}

/// Real day files: numbers only, never text.
func countsOnly(_ directory: String) {
    let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [])
        .filter { $0.hasPrefix("Writing_") && $0.hasSuffix(".md") }
    var sections = 0, touched = 0, dropped = 0
    var kinds: [String: Int] = [:]
    for name in names {
        guard let text = try? String(contentsOfFile: directory + "/" + name, encoding: .utf8) else { continue }
        for section in text.components(separatedBy: "\n## ").dropFirst() {
            sections += 1
            let bundle = section.components(separatedBy: "\n").first { $0.hasPrefix("Bundle ID: `") }
                .map { String($0.dropFirst(12).dropLast()) } ?? ""
            guard let range = section.range(of: "\nAccepted words:") else { continue }
            let rest = section[range.upperBound...]
            guard let bodyStart = rest.range(of: "\n\n") else { continue }
            let body = String(rest[bodyStart.upperBound...])
            let result = scrub(body, bundle)
            if !result.kinds.isEmpty { touched += 1 }
            if result.isOnlyRedactions { dropped += 1 }
            for kind in result.kinds { kinds[kind.rawValue, default: 0] += 1 }
        }
    }
    print("day files: \(names.count), sections: \(sections), sections with a redaction: \(touched), would be removed: \(dropped)")
    print("redactions by kind: " + kinds.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
}

let args = Array(CommandLine.arguments.dropFirst())
if let index = args.firstIndex(of: "--counts-only"), index + 1 < args.count {
    countsOnly(args[index + 1]); exit(0)
}
let show = args.contains("--show")
let corpusPath = args.first { $0.hasSuffix(".json") } ?? "Tests/Fixtures/writing-secret-corpus.json"
runCorpus(corpusPath, verbose: show)

// Sweep lists: `--sweep <label> <bundle id> <file list path>`.
var sweeps: [(String, String, String)] = []
var i = 0
while i < args.count {
    if args[i] == "--sweep", i + 3 < args.count { sweeps.append((args[i + 1], args[i + 2], args[i + 3])); i += 4 } else { i += 1 }
}
if !sweeps.isEmpty {
    print("## Repo sweep (text that has no secrets: every redaction is a false positive unless noted)\n")
    print("| Corpus | Files | Entries | Lines | Entries changed | Redactions | Kinds | SecretRules alone: entries changed |")
    print("|---|---:|---:|---:|---:|---:|---|---:|")
    for (label, app, listPath) in sweeps {
        let files = ((try? String(contentsOfFile: listPath, encoding: .utf8)) ?? "")
            .components(separatedBy: "\n").filter { !$0.isEmpty }
        sweep(label: label, app: app, files: files, show: show)
    }
}
